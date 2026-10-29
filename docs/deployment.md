# Deployment

> **Status:** the `network` and `compute` stages are implemented. The `full`
> stage (RDS, S3, Secrets Manager, CloudFront, WAF, monitoring) is still
> scaffolding, and `scripts/deploy.sh` refuses to deploy it until every template
> is marked `ImplementationStatus: IMPLEMENTED`.

## Prerequisites (local)

- AWS CLI v2, `jq`, `cfn-lint` (`pip install cfn-lint`), optionally `shellcheck`
- Credentials for the target account through AWS IAM Identity Center
  (`aws sso login`), not long-lived access keys

## Validate (safe, offline)

```bash
./scripts/validate.sh          # cfn-lint, parameter files, shellcheck
./scripts/validate.sh --aws    # + read-only `aws cloudformation validate-template`
```

## Stages

The root stack `<ProjectName>-<Environment>` (e.g. `ecommerce-dev`) is deployed
in stages; each stage includes the previous one.

| Stage     | Nested stacks                                                     | Hourly cost (dev) |
|-----------|-------------------------------------------------------------------|-------------------|
| `network` | VPC (`network/vpc.yml`), security groups                          | ~$0 with `NatGatewayMode=none` (flow logs only); +$0.05/h per NAT Gateway otherwise |
| `compute` | + VPC endpoints, IAM instance role, ALB, launch template, Auto Scaling group | ~$0.12 (~$87 / month) |
| `full`    | + RDS, S3, Secrets Manager, CloudFront, WAF, monitoring           | not implemented   |

`deploy.sh` refuses to move a stack to a smaller stage, because CloudFormation
would delete the nested stacks of the larger one. `--allow-shrink` permits it
from `compute` (to stop compute charges and keep the VPC), never from `full`.

Two stacks live outside the root stack:

| Stack                   | Template                  | Region    | Why separate |
|-------------------------|---------------------------|-----------|--------------|
| `<stack>-ecr`           | `storage/ecr.yml`         | us-east-2 | The image must be pushed before the compute stage can start, and deleting the app stack must not delete the images |
| `<stack>-waf`           | `networking/waf.yml`      | us-east-1 | CloudFront-scoped WAF ACLs exist only in us-east-1 (full stage) |

## Deploy

```bash
export CFN_ARTIFACT_BUCKET=<bootstrap-artifact-bucket>
./scripts/deploy.sh dev --stage network              # create and review a change set only
./scripts/deploy.sh dev --stage network --execute    # create, review and execute it
```

`deploy.sh`:

1. Refuses to continue if a template of the chosen stage is still a placeholder,
   if the stack is mid-operation or failed, if it is deployed with a larger
   stage (unless `--allow-shrink`), if it is in `ROLLBACK_COMPLETE` (a failed
   creation; delete it with `destroy.sh` first), or - when the root stack does not exist
   yet - if a VPC named `<stack>-vpc` already exists (a second VPC).
2. For `compute`/`full`: resolves the app image (`--image`, or the deployed
   value) and checks with `scripts/check-image.sh` (read-only) that it is a
   runnable `linux/amd64` image - not, for example, a BuildKit attestation
   manifest or an arm64 build;
   pins the AMI (`--ami`, or the deployed value, or the AL2023 SSM parameter
   for a new stack).
3. Runs `validate.sh`.
4. Asks you to type the stack name for `prod` (skipped with `--yes` in CI).
5. Refuses to change a **protected network parameter** of a deployed stack
   (`NatGatewayMode`, `VpcCidr`, `AvailabilityZoneA/B`) unless it is passed
   explicitly with `--param`. The deployed value always wins over the
   parameter file.
6. Runs `aws cloudformation package`, then `create-change-set
   --include-nested-stacks` with parameters and tags from
   `environments/<env>/parameters.json` plus `--param` overrides. Parameters
   not passed take their template defaults.
7. Prints every resource change, nested stacks included, and **blocks** a
   change set that removes or replaces anything in `NetworkStack` (VPC,
   subnets, NAT Gateways, routes, S3 endpoint), removes a network-stage stack,
   or replaces a security group - unless `--allow-network-changes`.
8. Without `--execute`, prints the command to execute exactly the reviewed
   change set. With `--execute`, executes it and waits for completion.

## NAT Gateway: verify the deployed configuration first

`environments/dev/parameters.json` now says `NatGatewayMode=none`; the last
commit says `single` (the value since the initial commit). The file value only
matters for a **new** stack: for a deployed stack, `deploy.sh` keeps whatever is
deployed and fails if the file differs, until you pass `--param
NatGatewayMode=<value>`. Check what is deployed (all read-only):

