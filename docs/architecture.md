# Architecture

> **Status:** design target. The CloudFormation templates are scaffolding
> (`ImplementationStatus: PLACEHOLDER`); none of the resources below exist yet.

## Overview

A classic three-tier, two-AZ web architecture for the
[python-ecommerce-app](https://github.com/) FastAPI service
(TODO: replace with the real repository URL).

```mermaid
flowchart TB
    user([Customer browser]) --> cf[CloudFront]
    waf[AWS WAF<br/>managed rules + rate limit] -. protects .- cf
    cf -- "/static/* (OAC)" --> s3[(S3 assets bucket)]
    cf -- "API, HTTPS + origin header" --> alb

    subgraph vpc[VPC - 2 Availability Zones]
        subgraph public[Public subnets]
            alb[Application Load Balancer]
            nat[NAT Gateway per AZ]
        end
        subgraph app[Private app subnets]
            asg[Auto Scaling group<br/>EC2 + Docker]
        end
        subgraph data[Private data subnets - no internet route]
            rds[(RDS PostgreSQL<br/>Multi-AZ)]
        end
    end

    alb --> asg
    asg --> rds
    asg -- outbound via --> nat
    asg -. pull image .-> ecr[(Amazon ECR)]
    asg -. read secrets .-> sm[Secrets Manager]
    cw[CloudWatch alarms] --> sns[SNS alerts]
    trail[CloudTrail] --> logs[(Audit log bucket)]
```

## Request flow

1. The client connects to **CloudFront** over HTTPS; **WAF** evaluates the request.
2. `/static/*` is served from the private **S3** assets bucket via Origin Access Control.
3. Everything else is forwarded to the **ALB**, which only accepts traffic from the
   CloudFront origin-facing prefix list and carrying a secret origin header.
4. The ALB forwards to healthy **EC2** instances in the private app subnets.
5. The app talks to **RDS PostgreSQL** in isolated data subnets on port 5432.

## Network layout (per environment)

| Tier    | Subnets       | Route to internet     | Hosts                     |
|---------|---------------|-----------------------|---------------------------|
| Public  | public-a / -b | Internet Gateway      | ALB, NAT Gateway(s)       |
| App     | app-a / -b    | NAT Gateway (egress)  | EC2 Auto Scaling group    |
| Data    | data-a / -b   | none                  | RDS primary + standby     |

`dev` uses `10.10.0.0/16` and a single NAT Gateway; `prod` uses `10.20.0.0/16` and
one NAT Gateway per AZ.

## Stack layout

`cloudformation/main.yml` is the root stack. It creates one nested stack per
component and wires them together with `!GetAtt <Stack>.Outputs.<Name>`.

| Nested stack           | Template                       | Depends on                         |
|------------------------|--------------------------------|------------------------------------|
| NetworkStack           | network/vpc.yml                | -                                  |
| SecurityGroupsStack    | network/security-groups.yml    | Network                            |
| AlertingStack          | monitoring/sns.yml             | -                                  |
| SecretsStack           | security/secrets.yml           | -                                  |
| StorageStack           | storage/s3.yml                 | -                                  |
| ContainerRegistryStack | storage/ecr.yml                | -                                  |
| DatabaseStack          | database/rds.yml               | Network, SecurityGroups            |
| IamStack               | security/iam.yml               | Secrets, Storage, ECR, Database    |
| LoadBalancerStack      | compute/alb.yml                | Network, SecurityGroups, Storage   |
| LaunchTemplateStack    | compute/ec2.yml                | SecurityGroups, IAM, ECR, Secrets  |
| AutoScalingStack       | compute/autoscaling.yml        | Network, LoadBalancer, LaunchTemplate |
| WafStack               | networking/waf.yml             | -                                  |
| CdnStack               | networking/cloudfront.yml      | LoadBalancer, Storage, WAF         |
| MonitoringStack        | monitoring/cloudwatch.yml      | Alerting, LoadBalancer, ASG, Database |

`network/` holds in-VPC networking; `networking/` holds the edge layer
(CloudFront, WAF).

## Conventions

**Naming** - `<ProjectName>-<Environment>-<component>`, e.g. `ecommerce-dev-alb`.
Globally unique names (S3) append `<account-id>-<region>`. IAM roles are *not*
explicitly named so CloudFormation can replace them safely; they use the path
`/<ProjectName>/<Environment>/` instead.

**Tagging** - stack-level tags from `environments/<env>/parameters.json` are applied
by `scripts/deploy.sh` and propagate to all nested stacks and taggable resources:

| Tag          | Example                        |
|--------------|--------------------------------|
| Project      | aws-ecommerce                  |
| Environment  | dev / prod                     |
| Owner        | platform-team                  |
| CostCenter   | portfolio                      |
| ManagedBy    | CloudFormation                 |
| Repository   | aws-ecommerce-infrastructure   |
| Component    | network, database, ... (set per nested stack in `main.yml`) |

**Cross-stack references** - nested stack outputs only; no CloudFormation
Exports, so `dev` and `prod` cannot become coupled.

**Region** - `us-east-1`, because a WAF web ACL attached to CloudFront must be
created there.

## Well-Architected mapping

| Pillar                 | How this design addresses it |
|------------------------|------------------------------|
| Operational excellence | All infrastructure as code, CI validation, change sets reviewed before execution |
| Security               | Private app/data tiers, least-privilege IAM, no SSH (SSM), encryption everywhere, WAF, secrets in Secrets Manager, OIDC instead of access keys |
| Reliability            | Two AZs, Multi-AZ RDS, ASG with ELB health checks, NAT per AZ in prod |
| Performance efficiency | CloudFront caching for static assets, target-tracking scaling, Graviton (t4g) RDS |
| Cost optimization      | Environment-sized parameters (single NAT, single-AZ DB in dev), log retention, ECR lifecycle |
| Sustainability         | Right-sized burstable instances, scale-in when idle |
