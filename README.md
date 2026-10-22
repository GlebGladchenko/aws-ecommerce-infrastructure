# AWS E-Commerce Infrastructure

Infrastructure as Code (AWS CloudFormation) for a highly available, secure AWS
platform that hosts the **python-ecommerce-app** FastAPI service.

> **Project status: initial scaffolding.**
> The repository structure, conventions, parameters, scripts and CI skeletons are in
> place. Every CloudFormation template is a **placeholder** (`ImplementationStatus:
> PLACEHOLDER`) with TODOs describing the planned resources. No AWS resources have
> been created, and deployment is blocked both in `scripts/deploy.sh` and in
> GitHub Actions until the templates are implemented.

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
 |  Public subnets     [ ALB ]            [ NAT GW ]       |
 |                        |                   ^           |
 |  Private app        [ EC2 Auto Scaling group (Docker) ]--> ECR, Secrets Manager
 |                        |                               |
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
cloudformation/
  main.yml                  Root stack - orchestrates all nested stacks
  network/                  VPC, subnets, routing, security groups
  compute/                  Launch template, ALB, Auto Scaling group
  database/                 RDS PostgreSQL
  storage/                  S3 buckets, ECR repository
  security/                 IAM roles, Secrets Manager
  networking/               Edge: CloudFront, WAF
  monitoring/               CloudWatch alarms/dashboard, SNS topic
environments/
  dev/parameters.json       Cost-optimized sizing (single NAT, single-AZ DB)
  prod/parameters.json      HA sizing (NAT per AZ, Multi-AZ DB)
scripts/
  validate.sh               Offline validation (cfn-lint, params, shellcheck)
  deploy.sh                 Package + deploy via change sets (guarded)
  destroy.sh                Confirmed teardown of an environment
.github/workflows/
  validate-infrastructure.yml   Runs on PRs and pushes to main
  deploy-infrastructure.yml     Manual, disabled by default, OIDC
docs/                       Architecture, security, deployment, cost estimate
```

## Getting started

```bash
pip install cfn-lint
./scripts/validate.sh
```

Validation is offline and makes no AWS calls unless you pass `--aws`.

## Planned deployment workflow

1. Open a pull request. `validate-infrastructure.yml` lints every template,
   parameter file and script.
2. Merge to `main`.
3. Manually run **Deploy Infrastructure**, choosing an environment. The workflow
   assumes an AWS role through OIDC (no stored keys) and creates a CloudFormation
   **change set** for review.
4. Re-run with *execute change set* to apply it. `prod` additionally requires
   approval through a GitHub Environment.

Full details, including the one-time OIDC bootstrap, are in
[docs/deployment.md](docs/deployment.md).

## Relationship to python-ecommerce-app

| Repository | Owns |
|------------|------|
| **aws-ecommerce-infrastructure** (this repo) | Network, compute, database, storage, security, edge and monitoring |
| **python-ecommerce-app** | FastAPI source code, tests, Dockerfile, image build and push to ECR |

The contract between them:

- The app is packaged as a Docker image, pushed to the ECR repository created here,
  and tagged with its git commit SHA.
- The container listens on port `8000` (`AppContainerPort`) and serves `GET /health`.
- Database connection details and secrets come from Secrets Manager and environment
  variables; nothing is baked into the image.

## Roadmap

- [x] Repository scaffolding, conventions, CI validation
- [ ] Network: VPC, subnets, IGW, NAT, route tables, flow logs
      (template implemented in `network/vpc.yml`; test deployment pending)
- [ ] Security groups
- [ ] S3, ECR, Secrets Manager, IAM
- [ ] RDS PostgreSQL Multi-AZ
- [ ] ALB, launch template, Auto Scaling group
- [ ] WAF and CloudFront
- [ ] SNS, CloudWatch alarms and dashboard, CloudTrail
- [ ] OIDC bootstrap template; enable the deployment workflow

## Documentation

- [Architecture](docs/architecture.md)
- [Security](docs/security.md)
- [Deployment](docs/deployment.md)
- [Cost estimation](docs/cost-estimation.md)
