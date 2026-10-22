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

## Relationship to python-ecommerce-app

This repository provides the platform; the application repository ships the code.

1. The app repository's CI builds a Docker image and pushes it to the ECR
   repository created here, tagged with the git commit SHA (tags are immutable).
2. The image tag is passed to the launch template (planned `AppImageTag`
   parameter), and an Auto Scaling instance refresh rolls it out.
3. At runtime the app reads its configuration from environment variables and its
   secrets from Secrets Manager, and exposes `GET /health` for the ALB.
