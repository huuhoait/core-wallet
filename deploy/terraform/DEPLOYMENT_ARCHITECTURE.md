# Core Wallet — Deployment Architecture

## High-Level Deployment Model

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                            CI/CD Pipeline (GitHub Actions)                        │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│  ┌──────────┐     ┌──────────────┐     ┌──────────────┐     ┌───────────────┐  │
│  │  Push /   │────▶│  CI: Lint +  │────▶│ Build & Push │────▶│  CD: Terraform │  │
│  │  PR / Tag │     │  Test + SQL  │     │ Docker Images│     │  Plan + Apply  │  │
│  └──────────┘     └──────────────┘     └──────────────┘     └───────────────┘  │
│                                               │                      │           │
│                                               ▼                      ▼           │
│                                          ┌─────────┐          ┌───────────┐     │
│                                          │  GHCR   │          │ AWS (OIDC)│     │
│                                          └─────────┘          └───────────┘     │
└─────────────────────────────────────────────────────────────────────────────────┘
```

## AWS Infrastructure (Production)

```
┌──────────────────────────────────────────────────────────────────────────────────────┐
│                              AWS Region: ap-southeast-1                                │
│                                                                                       │
│  ┌─────────────────────────────────────────────────────────────────────────────────┐ │
│  │                          VPC 10.0.0.0/16                                         │ │
│  │                                                                                  │ │
│  │  ┌────────────── Public Subnets (3 AZs) ──────────────────────────────────────┐ │ │
│  │  │                                                                             │ │ │
│  │  │  ┌─────────────────────────────────────────────────────────────────────┐   │ │ │
│  │  │  │                    Application Load Balancer                          │   │ │ │
│  │  │  │              (HTTPS :443 → Target Group :8080)                       │   │ │ │
│  │  │  └──────────────────────────────┬──────────────────────────────────────┘   │ │ │
│  │  │                                 │                                           │ │ │
│  │  │  ┌──────────┐                  │                                           │ │ │
│  │  │  │ NAT GW   │                  │                                           │ │ │
│  │  │  │ (EIP)    │                  │                                           │ │ │
│  │  │  └──────────┘                  │                                           │ │ │
│  │  └─────────────────────────────────┼───────────────────────────────────────────┘ │ │
│  │                                    │                                              │ │
│  │  ┌────────────── Private Subnets (3 AZs) ─────────────────────────────────────┐ │ │
│  │  │                                 │                                            │ │ │
│  │  │  ┌──────────────────────────────┼────────────────────────────────────────┐  │ │ │
│  │  │  │              ECS Cluster (Fargate)                                     │  │ │ │
│  │  │  │                              │                                         │  │ │ │
│  │  │  │  ┌──────────────────────────▼──────────────────────────────────────┐  │  │ │ │
│  │  │  │  │          ECS Service: wallet-service (3–10 tasks)                │  │  │ │ │
│  │  │  │  │          Auto-scaling: CPU 60% / 1000 req/min per target         │  │  │ │ │
│  │  │  │  │                                                                  │  │  │ │ │
│  │  │  │  │  ┌─── Task ───────────────────────────────────────────────────┐ │  │  │ │ │
│  │  │  │  │  │                                                             │ │  │  │ │ │
│  │  │  │  │  │  ┌───────────────────────┐   ┌──────────────────────────┐ │ │  │  │ │ │
│  │  │  │  │  │  │   wallet-service      │   │     PgBouncer (sidecar)  │ │ │  │  │ │ │
│  │  │  │  │  │  │   (Go/Gin, :8080)     │──▶│     (transaction mode)   │ │ │  │  │ │ │
│  │  │  │  │  │  │                       │   │     localhost:6432       │ │ │  │  │ │ │
│  │  │  │  │  │  │  • REST API           │   │                          │ │ │  │  │ │ │
│  │  │  │  │  │  │  • Audit GUCs         │   │  • pool_size=16          │ │ │  │  │ │ │
│  │  │  │  │  │  │  • OTel tracing       │   │  • max_client=200        │ │ │  │  │ │ │
│  │  │  │  │  │  │  • EOD scheduler      │   │  • SCRAM-SHA-256         │ │ │  │  │ │ │
│  │  │  │  │  │  └───────────────────────┘   └────────────┬─────────────┘ │ │  │  │ │ │
│  │  │  │  │  │                                            │               │ │  │  │ │ │
│  │  │  │  │  └────────────────────────────────────────────┼───────────────┘ │  │  │ │ │
│  │  │  │  └──────────────────────────────────────────────┼──────────────────┘  │  │ │ │
│  │  │  │                                                  │                     │  │ │ │
│  │  │  │  ┌──────────────────────────────────────────────┼──────────────────┐  │  │ │ │
│  │  │  │  │   ECS Service: outbox-relay (future)          │                  │  │  │ │ │
│  │  │  │  │   (Go, polls WLT_OUTBOX → Kafka)             │                  │  │  │ │ │
│  │  │  │  └──────────────────────────────────────────────┼──────────────────┘  │  │ │ │
│  │  │  │                                                  │                     │  │ │ │
│  │  │  └──────────────────────────────────────────────────┼─────────────────────┘  │ │
│  │  │                                                     │                         │ │
│  │  │  ┌──────────────────────────────────────────────────┼─────────────────────┐  │ │
│  │  │  │              Database Subnets (3 AZs)             │                     │  │ │
│  │  │  │                                                   │                     │  │ │
│  │  │  │  ┌───────────────────────────────────────────────▼───────────────────┐ │  │ │
│  │  │  │  │                                                                    │ │  │ │
│  │  │  │  │          RDS PostgreSQL 17 (Primary)                               │ │  │ │
│  │  │  │  │          db.r6g.large — Multi-AZ (sync standby)                    │ │  │ │
│  │  │  │  │                                                                    │ │  │ │
│  │  │  │  │  • Encrypted (AES-256)                                             │ │  │ │
│  │  │  │  │  • Performance Insights                                            │ │  │ │
│  │  │  │  │  • Auto-scaling storage (100–500 GB gp3)                           │ │  │ │
│  │  │  │  │  • Automated backups (7 days)                                      │ │  │ │
│  │  │  │  │  • pg_stat_statements enabled                                      │ │  │ │
│  │  │  │  │                                                                    │ │  │ │
│  │  │  │  │  Roles:                                                            │ │  │ │
│  │  │  │  │    wallet_app     → service (posting, reads)                       │ │  │ │
│  │  │  │  │    wallet_pii_ro  → PII reads (ops only)                           │ │  │ │
│  │  │  │  │    wallet_eod     → EOD batch (direct, no pooler)                  │ │  │ │
│  │  │  │  │                                                                    │ │  │ │
│  │  │  │  └────────────────────────────┬───────────────────────────────────────┘ │  │ │
│  │  │  │                               │ async replication                       │  │ │
│  │  │  │  ┌────────────────────────────▼───────────────────────────────────────┐ │  │ │
│  │  │  │  │          RDS Read Replica                                           │ │  │ │
│  │  │  │  │          (lag-tolerant: account profiles, statement list)           │ │  │ │
│  │  │  │  └────────────────────────────────────────────────────────────────────┘ │  │ │
│  │  │  │                                                                         │  │ │
│  │  │  └─────────────────────────────────────────────────────────────────────────┘  │ │
│  │  │                                                                                │ │
│  │  └────────────────────────────────────────────────────────────────────────────────┘ │
│  │                                                                                     │
│  └─────────────────────────────────────────────────────────────────────────────────────┘ │
│                                                                                          │
│  ┌───────── Supporting Services ──────────────────────────────────────────────────────┐ │
│  │                                                                                     │ │
│  │  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────────────────────┐ │ │
│  │  │ Secrets Manager   │  │ CloudWatch Logs  │  │ S3 (Terraform state)             │ │ │
│  │  │                   │  │                  │  │                                   │ │ │
│  │  │ • DB master pwd   │  │ • /ecs/wallet-*  │  │ • core-wallet-tfstate            │ │ │
│  │  │ • wallet_app pwd  │  │ • /ecs/pgbouncer │  │ • Versioned + encrypted          │ │ │
│  │  │ • wallet_pii pwd  │  │ • /ecs/outbox-*  │  │                                   │ │ │
│  │  │ • wallet_eod pwd  │  │ • RDS logs       │  │ DynamoDB (TF lock)               │ │ │
│  │  └──────────────────┘  └──────────────────┘  └──────────────────────────────────┘ │ │
│  │                                                                                     │ │
│  └─────────────────────────────────────────────────────────────────────────────────────┘ │
│                                                                                          │
└──────────────────────────────────────────────────────────────────────────────────────────┘
```

## Network Flow

```
                        Internet
                           │
                           ▼
                   ┌───────────────┐
                   │  Route 53     │  (future: custom domain)
                   │  DNS          │
                   └───────┬───────┘
                           │
                           ▼
              ┌────────────────────────┐
              │   ALB (public subnet)   │
              │   TLS termination       │
              │   Health: /healthz      │
              └────────────┬───────────┘
                           │ :8080
                           ▼
              ┌────────────────────────┐
              │  wallet-service (ECS)   │  ← private subnet
              │  Go/Gin REST API        │
              └────────────┬───────────┘
                           │ localhost:6432
                           ▼
              ┌────────────────────────┐
              │  PgBouncer (sidecar)    │  ← same task, no network hop
              │  transaction pooling    │
              └────────────┬───────────┘
                           │ :5432 (TCP, private)
                           ▼
              ┌────────────────────────┐
              │  RDS PostgreSQL 17      │  ← database subnet
              │  Posting SPs (atomic)   │
              │  Double-entry ledger    │
              └────────────────────────┘