```bash
R=us-east-2
# Root stack: stage and network parameters (error = no root stack)
aws cloudformation describe-stacks --region $R --stack-name ecommerce-dev \
  --query "Stacks[0].{Status:StackStatus,Params:Parameters[?contains(['DeploymentStage','NatGatewayMode','VpcCidr','AvailabilityZoneA','AvailabilityZoneB'],ParameterKey)]}"

# Every stack in the region - is the VPC (or ECR) in a standalone stack?
aws cloudformation list-stacks --region $R \
  --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE \
  --query 'StackSummaries[].[StackName,ParentId]' --output table

# NAT Gateways and the app route tables' default routes in the project VPC
VPC=$(aws ec2 describe-vpcs --region $R --filters Name=tag:Name,Values=ecommerce-dev-vpc \
  --query 'Vpcs[].VpcId' --output text); echo "VPC(s): $VPC"
aws ec2 describe-nat-gateways --region $R --filter Name=vpc-id,Values=$VPC \
  --query 'NatGateways[].[NatGatewayId,State,SubnetId,Tags[?Key==`Name`]|[0].Value]' --output table
aws ec2 describe-route-tables --region $R --filters Name=vpc-id,Values=$VPC \
  --query 'RouteTables[].[Tags[?Key==`Name`]|[0].Value,Routes[?DestinationCidrBlock==`0.0.0.0/0`]|[0].[NatGatewayId,GatewayId]]' --output json
# S3 gateway endpoint and the route tables it is attached to
aws ec2 describe-vpc-endpoints --region $R --filters Name=vpc-id,Values=$VPC \
  --query 'VpcEndpoints[].[ServiceName,VpcEndpointType,State,RouteTableIds]' --output json
```

More than one VPC ID means a second VPC already exists. If the NAT Gateway list
is non-empty, keep it with `--param NatGatewayMode=single` (or `per-az`), or
remove it deliberately with `--param NatGatewayMode=none` and review the
`Remove NatGatewayA` / `AppDefaultRouteA/B` lines (which also need
`--allow-network-changes`).

## Compute stage: EC2 + ALB + Auto Scaling

### Architecture

```
Internet ── CloudFront (full stage) or AlbTestIngressCidr (testing)
   │ HTTP 80 (HTTPS 443 once AlbCertificateArn is set)
   ▼
ALB  (public subnets, AZ a + b, ALB security group)
   │ HTTP 8080, health check GET /health -> 200
   ▼
Auto Scaling group  (private app subnets, AZ a + b, app security group)
   EC2 t3.micro, Amazon Linux 2023 (pinned AMI), no key pair, no public IP
   readiness hook: Pending:Wait until the container answers /health locally
   └─ systemd ─ docker run <account>.dkr.ecr.<region>.amazonaws.com/ecommerce-dev-api@sha256:...
                 -p 8080:8080, APP_ENV, UVICORN_PORT, UVICORN_FORWARDED_ALLOW_IPS=<VPC CIDR>
   │ HTTPS 443, no NAT
   ├─ ecr.api, ecr.dkr, logs, autoscaling, ssm, ssmmessages  interface endpoints
   └─ S3 gateway endpoint (network/vpc.yml): ECR image layers, AL2023 dnf repositories
```

| Template | Creates |
|----------|---------|
| `network/endpoints.yml` | Interface endpoints and their security group (443 from the app security group only) |
| `security/iam.yml` | Instance role and profile: ECR pull on the app repository, write to the app log group, complete its own readiness hook, `AmazonSSMManagedInstanceCore` |
| `compute/alb.yml` | Internet-facing ALB, one listener (HTTP 80 or HTTPS 443), target group on 8080 |
| `compute/ec2.yml` | Launch template (pinned AMI, IMDSv2, hop limit 1, encrypted gp3, user data) and the `/<project>/<env>/app` log group |
| `compute/autoscaling.yml` | Auto Scaling group (readiness hook, ELB health checks, instance refresh update policy), CPU target tracking, unhealthy-hosts alarm |
| `network/security-groups.yml` | Unchanged resources; adds an optional test rule (`AlbTestIngressCidr`) |

### IAM instance role

| Permission | Scope |
|------------|-------|
| `ecr:GetAuthorizationToken` | `*` (AWS does not support scoping it) |
| `ecr:BatchGetImage`, `ecr:GetDownloadUrlForLayer`, `ecr:BatchCheckLayerAvailability` | `<project>-<env>-api` repository only; no push |
| `logs:CreateLogStream`, `logs:PutLogEvents` | `/<project>/<env>/app` log group only |
| `autoscaling:CompleteLifecycleAction` | `<project>-<env>-app-asg` only |
| `AmazonSSMManagedInstanceCore` | Session Manager (`EnableSessionManager=true`) |

The container itself cannot use the role: IMDSv2 with a hop limit of 1 blocks
the metadata service from inside containers. Only the Docker daemon on the host
(for the `awslogs` driver) and the boot script use it.

