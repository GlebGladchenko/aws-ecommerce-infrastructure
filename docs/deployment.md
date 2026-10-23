# Deployment

> **Deployment is currently disabled.** All templates are placeholders and
> `scripts/deploy.sh` refuses to run until every template is marked
> `ImplementationStatus: IMPLEMENTED`.

## Prerequisites (local)

- AWS CLI v2, `jq`, `cfn-lint` (`pip install cfn-lint`), optionally `shellcheck`
- Credentials for the target account through AWS IAM Identity Center
  (`aws sso login`), not long-lived access keys

## Validate (safe, offline)

```bash
./scripts/validate.sh          # cfn-lint, parameter files, shellcheck
./scripts/validate.sh --aws    # + read-only `aws cloudformation validate-template`
```

## Deploy

```bash
export CFN_ARTIFACT_BUCKET=<bootstrap-artifact-bucket>
./scripts/deploy.sh dev              # create a change set only
./scripts/deploy.sh dev --execute    # create and execute it
```

`deploy.sh`:

1. Refuses to continue if any template is still a placeholder.
2. Runs `validate.sh`.
3. Asks you to type the stack name for `prod` (skipped with `--yes` in CI).
4. Runs `aws cloudformation package` to upload nested templates to S3 and rewrite
   `TemplateURL`s.
5. Runs `aws cloudformation deploy` with parameters and tags from
   `environments/<env>/parameters.json`. It creates a change set without executing
   it unless `--execute` is given.

The stack is named `<ProjectName>-<Environment>`, e.g. `ecommerce-dev`.

## Destroy

```bash
./scripts/destroy.sh dev
./scripts/destroy.sh prod --allow-prod
```

Resources with `Retain`/`Snapshot` deletion policies (S3 buckets, ECR, final RDS
snapshot) survive and must be removed manually if no longer needed.

## GitHub Actions

| Workflow                      | Trigger                                 | AWS access |
|-------------------------------|-----------------------------------------|------------|
| `validate-infrastructure.yml` | PR / push to `main` touching IaC files  | Optional read-only OIDC role for `validate-template` |
| `deploy-infrastructure.yml`   | Manual `workflow_dispatch` only         | OIDC deploy role per GitHub Environment |
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
| Trusted proxies | VPC CIDR, e.g. `10.10.0.0/16` | `UVICORN_FORWARDED_ALLOW_IPS`; see [security.md](security.md) |
| Environment | `dev` / `prod` | `APP_ENV` |
| Logs | stdout/stderr | Docker `awslogs` driver or CloudWatch agent |

The ALB listener port (80 or 443) is configured separately and does not change
when `AppContainerPort` does.

### Planned release flow

1. App CI builds the image and pushes it to the ECR repository created here,
   tagged with the git commit SHA (tags are immutable). Not implemented yet.
2. The image tag is passed to the launch template (planned `AppImageTag`
   parameter), and an Auto Scaling instance refresh rolls it out.
3. At runtime the app reads its configuration from environment variables and its
   secrets from Secrets Manager.