```

## CI/CD Pipeline Flow

```
┌─────────┐      ┌─────────────────────────────────────────────────────────────┐
│Developer│      │                    GitHub Actions                             │
└────┬────┘      └─────────────────────────────────────────────────────────────┘
     │
     │ git push feature/xyz
     │──────────────────────────────▶ CI Pipeline
     │                                  │
     │                                  ├─── go-checks ────────────────────┐
     │                                  │    • go mod tidy (check)         │
     │                                  │    • go vet                      │
     │                                  │    • golangci-lint               │
     │                                  │    • go test -race               │
     │                                  │    • go build (linux/amd64)      │
     │                                  │                                  │
     │                                  ├─── outbox-relay-checks ──────────┤
     │                                  │    • go vet + build              │
     │                                  │                                  │
     │                                  ├─── sql-tests ────────────────────┤
     │                                  │    • PG17 service container      │
     │                                  │    • Load schema + partitions    │
     │                                  │    • 9 SQL assertion suites      │
     │                                  │                                  │
     │                                  └─── terraform-validate ───────────┘
     │                                       • fmt -check                  
     │                                       • init -backend=false         
     │                                       • validate                    
     │
     │ PR merge → master
     │──────────────────────────────▶ CD Pipeline (Staging)
     │                                  │
     │                                  ├─── build-images ─────────────────┐
     │                                  │    • wallet-service (multi-arch) │
     │                                  │    • outbox-relay (multi-arch)   │
     │                                  │    • Push → GHCR                 │
     │                                  │                                  │
     │                                  └─── deploy-staging ───────────────┘
     │                                       • AWS OIDC auth               
     │                                       • terraform plan              
     │                                       • terraform apply             
     │
     │ git tag v1.2.3
     │──────────────────────────────▶ CD Pipeline (Production)
     │                                  │
     │                                  ├─── build-images (semver tag)
     │                                  │
     │                                  └─── deploy-production ────────────┐
     │                                       • Requires approval           │
     │                                       • terraform plan              │
     │                                       • terraform apply             │
     │                                       └────────────────────────────┘
