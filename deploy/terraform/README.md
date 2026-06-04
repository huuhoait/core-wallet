# Terraform — Core Wallet Infrastructure

> AWS infrastructure as code for the Core Wallet ledger system.
> Target region: `ap-southeast-1` (Singapore) — low latency to Vietnam.

## Architecture

```
Internet → ALB (HTTPS) → ECS Fargate (wallet-service + PgBouncer sidecar)
                                         ↓
                           RDS PostgreSQL 17 (multi-AZ in prod)
                                         ↓
                           Read Replica (optional, lag-tolerant reads)
```

### Components

| Resource | Staging | Production |
|----------|---------|------------|
| RDS PostgreSQL | db.t4g.medium, single-AZ, 50 GB | db.r6g.large, multi-AZ, 100–500 GB |
| Read Replica | — | db.r6g.large (async) |
| ECS Tasks | 1× (256 CPU / 512 MB) | 3–10× (1024 CPU / 2048 MB) autoscaled |
| PgBouncer | Sidecar per task (128 CPU / 256 MB) | Sidecar per task (256 CPU / 512 MB) |
| ALB | Public, HTTP only | Public, HTTPS (ACM cert required) |
| VPC | 3-AZ, 1 NAT | 3-AZ, 1 NAT (upgrade to per-AZ for HA) |

## Directory structure

```
deploy/terraform/
├── README.md              ← this file
├── main.tf                ← root module (composes vpc + rds + ecs)
├── modules/
│   ├── vpc/main.tf        ← VPC, subnets, NAT, route tables
│   ├── rds/main.tf        ← RDS PG17, secrets, parameter groups, replica
│   └── ecs/main.tf        ← ECS cluster, task defs, ALB, autoscaling
├── environments/
│   ├── staging/main.tf    ← staging backend + sizing
│   └── production/main.tf ← production backend + sizing
└── bootstrap/main.tf      ← S3 state bucket + DynamoDB lock + GitHub OIDC role
```

## Getting started

### 1. Bootstrap (one-time setup)

Create the S3 state bucket, DynamoDB lock table, and GitHub OIDC deploy role:

```bash
cd deploy/terraform/bootstrap
terraform init
terraform apply
```

Save the output `deploy_role_arn` → set as `AWS_DEPLOY_ROLE_ARN` in GitHub repo secrets.

### 2. Configure GitHub secrets

| Secret | Value |
|--------|-------|
| `AWS_DEPLOY_ROLE_ARN` | `arn:aws:iam::ACCOUNT_ID:role/core-wallet-github-deploy` |

### 3. Deploy staging manually (optional)

```bash
cd deploy/terraform/environments/staging
terraform init
terraform plan -var="image_tag=abc123"
terraform apply -var="image_tag=abc123"
```

### 4. CI/CD automatic deployment

- **Push to master** → CI runs → builds images → deploys to staging
- **Tag `v*`** → CI runs → builds images → deploys to production

## Database initialization

After the first `terraform apply`, the RDS instance has an empty `wallet` database.
Load the schema:

```bash
# Get RDS endpoint from terraform output
RDS_HOST=$(terraform output -raw rds_endpoint | cut -d: -f1)

# Load the full schema (via bastion or VPN — RDS is in private subnet)
PGPASSWORD=<from-secrets-manager> psql -h $RDS_HOST -U postgres -d wallet \
  -f db/export/schema.sql \
  -f db/export/partitions.sql \
  -f db/export/seed.sql
```

> Future: integrate schema loading into an init ECS task or use a migration tool.

## Security notes

- RDS is in private subnets (no public access)
- All credentials in AWS Secrets Manager (rotatable)
- PgBouncer runs as a sidecar (localhost-only, no network hop)
- ECS tasks use IAM roles (no long-lived credentials)
- GitHub Actions uses OIDC federation (no AWS access keys stored)
- ALB should use HTTPS with ACM certificate (configure `acm_certificate_arn`)

## Cost estimate (staging)

| Resource | Monthly cost (approx) |
|----------|----------------------|
| RDS db.t4g.medium (single-AZ) | ~$55 |
| NAT Gateway | ~$35 |
| ECS Fargate (1 task) | ~$15 |
| ALB | ~$20 |
| **Total** | **~$125/month** |

## Cost estimate (production)

| Resource | Monthly cost (approx) |
|----------|----------------------|
| RDS db.r6g.large (multi-AZ) | ~$380 |
| RDS read replica | ~$190 |
| NAT Gateway | ~$35 |
| ECS Fargate (3 tasks base) | ~$120 |
| ALB | ~$25 |
| **Total** | **~$750/month** |
