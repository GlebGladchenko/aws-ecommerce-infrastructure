# AWS E-Commerce Infrastructure

Infrastructure as Code (AWS CloudFormation) for a highly available, secure AWS
platform, plus the **FastAPI application** it hosts, in one repository
(`app/`).

> **Project status: network and compute stages implemented.**
> The VPC, security groups, ECR repository and the EC2 + ALB + Auto Scaling
> compute stage (with VPC endpoints instead of NAT) are implemented and can be
> deployed stage by stage with `scripts/deploy.sh --stage network|compute`.
> RDS, S3, Secrets Manager, CloudFront, WAF and monitoring are still
> placeholders, so the `full` stage stays blocked.

## Goals

This is a portfolio project that demonstrates:

- **Infrastructure as Code**: modular nested CloudFormation stacks, parameters,
  outputs and environment-specific configuration
- **High availability**: two Availability Zones, Multi-AZ RDS, Auto Scaling behind an ALB
- **Security**: private subnets, least-privilege IAM, encryption at rest and in
  transit, Secrets Manager, WAF, no SSH, no long-lived CI credentials
- **CI/CD**: GitHub Actions with AWS OIDC, change-set-based deployments
- **Observability**: CloudWatch alarms and dashboards, SNS alerting, CloudTrail auditing

## Architecture

```
            Internet
               |
        [ CloudFront ] <-- [ AWS WAF ]
          |         \
          |          \--- /static/* ---> [ S3 assets (private, OAC) ]
          v
 +--------------------- VPC (2 AZs) ----------------------+
 |  Public subnets     [ ALB ]       [ NAT GW (optional) ] |
 |                        | :8080                         |
 |  Private app        [ EC2 Auto Scaling group (Docker) ]--> VPC endpoints:
 |                        |                               |   ECR, Logs, Auto Scaling, SSM, S3
 |  Private data       [ RDS PostgreSQL Multi-AZ ]        |
 +--------------------------------------------------------+
     CloudWatch alarms -> SNS        CloudTrail -> S3
```

See [docs/architecture.md](docs/architecture.md) for the full design, network
layout, stack dependencies and naming/tagging conventions.

## AWS services

| Service | Role |
|---------|------|
| VPC, subnets, IGW, NAT Gateway | Two-AZ network with public, private app and isolated data tiers |
| Application Load Balancer | Distributes traffic to healthy app instances |
| EC2 Launch Templates + Auto Scaling | Self-healing, horizontally scaling app hosts |
| Amazon ECR | Container registry for the application image |
| Amazon RDS for PostgreSQL | Managed Multi-AZ relational database |
| Amazon S3 | Static assets and access logs |
| Amazon CloudFront | HTTPS edge, caching, single entry point |
| AWS WAF | Managed rule sets and rate limiting at the edge |
| AWS IAM | Least-privilege runtime roles; OIDC role for CI |
| AWS Secrets Manager + KMS | Generated, encrypted, rotatable secrets |
| CloudWatch, SNS, CloudTrail | Metrics, alarms, notifications, audit logging |

## Repository structure

```
app/                        FastAPI application, tests and Dockerfile (see app/README.md)
cloudformation/
  main.yml                  Root stack - orchestrates all nested stacks
  network/                  VPC, subnets, routing, security groups, VPC endpoints
  compute/                  Launch template, ALB, Auto Scaling group
  database/                 RDS PostgreSQL
  storage/                  S3 buckets, ECR repository (separate stack)
  security/                 IAM roles, Secrets Manager
  networking/               Edge: CloudFront, WAF
  monitoring/               CloudWatch alarms/dashboard, SNS topic
environments/
  dev/parameters.json       Cost-optimized sizing (no NAT, single-AZ endpoints and DB)
  prod/parameters.json      HA sizing (NAT per AZ, Multi-AZ DB)
scripts/
  validate.sh               Offline validation (cfn-lint, params, shellcheck)
  deploy.sh                 Package + deploy via change sets (guarded)
  push-image.sh             Build the app image (linux/amd64) and push it to ECR
  check-image.sh            Read-only check that an ECR image can run on the instances
  destroy.sh                Confirmed teardown of an environment
.github/workflows/
  app-ci.yml                    App tests + Docker build on changes to app/
  validate-infrastructure.yml   Runs on PRs and pushes to main
  deploy-infrastructure.yml     Manual, disabled by default, OIDC
docs/                       Architecture, security, deployment, cost estimate
```