```

## Scaling Strategy

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         Auto-Scaling Rules                                │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  ECS wallet-service:                                                     │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │  Min: 3 tasks  ──────────────────────────────────── Max: 10     │    │
│  │       │                                                  │       │    │
│  │       │  Scale OUT when:                                 │       │    │
│  │       │    • CPU > 60% (cooldown 60s)                    │       │    │
│  │       │    • Requests > 1000/min/target (cooldown 60s)   │       │    │
│  │       │                                                  │       │    │
│  │       │  Scale IN when:                                  │       │    │
│  │       │    • Below thresholds (cooldown 300s)            │       │    │
│  │       │                                                  │       │    │
│  └─────────────────────────────────────────────────────────────────┘    │
│                                                                          │
│  RDS PostgreSQL:                                                         │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │  Storage: 100 GB ──── auto-expand ──── 500 GB max               │    │
│  │  Compute: db.r6g.large (fixed — scale vertically if needed)     │    │
│  │  Read Replica: offloads account/statement reads                  │    │
│  └─────────────────────────────────────────────────────────────────┘    │
│                                                                          │
│  PgBouncer (per-task sidecar):                                           │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │  16 server connections × N tasks = 48 DB connections (3 tasks)   │    │
│  │  → scales linearly with ECS tasks                                │    │
│  │  → max 10 tasks × 16 = 160 server conns (< RDS max_connections) │    │
│  └─────────────────────────────────────────────────────────────────┘    │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

## Security Layers

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           Security Model                                  │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  Network:                                                                │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │  • ALB: public subnets only (HTTPS/443)                           │   │
│  │  • ECS: private subnets (no public IP)                            │   │
│  │  • RDS: database subnets (SG: inbound only from ECS SG)          │   │
│  │  • NAT GW: outbound-only for ECS (pulls images, OTel export)     │   │
│  └──────────────────────────────────────────────────────────────────┘   │
│                                                                          │
│  Authentication:                                                         │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │  • GitHub → AWS: OIDC federation (no long-lived keys)             │   │
│  │  • ECS → Secrets: IAM role (task execution role)                  │   │
│  │  • ECS → RDS: SCRAM-SHA-256 via PgBouncer                        │   │
│  │  • DB passwords: Secrets Manager (rotatable)                      │   │
│  └──────────────────────────────────────────────────────────────────┘   │
│                                                                          │
│  Data:                                                                   │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │  • RDS: encrypted at rest (AES-256)                               │   │
│  │  • PII: column-level pgcrypto encryption + masked views           │   │
│  │  • Audit: FM_CLIENT_AUDIT_LOG (tamper-evident, partitioned)       │   │
│  │  • Trial balance: SHA-256 hash chain (integrity proof)            │   │
│  └──────────────────────────────────────────────────────────────────┘   │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

## Environment Comparison

```
┌─────────────────────┬──────────────────────────┬──────────────────────────┐
│                     │        STAGING            │       PRODUCTION          │
├─────────────────────┼──────────────────────────┼──────────────────────────┤
│ Trigger             │ Push to master           │ Tag v*                    │
│ Approval            │ Automatic                │ Manual (environment gate) │
│ RDS                 │ db.t4g.medium, 1-AZ      │ db.r6g.large, multi-AZ   │
│ Read Replica        │ None                     │ Yes                       │
│ ECS Tasks           │ 1 (no autoscaling)       │ 3–10 (autoscaled)        │
│ Task Size           │ 256 CPU / 512 MB         │ 1024 CPU / 2048 MB       │
│ PgBouncer           │ 128 CPU / 256 MB         │ 256 CPU / 512 MB         │
│ ALB                 │ HTTP (port 8080)         │ HTTPS (TLS 1.3, ACM)     │
│ Cost (est.)         │ ~$125/month              │ ~$750/month              │
│ DB Backup           │ 7 days                   │ 7 days + cross-region    │
│ Deletion Protection │ Yes                      │ Yes                       │
└─────────────────────┴──────────────────────────┴──────────────────────────┘
```

## Capacity Sizing by TPS

> Sizing estimates based on the wallet workload profile: 8-way posting mix
> (topup/transfer/withdraw/reversal/merchant), each SP call ≈ 3–8ms DB time,
> p99 target < 300ms end-to-end. PgBouncer transaction-mode multiplexes
> many app connections onto fewer DB server connections.

### Sizing Matrix

```
┌──────────┬──────────────────────────────────────────────────────────────────────────────────────────┐
│   TPS    │                              Infrastructure Sizing                                        │
├──────────┼───────────────┬───────────────┬───────────────┬──────────────────┬───────────────────────┤
│          │ ECS Tasks     │ Task Size     │ PgBouncer     │ RDS Instance     │ Est. Monthly Cost     │
│          │ (min–max)     │ (CPU/Mem)     │ (pool/task)   │                  │ (USD)                 │
├──────────┼───────────────┼───────────────┼───────────────┼──────────────────┼───────────────────────┤
│   100    │  1–2          │ 256 / 512 MB  │ 8 conns       │ db.t4g.medium    │ ~$125                 │
│          │               │               │               │ (2 vCPU, 4 GB)   │                       │
├──────────┼───────────────┼───────────────┼───────────────┼──────────────────┼───────────────────────┤
│   500    │  2–4          │ 512 / 1024 MB │ 12 conns      │ db.r6g.medium    │ ~$350                 │
│          │               │               │               │ (2 vCPU, 16 GB)  │                       │
├──────────┼───────────────┼───────────────┼───────────────┼──────────────────┼───────────────────────┤
│  1,000   │  2–6          │ 512 / 1024 MB │ 16 conns      │ db.r6g.large     │ ~$550                 │
│          │               │               │               │ (2 vCPU, 16 GB)  │                       │
├──────────┼───────────────┼───────────────┼───────────────┼──────────────────┼───────────────────────┤
│  2,000   │  3–10         │ 1024 / 2048   │ 16 conns      │ db.r6g.xlarge    │ ~$900                 │
│ (target) │               │               │               │ (4 vCPU, 32 GB)  │                       │
│          │               │               │               │ + read replica   │                       │
├──────────┼───────────────┼───────────────┼───────────────┼──────────────────┼───────────────────────┤
│  5,000   │  6–20         │ 1024 / 2048   │ 20 conns      │ db.r6g.2xlarge   │ ~$1,800               │
│  (peak)  │               │               │               │ (8 vCPU, 64 GB)  │                       │
│          │               │               │               │ + read replica   │                       │
│          │               │               │               │ + multi-AZ       │                       │
├──────────┼───────────────┼───────────────┼───────────────┼──────────────────┼───────────────────────┤
│ 10,000   │ 10–30         │ 2048 / 4096   │ 24 conns      │ db.r6g.4xlarge   │ ~$3,500               │
│ (future) │               │               │               │ (16 vCPU, 128 GB)│                       │
│          │               │               │               │ + 2 read replicas│                       │
│          │               │               │               │ + multi-AZ       │                       │
└──────────┴───────────────┴───────────────┴───────────────┴──────────────────┴───────────────────────┘
```

### Calculation Assumptions

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        Sizing Rationale                                       │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  Per-request DB time (posting SP):                                           │
│    • Average: 5 ms (validated at 200 TPS pgbench, 0 failed)                 │
│    • p95: 12 ms (under contention / hot-account retry)                      │
│    • p99: 25 ms (worst-case lock wait before timeout)                       │
│                                                                              │
│  DB connection utilization:                                                   │
│    TPS capacity per DB connection = 1000ms / 5ms = 200 TPS/conn             │
│    At 70% utilization target: ~140 TPS/conn effective                        │
│                                                                              │
│  PgBouncer pool sizing:                                                      │
│    • 16 server conns/task × N tasks = total DB connections                   │
│    • 3 tasks × 16 = 48 conns → supports ~6,700 TPS (theoretical)           │
│    • Practical (contention, GC, network): ~2,000 TPS @ 3 tasks              │
│                                                                              │
│  RDS connection budget:                                                       │
│    • db.r6g.large max_connections ≈ 1,600                                    │
│    • Budget: 80% for app = 1,280 connections                                │
│    • At 16 conns/task × 10 tasks = 160 conns (well within budget)           │
│                                                                              │
│  ECS task throughput:                                                         │
│    • Go/Gin: ~5,000 req/s per vCPU (JSON parse + validate + pgx call)       │
│    • Bottleneck is ALWAYS the DB, not the Go layer                          │
│    • Extra tasks provide redundancy, not DB throughput                        │
│                                                                              │
│  Read path offload:                                                          │
│    • Read replica handles: GetAccount, ListTransactions                      │
│    • Frees ~30% of primary connections for write posting                     │
│    • Balance reads stay on primary (read-after-write consistency)            │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Storage Growth Estimates

```
┌──────────┬───────────────────────────────────────────────────────────────────┐
│   TPS    │                   Storage Growth (WLT_TRAN_HIST)                   │
├──────────┼──────────────┬──────────────┬──────────────┬──────────────────────┤
│          │ Rows/day     │ GB/day       │ GB/month     │ 1-year (with idx)    │
├──────────┼──────────────┼──────────────┼──────────────┼──────────────────────┤
│   100    │   8.6M       │  ~2.5 GB     │  ~75 GB      │  ~1 TB              │
│   500    │  43.2M       │  ~12 GB      │  ~370 GB     │  ~5 TB              │
│  1,000   │  86.4M       │  ~25 GB      │  ~750 GB     │  ~10 TB             │
│  2,000   │ 172.8M       │  ~50 GB      │  ~1.5 TB     │  ~20 TB             │
│  5,000   │ 432.0M       │  ~125 GB     │  ~3.7 TB     │  ~50 TB             │
│ 10,000   │ 864.0M       │  ~250 GB     │  ~7.5 TB     │  ~100 TB            │
├──────────┼──────────────┴──────────────┴──────────────┴──────────────────────┤
│  Notes   │ • ~2.5 legs/posting (avg of 8-way mix: topup 2, transfer 5,      │
│          │   withdraw 4, reversal 3, merchant 3)                             │
│          │ • Row size: ~300 bytes (excl. TOAST, incl. index overhead)        │
│          │ • Monthly partitioning + HASH(8) subpartitions keeps per-shard    │
│          │   index <1M rows → fast sequential scan + hot-page locality       │
│          │ • Partition pruning in queries scopes search to 1 monthly shard   │
│          │ • Archive (>12 months) → pg_dump + S3 glacier, detach partition   │
└──────────┴───────────────────────────────────────────────────────────────────┘
```

### Recommended Terraform Variables by TPS Target

```hcl
# ═══════════════════════════════════════════════════════════════════════════
# 500 TPS — Early production / soft launch
# ═══════════════════════════════════════════════════════════════════════════
# db_instance_class        = "db.r6g.medium"
# db_allocated_storage     = 100
# db_max_allocated_storage = 300
# db_multi_az              = true
# db_read_replica          = false
# wallet_service_cpu       = 512
# wallet_service_memory    = 1024
# wallet_service_desired_count = 2

