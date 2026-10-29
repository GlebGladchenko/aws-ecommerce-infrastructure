# Cost Estimation

> **Illustrative only.** Approximate on-demand prices for `us-east-1` at the time of
> writing; AWS prices change. Nothing is deployed, so nothing is being billed.
> Validate with the [AWS Pricing Calculator](https://calculator.aws/) before deploying.

## Monthly estimate (~730 hours, light traffic)

| Component                         | dev                          | prod                              |
|-----------------------------------|------------------------------|-----------------------------------|
| NAT Gateway (hourly)              | none (`NatGatewayMode=none`) | 2 x ~$33 = ~$66                   |
| NAT data processing               | -                            | ~$0.045 / GB                      |
| Interface VPC endpoints (~$7.30 per endpoint per AZ) | 6 x 1 AZ ~$44 | 6 x 2 AZs ~$88          |
| Application Load Balancer         | ~$16 + LCUs                  | ~$16 + LCUs                       |
| EC2 instances                     | 2 x t3.micro ~$15            | 2 x t3.small ~$30                 |
| EBS (gp3, 8-20 GB per instance)   | ~$1-2                        | ~$2-4                             |
| RDS PostgreSQL                    | db.t4g.micro single-AZ ~$12  | db.t4g.small Multi-AZ ~$47        |
| RDS storage (gp3)                 | 20 GB ~$2-3                  | 50 GB Multi-AZ ~$12               |
| Public IPv4 addresses (~$3.65 ea) | 2 (ALB) -> ~$7               | ~4 -> ~$15                        |
| AWS WAF (ACL + ~5 rules)          | ~$10 + $0.60 / M requests    | ~$10 + $0.60 / M requests         |
| CloudFront                        | free tier usually covers it  | free tier, then per GB            |
| KMS keys (~4 x $1)                | ~$4                          | ~$4                               |
| Secrets Manager (~2 x $0.40)      | ~$1                          | ~$1                               |
| CloudWatch alarms, logs, dashboard| ~$5                          | ~$10-15                           |
| S3, ECR, CloudTrail (1st trail)   | ~$1-2                        | ~$2-5                             |
| **Approximate total**             | **~$120-140 / month**        | **~$325-365 / month**             |

The implemented `compute` stage alone (ALB, 2 x t3.micro, 5 endpoints, logs)
costs about **$0.12/hour (~$88/month)** in dev; the `network` stage is
essentially free without NAT. See [deployment.md](deployment.md#cleanup-and-cost).

## Biggest cost drivers

1. **NAT Gateways vs. interface endpoints** - `dev` runs without NAT and uses
   6 interface endpoints in one AZ (~$44 / month; ~$29 without the two Session
   Manager endpoints). One NAT Gateway is ~$33 / month plus $0.045 / GB and
   would also allow internet access. The free S3 gateway endpoint carries ECR
   image layers and the AL2023 package repositories either way.
2. **Multi-AZ RDS** doubles instance and storage cost; it is enabled only in `prod`.
3. **ALB + public IPv4 addresses** - fixed baseline cost.

## Saving money while building

- Deploy `dev` only when testing and run `./scripts/destroy.sh dev` afterwards;
  most of the cost is hourly.
- Set an **AWS Budget** with an email alert (for example $20 / month) before the
  first deployment.
- Keep log retention short in `dev` (14 days).
- Use Savings Plans or Reserved Instances only for a long-lived `prod`.