## Getting started

### Infrastructure

```bash
pip install cfn-lint
./scripts/validate.sh
```

Validation is offline and makes no AWS calls unless you pass `--aws`.

Deploy stage by stage; every command creates a change set for review and
executes it only with `--execute`:

```bash
export CFN_ARTIFACT_BUCKET=<artifact-bucket>
./scripts/push-image.sh dev                                   # prints the image digest
./scripts/deploy.sh dev --stage network                       # VPC + security groups
./scripts/deploy.sh dev --stage compute --image sha256:<digest> \
  --param AlbTestIngressCidr=<your-ip>/32                      # + endpoints, IAM, ALB, EC2, ASG
```

The compute stage costs about $0.12/hour in dev. See
[docs/deployment.md](docs/deployment.md) for the deployment order, change set
review, health checks, scaling, troubleshooting and cleanup.

### Application

```bash
cd app
python3.13 -m venv .venv && source .venv/bin/activate
pip install -r requirements-dev.txt
pytest                                  # tests, no AWS or Docker needed
uvicorn main:app --reload --port 8080   # http://localhost:8080/docs
```

With Docker, from the repository root:

```bash
docker build -t ecommerce-api ./app
docker run --rm -p 8080:8080 ecommerce-api
```

See [app/README.md](app/README.md) for endpoints, configuration and the
planned PostgreSQL integration.

## Planned deployment workflow

1. Open a pull request. `validate-infrastructure.yml` lints every template,
   parameter file and script.
2. Merge to `main`.
3. Manually run **Deploy Infrastructure**, choosing an environment, stage and
   image. The workflow
   assumes an AWS role through OIDC (no stored keys) and creates a CloudFormation
   **change set** for review.
4. Re-run with *execute change set* to apply it. `prod` additionally requires
   approval through a GitHub Environment.

Full details, including the one-time OIDC bootstrap, are in
[docs/deployment.md](docs/deployment.md).

## Application and infrastructure contract

The FastAPI application lives in [`app/`](app/) in this repository. App and
infrastructure have separate CI workflows (`app-ci.yml` and
`validate-infrastructure.yml`), triggered by changes to their own paths.

- The app is packaged as a Docker image (`app/Dockerfile`, Python 3.13, non-root)
  and pushed to the `<project>-<env>-api` ECR repository by `scripts/push-image.sh`
  (`linux/amd64`, no build attestations), tagged with the git commit SHA. The
  compute stage runs it by digest or tag (`--image`).
- The container listens on port `8080` (`AppContainerPort`) and serves
  `GET /health` for the ALB target group, with no database dependency.
- Configuration comes from environment variables and secrets from Secrets
  Manager; nothing is baked into the image.
- On AWS, `UVICORN_FORWARDED_ALLOW_IPS` is set to the VPC CIDR so only the ALB's
  `X-Forwarded-*` headers are trusted (see [docs/security.md](docs/security.md)).

## Roadmap

- [x] Repository scaffolding, conventions, CI validation
- [x] FastAPI application (`app/`) with tests, Dockerfile and CI
- [x] Network: VPC, subnets, IGW, NAT, route tables, flow logs
- [x] Security groups
- [x] ECR repository
- [x] IAM instance role, VPC endpoints, ALB, launch template, Auto Scaling group
- [ ] S3, Secrets Manager
- [ ] RDS PostgreSQL Multi-AZ
- [ ] App image push from CI (GitHub OIDC)
- [ ] WAF and CloudFront
- [ ] SNS, CloudWatch alarms and dashboard, CloudTrail
- [ ] OIDC bootstrap template; enable the deployment workflow

## Documentation

- [Architecture](docs/architecture.md)
- [Security](docs/security.md)
- [Deployment](docs/deployment.md)
- [Cost estimation](docs/cost-estimation.md)