### Private connectivity without NAT

`NatGatewayMode=none` leaves the app subnets with no route to the internet.
Everything the instances need is reached privately:

| Need | Path | Endpoint |
|------|------|----------|
| `docker login` | `api.ecr.us-east-2.amazonaws.com` | `ecr.api` (interface) |
| Image manifests | `<account>.dkr.ecr.us-east-2.amazonaws.com` | `ecr.dkr` (interface) |
| Image layers | `prod-us-east-2-starport-layer-bucket` in S3 | S3 gateway (`network/vpc.yml`) |
| Docker package, if not in the AMI | `al2023-repos-us-east-2-*` buckets in S3 | S3 gateway |
| Container logs | `logs.us-east-2.amazonaws.com` | `logs` (interface) |
| Readiness hook | `autoscaling.us-east-2.amazonaws.com` | `autoscaling` (interface) |
| Session Manager | `ssm`, `ssmmessages` | interface, optional (`EnableSessionManager`) |

Not needed: `sts` (role credentials come from instance metadata), `ec2`,
`kms` (ECR uses AES256, EBS uses the AWS-managed key), `cloudformation` (no
`cfn-signal`), `ec2messages` (SSM Agent 3.3.40.0+, shipped with current AL2023
AMIs, uses `ssmmessages`; add it only for an older custom AMI).

Configuration that makes this work, all in the templates:

- Interface endpoints have `PrivateDnsEnabled: true`, so the standard service
  hostnames resolve to the endpoint ENIs; the VPC has `EnableDnsSupport` and
  `EnableDnsHostnames` (`vpc.yml`).
- Endpoint security group: inbound 443 from the app security group only. The
  app security group allows outbound 443 to `0.0.0.0/0`, which covers both the
  endpoint ENIs and the S3 prefix list.