# ═══════════════════════════════════════════════════════════════════════════
# 2,000 TPS — Sustained target (design goal)
# ═══════════════════════════════════════════════════════════════════════════
# db_instance_class        = "db.r6g.xlarge"
# db_allocated_storage     = 200
# db_max_allocated_storage = 1000
# db_multi_az              = true
# db_read_replica          = true
# wallet_service_cpu       = 1024
# wallet_service_memory    = 2048
# wallet_service_desired_count = 3

# ═══════════════════════════════════════════════════════════════════════════
# 5,000 TPS — Peak / Tet holiday traffic
# ═══════════════════════════════════════════════════════════════════════════
# db_instance_class        = "db.r6g.2xlarge"
# db_allocated_storage     = 500
# db_max_allocated_storage = 2000
# db_multi_az              = true
# db_read_replica          = true
# wallet_service_cpu       = 1024
# wallet_service_memory    = 2048
# wallet_service_desired_count = 6

# ═══════════════════════════════════════════════════════════════════════════
# 10,000 TPS — Future scale (requires DB sharding evaluation)
# ═══════════════════════════════════════════════════════════════════════════
# db_instance_class        = "db.r6g.4xlarge"
# db_allocated_storage     = 1000
# db_max_allocated_storage = 5000
# db_multi_az              = true
# db_read_replica          = true   # consider 2 replicas
# wallet_service_cpu       = 2048
# wallet_service_memory    = 4096
# wallet_service_desired_count = 10
```

### Bottleneck Analysis

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    Where does the system hit its ceiling?                     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  TPS        Bottleneck           Mitigation                                  │
│  ─────────  ───────────────────  ────────────────────────────────────────── │
│  < 2,000    None expected        Current design handles this cleanly         │
│                                                                              │
│  2,000–     Hot-account lock     ✅ Server-side retry (DB_TX_MAX_RETRIES=2) │
│  5,000      contention on        ✅ Merchant hot-wallet sharding (4→8→16)   │
│             popular wallets       ⚠️ Monitor p99 latency + retry rate        │
│                                                                              │
│  5,000–     RDS single-writer    Options:                                    │
│  10,000     CPU saturation        • Vertical scale (r6g.4xl → r6g.8xl)     │
│                                   • Citus/partitioned writes (complex)       │
│                                   • Application-level sharding by client     │
│                                                                              │
│  > 10,000   Single-PG limit      Requires architectural change:             │
│                                   • Multi-primary (Citus distributed)        │
│                                   • Shard by client_no prefix               │
│                                   • Separate hot-path (transfer) from cold   │
│                                                                              │
│  Read        Never the            Read replica absorbs all lag-tolerant      │
│  path        bottleneck           reads; balance/posting stay on primary     │
│                                                                              │
│  Network     Never the            PgBouncer sidecar = localhost (0 hop);    │
│              bottleneck           ALB → ECS = in-VPC (< 1ms)                │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```