- The S3 gateway endpoint is attached to `AppRouteTableA` and `AppRouteTableB`
  (the app subnets' route tables) with the default full-access policy. Verify
  in AWS with the `describe-vpc-endpoints` command above (`RouteTableIds` must
  list both app route tables).
- `EndpointAzMode=single` (dev) puts every interface endpoint in AZ a only;
  instances in AZ b use it across AZs.

### Docker on Amazon Linux 2023 without NAT

The standard AL2023 AMI does **not** include Docker. The user data uses Docker
from the AMI if present, and otherwise runs `dnf install docker`, which can
only succeed through the S3 gateway endpoint:

- AL2023 repositories are S3 buckets (`al2023-repos-<region>-<id>`), reached
  through the `mirrorlist` in `/etc/yum.repos.d/amazonlinux.repo`. AWS
  documents installing packages without internet access through an S3 gateway
  endpoint whose policy allows those buckets
  ([AWS re:Post](https://repost.aws/knowledge-center/ec2-al1-al2-update-yum-without-internet)).
- The repository URLs use **S3 dual-stack hostnames**. They resolve to public
  S3 addresses; a gateway endpoint still carries them, because it routes by
  the S3 prefix list. An *interface* S3 endpoint with private DNS does not
  cover them, and a NACL that blocks S3 address ranges breaks them
  ([amazon-linux-2023#535](https://github.com/amazonlinux/amazon-linux-2023/issues/535)).
  This VPC uses the gateway endpoint and default NACLs.
- `/etc/dnf/vars/releasever` must not be overridden; the AMI pins the
  repository release, so a given AMI always installs the same Docker build.

This path is documented by AWS but **unverified in this account**. If it
fails, the instance completes its readiness hook with `ABANDON`, never joins
the target group, and the boot log says `Bootstrap failed`. Verify it once,
right after the first compute deployment (Session Manager on an instance):

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://al2023-repos-us-east-2-de612dc2.s3.dualstack.us-east-2.amazonaws.com/
#   any HTTP status (typically 403: anonymous listing is denied) = S3 reachable
#   timeout = no S3 path: check the gateway endpoint route and NACLs
sudo dnf makecache && rpm -q docker
```

**Custom AMI (recommended for prod, removes the dnf dependency).** Build an
x86_64 AL2023 AMI with EC2 Image Builder (or Packer) that has:

- `docker` installed and enabled (`systemctl enable docker`);
- AWS CLI v2 (part of the standard AL2023 AMI; needed for `docker login` and the
  readiness hook) and SSM Agent;
- optionally the application image pre-pulled, for faster boots.

The build itself needs package access (a build subnet with internet access,
or the same S3 gateway endpoint), but the app instances then download nothing
at boot. Deploy it with `--ami ami-...`, or publish the ID to an SSM parameter
and use `AMI_SSM_PARAMETER=/ecommerce/dev/app-ami ./scripts/deploy.sh ... --ami latest`.

### Building and pushing the image

```bash
AWS_PROFILE=ecommerce-dev ./scripts/push-image.sh dev        # tag = current git commit SHA
AWS_PROFILE=ecommerce-dev ./scripts/push-image.sh dev --tag <tag>
```

The script builds `app/` with `docker buildx build --platform linux/amd64
--provenance=false --sbom=false`, pushes it, verifies it with
`scripts/check-image.sh` and prints the digest for `deploy.sh --image`.

Both flags matter:

- **`--provenance=false --sbom=false`** - by default buildx attaches attestation
  manifests to the image. Pushed to this repository (`IMMUTABLE` tags), the tag
  can end up on the attestation manifest - one `application/vnd.in-toto+json`
  layer, platform `unknown/unknown` - while the image manifest itself is
  rejected with `ImageTagAlreadyExistsException`. `docker pull` then fails with
  `unsupported media type application/vnd.in-toto+json`. This is what broke
  the first compute deployment.
- **`--platform linux/amd64`** - t3 instances run x86_64; an image built on an
  Apple silicon Mac is `linux/arm64` by default and would fail with `exec
  format error`.

Check any reference by hand (read-only):

```bash
AWS_PROFILE=ecommerce-dev ./scripts/check-image.sh ecommerce-dev-api <tag|sha256:digest>
```

A tag that points at a broken artifact cannot be reused (immutable tags):
push under a new tag, or delete the broken image first
(`aws ecr batch-delete-image --repository-name ecommerce-dev-api --image-ids imageTag=<tag>`).

### Docker image startup

The image is selected with `--image`: a digest (`sha256:...`, preferred) or an
immutable tag such as the git SHA. Only the digest or tag is passed; the
registry is built from the account and region the stack runs in, and the
repository from the naming convention, so no account ID is committed.

New instances are held in `Pending:Wait` by the `app-ready` launch lifecycle
hook (timeout 600 s, default result `ABANDON`). On first boot the user data
(output in `/var/log/cloud-init-output.log`):

1. uses Docker from the AMI or installs it with dnf, and starts it;
2. logs in to ECR, pulls the image and logs out. Transient errors are retried
   (5 attempts with backoff); errors a retry cannot fix (`unsupported media
   type`, `no matching manifest`, `not found`, `denied`) fail at once. The
   pulled image's platform must match the instance (`linux/amd64`);
3. writes `/etc/<project>/app.env` (`APP_ENV`, `APP_VERSION`, `UVICORN_PORT`,
   `UVICORN_FORWARDED_ALLOW_IPS`) and a `<project>-app` systemd unit with
   `Restart=always`, enabled at boot - the container comes back after a crash
   or reboot using the local image;
4. waits up to 120 s for `GET /health` on the instance;
5. completes the hook with `CONTINUE`; the instance enters `InService` and is
   registered with the target group. Any failure prints
   `BOOTSTRAP FAILED during step '<step>'` and completes the hook with
   `ABANDON`; Auto Scaling replaces the instance.

The bootstrap output is uploaded to CloudWatch Logs, log group
`/ecommerce/dev/app`, stream `bootstrap/<instance-id>`, before the hook is
completed, on failure and on success. It survives the instance's termination,
though not the deletion of the stack, which deletes the log group.

### Required parameters

| Parameter | Where | dev value |
|-----------|-------|-----------|
| `AppImageReference` | `--image` | image digest or tag in `ecommerce-dev-api` |
| `AppAmiId` | `--ami` (pinned automatically) | AL2023 x86_64 AMI ID |
| `AlbTestIngressCidr` | `--param` (optional, never committed) | your IP as `/32` |
| `NatGatewayMode` | parameters.json (new stacks) / deployed value | `none` |
| `AsgMinSize` / `AsgDesiredCapacity` / `AsgMaxSize` | parameters.json | `1` / `2` / `4` |
| `AppInstanceType` | parameters.json | `t3.micro` |
| `AppContainerPort` / `AppHealthCheckPath` | parameters.json | `8080` / `/health` |
| `AlbCertificateArn` | parameters.json | empty = HTTP 80 listener |
| `VpcEndpointAzMode` | parameters.json | `single` (prod: `per-az`) |
| `EnableSessionManager` | parameters.json | `true` |

### Deployment order

1. **Verify the deployed network** with the read-only commands in
   [NAT Gateway](#nat-gateway-verify-the-deployed-configuration-first).
   The root stack `ecommerce-dev` must own the VPC; if the VPC is in a
   standalone stack, deploying the root stack would create a second VPC.
2. **ECR repository** (separate stack, once). Skip if `ecommerce-dev-api`
   already exists; check which stack owns it:
   ```bash
   aws ecr describe-repositories --region us-east-2 --repository-names ecommerce-dev-api
   aws cloudformation describe-stack-resources --region us-east-2 \
     --physical-resource-id ecommerce-dev-api
   ```
3. **Push an image** with `scripts/push-image.sh` (see
   [Building and pushing the image](#building-and-pushing-the-image)); it
   prints the digest to deploy.
4. **Network stage** - preview only, to confirm the deployed stack has no
   drift from the templates: `./scripts/deploy.sh dev --stage network`
   (add `--param NatGatewayMode=<deployed value>` if it differs from the file).
   Expect `SecurityGroupsStack Modify` (new parameter, no resource changes) and
   nothing else.
5. **Compute stage** - change set first, review, then execute the reviewed one:
   ```bash
   ./scripts/deploy.sh dev --stage compute --image sha256:<digest> \
     --param AlbTestIngressCidr="$(curl -s https://checkip.amazonaws.com)/32"
   aws cloudformation execute-change-set --region us-east-2 --change-set-name '<id printed above>'
   aws cloudformation wait stack-update-complete --region us-east-2 --stack-name ecommerce-dev
   ```

### Reviewing the change set

`deploy.sh` prints every change, nested stacks included. For the compute
stage on top of a deployed network stage, expect:

| Stack | Changes |
|-------|---------|
| root | `Add` EndpointsStack, IamStack, LoadBalancerStack, LaunchTemplateStack, AutoScalingStack; `Modify` SecurityGroupsStack |
| SecurityGroupsStack | nothing, or `Add AlbTestIngress` with `AlbTestIngressCidr` |
| NetworkStack | **not listed** |
| new stacks | `Add` only |

Any `NetworkStack` line, a `Remove`, or `replacement=True` outside the new
stacks means the parameters differ from what is deployed: stop and compare.
`deploy.sh` blocks the network cases itself. To inspect a change set again:

```bash
aws cloudformation describe-change-set --region us-east-2 --change-set-name '<id>' \
  --query 'Changes[].ResourceChange.[Action,LogicalResourceId,Replacement,ChangeSetId]' --output table
```

### Health-check verification

```bash
STACK=ecommerce-dev
out() { aws cloudformation describe-stacks --region us-east-2 --stack-name $STACK \
  --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text; }

aws autoscaling describe-auto-scaling-instances --region us-east-2 \
  --query "AutoScalingInstances[?AutoScalingGroupName=='$(out AutoScalingGroupName)'].[InstanceId,LifecycleState,HealthStatus]" --output table
aws elbv2 describe-target-health --region us-east-2 --target-group-arn "$(out TargetGroupArn)" \
  --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State,TargetHealth.Reason]' --output table
curl -i "$(out AlbUrl)/health"          # needs AlbTestIngressCidr, or CloudFront
curl -s "$(out AlbUrl)/" | jq .         # version shows the deployed image reference
```

Instances show `Pending:Wait` while bootstrapping (1-3 minutes), then
`InService`; their targets go `initial` -> `healthy` within ~30 s.

### Scaling behaviour

- Capacity 1-4, starting at 2. Target tracking keeps average CPU near 60%:
  above it, instances are added; well below it for ~15 minutes, removed.
- `DefaultInstanceWarmup` (120 s) keeps new instances out of the average until
  they have settled.
- `HealthCheckType: ELB`, grace period 60 s after `InService` (bootstrapping
  is already done by then): an instance failing `/health` is replaced.
- t3 instances use **standard** CPU credits: no surplus charges, but a
  sustained load above the ~10% baseline is throttled when credits run out.

### Rolling out a new image or AMI

Deploy with a new `--image` (or `--ami`). The launch template gets a new
version, the Auto Scaling group's `LaunchTemplate` property changes, and its
`AutoScalingInstanceRefresh` update policy makes CloudFormation run an
instance refresh as part of the stack update:

1. launch replacements first (`MinHealthyPercentage 100`,
   `MaxHealthyPercentage 200`, the group's instance maintenance policy);
2. each replacement must complete the readiness hook (container healthy), pass
   the ELB health check and the 120 s warmup;
3. then the old instances are deregistered (30 s drain) and terminated.

If a replacement is abandoned or the `<project>-<env>-app-unhealthy-hosts`
alarm fires, the refresh fails, the stack update fails, and CloudFormation
rolls back, running another refresh to the previous launch template version.
A changed image or AMI is announced by `deploy.sh` before the change set is
created; nothing else (scaling settings, log retention, ...) replaces
instances.

Notes from the [AWS documentation](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-attribute-updatepolicy.html#cfn-attributes-updatepolicy-instancerefresh):
only one refresh can run per group, so do not start a manual refresh during a
stack update; the stack's temporary credentials must outlast the refresh
(~10 minutes here).

**Optional operational tool** - replace instances without a template change,
e.g. to recover from a bad host. Not part of the deployment process:

```bash
aws autoscaling start-instance-refresh --region us-east-2 \
  --auto-scaling-group-name ecommerce-dev-app-asg \
  --preferences '{"MinHealthyPercentage":100,"MaxHealthyPercentage":200,"SkipMatching":false,"AutoRollback":true}'
aws autoscaling describe-instance-refreshes --region us-east-2 \
  --auto-scaling-group-name ecommerce-dev-app-asg --max-records 1
```

### Troubleshooting

| Symptom | Check |
|---------|-------|
| Instances stay `Pending:Wait`, then terminate | Bootstrap failed: read the `bootstrap/<instance-id>` log stream or the console output (see [Diagnosing a failed launch](#diagnosing-a-failed-launch)); the `BOOTSTRAP FAILED during step` line names the step |
| `unsupported media type application/vnd.in-toto+json` | The tag points at a BuildKit attestation, not an image. Push with `scripts/push-image.sh` |
| `exec format error`, or `Image platform is linux/arm64` | Image built for arm64; push with `scripts/push-image.sh` (`linux/amd64`) |
| `dnf install docker` fails or times out | S3 gateway endpoint missing from the app route tables, a restrictive endpoint policy, or NACLs; `/etc/dnf/vars/releasever` must not be overridden. Or use a custom AMI with Docker |
| `docker login`/`pull` times out | `ecr.api`/`ecr.dkr` endpoints `available` with private DNS; endpoint security group allows 443 from the app security group |
| `pull` fails with `AccessDenied` or `not found` | Image reference and repository name (`<project>-<env>-api`); the instance role only reads that repository |
| `Could not complete the lifecycle hook` in the boot log | `autoscaling` endpoint; the instance is abandoned when the hook times out (600 s) |
| No log stream in `/ecommerce/dev/app` | `logs` endpoint; container start fails if the awslogs driver cannot reach it |
| Targets `unhealthy` after `InService` | `sudo systemctl status ecommerce-app`, `sudo journalctl -u ecommerce-app` |
| Instance not in Session Manager | `ssm`/`ssmmessages` endpoints; older SSM agents also need `ec2messages` |
| Stack update fails during instance refresh | `aws autoscaling describe-instance-refreshes ...` (`StatusReason`); the stack rolls back on its own |
| `curl` to the ALB hangs | ALB only admits CloudFront and `AlbTestIngressCidr`; your IP may have changed |

### Diagnosing a failed launch

All read-only; they work after the instances are terminated (CloudTrail keeps
90 days, scaling activities of deleted groups ~6 weeks, console output for a
while after termination).

```bash
export AWS_PROFILE=ecommerce-dev AWS_REGION=us-east-2

# 1. Why instances were removed (also for deleted groups)
aws autoscaling describe-scaling-activities --auto-scaling-group-name ecommerce-dev-app-asg \
  --include-deleted-groups --query 'Activities[].[StartTime,StatusCode,Description,StatusMessage]' --output text
#    "Lifecycle Action Completed with ABANDON Result" = the instance gave up (bootstrap failure);
#    a heartbeat timeout after 600 s = the instance never reported back.

# 2. Who completed the hook, and every API call one instance made (ECR, S3, logs, SSM)
aws cloudtrail lookup-events --lookup-attributes AttributeKey=EventName,AttributeValue=CompleteLifecycleAction \
  --query 'Events[].CloudTrailEvent' --output text \
  | jq -r '[.eventTime,.requestParameters.instanceId,.requestParameters.lifecycleActionResult,(.errorCode//"ok")]|@tsv'
aws cloudtrail lookup-events --lookup-attributes AttributeKey=Username,AttributeValue=<instance-id> \
  --query 'Events[].CloudTrailEvent' --output text \
  | jq -r '[.eventTime,.eventSource,.eventName,(.errorCode//"ok"),(.vpcEndpointId//"-")]|@tsv' | sort

# 3. The bootstrap output
aws logs get-log-events --log-group-name /ecommerce/dev/app --log-stream-name bootstrap/<instance-id> \
  --query 'events[].message' --output text
aws ec2 get-console-output --instance-id <instance-id> --latest --query Output --output text \
  | grep -aE 'cloud-init|BOOTSTRAP|Attempt|error'

# 4. Live, while an instance is in Pending:Wait
aws autoscaling describe-auto-scaling-instances \
  --query "AutoScalingInstances[?AutoScalingGroupName=='ecommerce-dev-app-asg'].[InstanceId,LifecycleState]"
aws logs tail /ecommerce/dev/app --follow --log-stream-name-prefix bootstrap/
```

While instances keep being abandoned, CloudFormation waits for the group to
reach its desired capacity until `AutoScalingStack` times out (30 minutes),
then rolls back - deleting the log group. Read the evidence before the
rollback completes, or from the console output and CloudTrail afterwards.

## Cleanup and cost

Hourly costs of the compute stage in dev (us-east-2, on-demand, approximate):

| Resource | Hourly | Monthly |
|----------|--------|---------|
| ALB (+ ~1 LCU at light load) | ~$0.023 + ~$0.008 | ~$22 |
| ALB public IPv4 addresses (2) | $0.010 | ~$7 |
| EC2 t3.micro x 2 (+ 8 GB gp3 each) | ~$0.021 | ~$16 |
| Interface endpoints: 6 x 1 AZ ($0.01 each) | $0.060 | ~$44 |
| Endpoint data processing, CloudWatch Logs, ECR storage, 1 alarm | usage | ~$1-2 |
| **Total** | **~$0.12** | **~$88** |

Endpoint options (dev, `EndpointAzMode`/`EnableSessionManager`):

| Endpoints | single AZ | per AZ |
|-----------|-----------|--------|
| 4 required (ecr.api, ecr.dkr, logs, autoscaling) | $0.04/h, ~$29/month | $0.08/h, ~$58/month |
| + 2 Session Manager (ssm, ssmmessages) | $0.06/h, ~$44/month | $0.12/h, ~$88/month |

For comparison, one NAT Gateway is $0.045/h (~$33/month) plus $0.045/GB and
gives internet access; the endpoints are still needed for private access in
prod.

Remove the compute stage when you stop testing; the VPC and security groups
stay:

```bash
./scripts/deploy.sh dev --stage network --allow-shrink            # review: Remove x 5 nested stacks
./scripts/deploy.sh dev --stage network --allow-shrink --execute
```

This deletes the endpoints, IAM role, ALB, launch template, Auto Scaling group
(instances), alarm and the app log group. To remove everything, use
`./scripts/destroy.sh dev`. Neither touches the `ecommerce-dev-ecr` stack or
its images (ECR storage is ~$0.10/GB-month). Afterwards, check that nothing is
left running:

```bash
aws ec2 describe-instances --region us-east-2 \
  --filters Name=tag:Project,Values=aws-ecommerce Name=instance-state-name,Values=pending,running \
  --query 'Reservations[].Instances[].InstanceId'
aws ec2 describe-vpc-endpoints --region us-east-2 --query 'VpcEndpoints[].[VpcEndpointId,ServiceName]'
aws elbv2 describe-load-balancers --region us-east-2 --query 'LoadBalancers[].LoadBalancerName'
```

## Destroy

```bash
./scripts/destroy.sh dev
./scripts/destroy.sh prod --allow-prod
```

Resources with `Retain`/`Snapshot` deletion policies (S3 buckets, final RDS
snapshot) survive and must be removed manually if no longer needed. The
separate `<stack>-ecr` and `<stack>-waf` stacks are not deleted.

## IAM permissions for the deploying user

Without `AdministratorAccess`, the compute stage needs (scope to the project's
resources where the service allows it):

- `cloudformation:*` on `arn:aws:cloudformation:us-east-2:<account>:stack/ecommerce-dev*/*`
  and `changeSet/*` (create, describe, execute and delete change sets, nested
  ones included), plus `cloudformation:ValidateTemplate`
- `s3:PutObject`, `s3:GetObject` on the artifact bucket
- `ec2:Describe*`, `ec2:CreateVpcEndpoint`, `ec2:DeleteVpcEndpoints`,
  `ec2:ModifyVpcEndpoint`, `ec2:CreateSecurityGroup`, `ec2:DeleteSecurityGroup`,
  `ec2:AuthorizeSecurityGroupIngress/Egress`, `ec2:RevokeSecurityGroupIngress/Egress`,
  `ec2:CreateLaunchTemplate`, `ec2:CreateLaunchTemplateVersion`,
  `ec2:DeleteLaunchTemplate`, `ec2:RunInstances`, `ec2:CreateTags`,
  `ssm:GetParameter` (AMI parameter, read by `deploy.sh`)
- `elasticloadbalancing:*` on the project's ALB, target group and listeners
- `autoscaling:*` on `ecommerce-dev-app-asg` (including
  `StartInstanceRefresh`/`CancelInstanceRefresh` for the update policy and
  `PutLifecycleHook`), plus `autoscaling:Describe*`
- `cloudwatch:PutMetricAlarm`, `cloudwatch:DeleteAlarms`, `cloudwatch:DescribeAlarms`
  on `arn:aws:cloudwatch:us-east-2:<account>:alarm:ecommerce-dev-*`
- `iam:CreateRole`, `iam:DeleteRole`, `iam:PutRolePolicy`, `iam:DeleteRolePolicy`,
  `iam:AttachRolePolicy`, `iam:DetachRolePolicy`, `iam:GetRole`,
  `iam:CreateInstanceProfile`, `iam:DeleteInstanceProfile`,
  `iam:AddRoleToInstanceProfile`, `iam:RemoveRoleFromInstanceProfile` on
  `arn:aws:iam::<account>:role/ecommerce/dev/*` and `instance-profile/ecommerce/dev/*`,
  and `iam:PassRole` on `role/ecommerce/dev/*` (condition
  `iam:PassedToService = ec2.amazonaws.com`)
- `iam:CreateServiceLinkedRole` for `elasticloadbalancing.amazonaws.com` and
  `autoscaling.amazonaws.com` (first use in the account only)
- `logs:CreateLogGroup`, `logs:DeleteLogGroup`, `logs:PutRetentionPolicy`,
  `logs:DescribeLogGroups` on `/ecommerce/dev/*`
- `ecr:DescribeImages`, `ecr:BatchGetImage`, `ecr:GetDownloadUrlForLayer`
  (read-only image check in `deploy.sh` / `check-image.sh`); for
  `push-image.sh` also `ecr:GetAuthorizationToken`, `ecr:InitiateLayerUpload`,
  `ecr:UploadLayerPart`, `ecr:CompleteLayerUpload`, `ecr:PutImage` and
  `ecr:BatchCheckLayerAvailability` on the repository

## GitHub Actions

| Workflow                      | Trigger                                 | AWS access |
|-------------------------------|-----------------------------------------|------------|
| `validate-infrastructure.yml` | PR / push to `main` touching IaC files  | Optional read-only OIDC role for `validate-template` |
| `deploy-infrastructure.yml`   | Manual `workflow_dispatch` only (environment, stage, image) | OIDC deploy role per GitHub Environment |
| `app-ci.yml`                  | PR / push to `main` touching `app/`     | None: pytest and `docker build` only |

### One-time setup (when ready)

1. **Bootstrap the AWS account** (TODO: `bootstrap/` template):
   - IAM OIDC identity provider for `token.actions.githubusercontent.com`
   - Deploy role trusted only by `repo:<owner>/aws-ecommerce-infrastructure:environment:<env>`
   - Optional read-only validation role for pull requests
   - Versioned, encrypted S3 bucket for packaged templates
2. **Create GitHub Environments** `dev` and `prod`; add required reviewers to `prod`.
3. **Set variables** (Settings -> Secrets and variables -> Actions -> *Variables*;
   none of these are secrets):

   | Variable                | Scope       | Example |
   |-------------------------|-------------|---------|
   | `AWS_DEPLOY_ROLE_ARN`   | environment | `arn:aws:iam::123456789012:role/gha-deploy-dev` |
   | `CFN_ARTIFACT_BUCKET`   | environment | `ecommerce-cfn-artifacts-123456789012` |
   | `AWS_REGION`            | repository  | `us-east-2` |
   | `AWS_VALIDATE_ROLE_ARN` | repository  | optional; enables the API validation job |
   | `INFRA_DEPLOY_ENABLED`  | repository  | `true` - **only** once templates are implemented |

## Application (`app/`)

The FastAPI application is part of this repository. Its CI (`app-ci.yml`) is
independent of the infrastructure workflows: it runs only when `app/` changes,
runs pytest and checks that the Docker image builds. It has no AWS access.

### Build, test and run locally

```bash
cd app
python3.13 -m venv .venv && source .venv/bin/activate
pip install -r requirements-dev.txt
pytest
uvicorn main:app --reload --port 8080
```

### Docker

```bash
docker build -t ecommerce-api ./app
docker run --rm -p 8080:8080 ecommerce-api
curl http://localhost:8080/health      # {"status":"healthy"}
```

### Runtime contract with the infrastructure

| Setting | Value on AWS | Source |
|---------|--------------|--------|
| Container port | `8080` | `AppContainerPort` (security groups, ALB target group); `UVICORN_PORT` in the container |
| Health check | `GET /health` -> 200 | `AppHealthCheckPath`; never depends on the database |
| Trusted proxies | VPC CIDR, e.g. `10.10.0.0/16` | `UVICORN_FORWARDED_ALLOW_IPS`, from `NetworkStack.Outputs.VpcCidr`; see [security.md](security.md) |
| Environment | `dev` / `prod` | `APP_ENV` |
| Version | image digest or tag | `APP_VERSION`, shown by `GET /` |
| Logs | stdout/stderr | Docker `awslogs` driver -> `/<project>/<env>/app`, one stream per instance |

The ALB listener port (80 or 443) is configured separately and does not change
when `AppContainerPort` does.

### Release flow

1. Build the image and push it to `<project>-<env>-api`, tagged with the git
   commit SHA (tags are immutable), with `scripts/push-image.sh`. An App CI
   push job with a GitHub OIDC role is planned.
2. Deploy the compute stage with `--image <digest>`: a new launch template
   version, rolled out by the CloudFormation-managed instance refresh.
3. At runtime the app reads its configuration from environment variables; in
   the full stage, secrets will come from Secrets Manager.
