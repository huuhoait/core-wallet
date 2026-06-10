# Core Wallet — E-Wallet Ledger System

> **Status:** Active development · MVP / not production-validated
> **Trạng thái:** Đang phát triển · MVP, chưa kiểm chứng cho production

A double-entry e-wallet **ledger** for retail and merchant wallets. The scope is
**internal synchronous posting only** — top-up, transfer, withdraw, merchant
settlement, fee/VAT, and reversal. External rails (NAPAS, partner banks, card
3DS, MT940 reconciliation) are deliberately **out of scope** and belong to a
separate Treasury Service.

> 🇻🇳 Hệ thống **sổ cái** ví điện tử ghi sổ kép (double-entry) cho ví khách hàng
> và ví merchant. Phạm vi chỉ gồm **giao dịch nội bộ đồng bộ**: nạp tiền, chuyển
> khoản, rút tiền, tất toán merchant, phí/VAT và đảo giao dịch. Tích hợp ra bên
> ngoài (NAPAS, ngân hàng đối tác, 3DS thẻ, đối soát MT940) **không thuộc phạm
> vi** — thuộc về Treasury Service riêng.

- **Tech stack:** Go 1.26 (Gin) + PostgreSQL 17 (plpgsql stored procedures) + PgBouncer (transaction mode) + Kafka (transactional outbox relay) + OpenTelemetry → Jaeger
- **Design pattern:** thin Go RPC layer; **all posting logic lives in PostgreSQL stored functions** (atomic, deferred-locking)
- **Design targets (not yet verified):** 2,000 TPS sustained / 5,000 TPS peak; p99 < 300 ms for in-wallet transfer
- **Compliance scope:** Decree 52/2024, Circular 23/2019 (SBV), Decree 13/2023 (PII)

📋 **Feature status / Tình trạng tính năng → [USER_STORIES.md](USER_STORIES.md)**
📚 **Full design docs / Tài liệu thiết kế → [docs/INDEX.md](docs/INDEX.md)**

---

## Repository structure / Cấu trúc dự án

```
Core/
├── README.md                 # this file
├── USER_STORIES.md           # user-story backlog with done / not-done status
├── CHANGELOG.md              # version history
├── docker-compose.yml        # local dev stack (PG17 + PgBouncer + Adminer; +Kafka/relay/Jaeger via profiles)
├── .env.example              # infra env template (copy to .env)
│
├── .github/workflows/        # CI/CD pipelines
│   ├── ci.yml                #   lint + test + SQL suites + terraform validate
│   ├── cd.yml                #   build images → terraform deploy (ECS)
│   └── cd-k8s.yml            #   build images → kustomize → kubectl apply (K8s)
│
├── docs/                     # design documentation
│   ├── INDEX.md              #   doc catalogue
│   ├── hld/                  #   High-Level Design (+ 20-TPS variant)
│   ├── dld/                  #   Detailed Low-Level Design (schema, posting)
│   └── specs/                #   feature specs (finance, errors, onboarding, COA, T24, k6)
│
├── db/                       # PostgreSQL — single source of truth for the ledger
│   ├── export/               #   the DB: schema.sql + partitions.sql + seed.sql (docker-init)
│   ├── seeds/                #   demo / load-test fixtures (testdata, bulk generator, COA src)
│   └── tests/                #   SQL assertion suites (accounting, recon, reversal)
│
├── services/
│   ├── wallet-service/       # Go service — thin RPC over the stored procedures
│   │   ├── cmd/server/       #   main entrypoint
│   │   ├── internal/         #   domain / usecase / repo / http (clean architecture)
│   │   └── postman/          #   Postman collection + environment
│   ├── outbox-relay/         # Outbox → Kafka relay worker (polling + Debezium CDC modes)
│   └── shared/               # shared Go module: otelx (tracing) · pgxdb (pool) · kafkax
│
└── deploy/
    ├── docker/               # postgres + pgbouncer config & init scripts
    ├── loadtest/             # k6 (HTTP) + pgbench (DB) load tests
    ├── k8s/                  # ⭐ Kubernetes manifests (Kustomize)
    │   ├── base/             #   shared: deployment, service, HPA, PDB, netpol
    │   └── overlays/         #   aws-eks/ | on-premise/
    └── terraform/            # ⭐ AWS infrastructure as code
        ├── modules/          #   vpc, rds, eks, ecs
        ├── environments/     #   staging/ | production/
        └── bootstrap/        #   S3 state + DynamoDB lock + OIDC role
```

> Legacy spreadsheets live in `.archive/` (git-ignored, not part of the deliverable).

---

## Architecture / Kiến trúc

The Go service is a **thin client**. It validates input, sets per-transaction
GUCs (audit actor/source), and calls a single PostgreSQL stored function per
operation. The stored function does all balance validation and the atomic
double-entry posting in one transaction.

```
Customer App / Ops Console
        │  REST + JSON
        ▼
┌─────────────────────────────────────────┐
│  wallet-service (Go / Gin)               │
│  http → handler → usecase → repo         │   ← clean architecture
│  middleware: request-id, audit ctx, OTel │
└───────────────┬──────────────────────────┘
                │  pgx (3 s ctx deadline)
                ▼
┌─────────────────────────────────────────┐
│  PgBouncer (transaction pooling, :6432)  │
└───────────────┬──────────────────────────┘
                ▼
┌─────────────────────────────────────────┐
│  PostgreSQL 17                           │
│  posting SPs (post_topup/transfer/…)     │
│  WLT_ACCT · WLT_TRAN_HIST · WLT_ACCT_BAL │
│  WLT_OUTBOX (transactional outbox)       │
│  WLT_WITHDRAW_TRACK · WLT_CLIENT_AUDIT…  │
└───────────────┬─────────────────────────┘
                │  WLT_OUTBOX (status PENDING)
                ▼
┌─────────────────────────────────────────┐
│  outbox-relay (Go)                       │   ← polling or Debezium CDC
│  poll → publish → stamp SENT             │
└───────────────┬─────────────────────────┘
                ▼
              Kafka  (downstream consumers)
```

**Timeout layering:** Go context 3 s → PG `statement_timeout` 2.5 s → PG
`lock_timeout` 1.5 s. **Posting** uses a deferred-locking pattern (Phase 1
no-lock validate → Phase 2 atomic UPDATE).

**Tracing:** wallet-service and outbox-relay emit OpenTelemetry spans. The W3C
trace context is propagated end-to-end — HTTP request → DB stored function →
`WLT_OUTBOX` row → relay publish → Kafka — so one trace renders as a single
waterfall in Jaeger. Disabled by default; opt in with `OTEL_ENABLED=true`.

---

## Getting started / Bắt đầu

### 1. Start the database stack

```bash
cp .env.example .env                 # adjust passwords if needed
docker compose up -d                 # PG17 + PgBouncer
docker compose logs -f postgres      # wait for "ready to accept connections"
```

On first volume init, PostgreSQL auto-loads the **entire DB** from `db/export/`
(mounted as init scripts, in order): `01-schema.sql` (all DDL + stored
functions + triggers), `02-partitions.sql` (monthly + hash partitions),
`03-seed.sql` (GL master / COA / tran-type reference data). A plain
`docker compose up` gives a complete, ready DB — **no manual psql steps**. The
roles the schema grants to are created by `deploy/docker/postgres/init/00-set-passwords.sh`.

To change schema or a stored function, edit `db/export/schema.sql` and re-init
(`docker compose down -v && up`), or apply to a running DB and regenerate — see
`db/export/README.md` for the `pg_dump` regenerate commands.

> 🇻🇳 `docker compose up` tự nạp toàn bộ DB từ 3 file trong `db/export/`
> (schema → partitions → seed). Không còn bước nạp thủ công.

### 2. Run the service

```bash
cd services/wallet-service
cp .env.example .env                 # service config (DB_DSN, timeouts, OTel)
make run                             # connects to PgBouncer on :6432, listens :8080
```

### 3. Smoke test

```bash
cd services/wallet-service && make smoke      # POSTs a top-up via curl
# or import postman/wallet-service.postman_collection.json
```

### 4. Optional: outbox relay + distributed tracing

The base stack is the ledger only. Kafka + the outbox-relay live behind the
`relay` profile, and Jaeger behind the `tracing` profile — both opt-in:

```bash
# Outbox → Kafka relay (Zookeeper + Kafka + outbox-relay)
docker compose --profile relay up -d

# Add end-to-end tracing into Jaeger (UI at http://localhost:16686)
OTEL_ENABLED=true docker compose --profile relay --profile tracing up -d
```

> 🇻🇳 Stack mặc định chỉ gồm sổ cái. Relay (Kafka) và tracing (Jaeger) là tuỳ
> chọn, bật qua profile `relay` / `tracing`.

---

## API reference / Tham chiếu API

Base path `/v1`. Transactional + treasury routes carry the request-timeout
deadline. Full request/response shapes: [docs/specs/finance_transaction.md](docs/specs/finance_transaction.md)
and the Postman collection.

| Method | Path | Purpose |
|--------|------|---------|
| `GET`  | `/healthz` | Liveness probe |
| `POST` | `/v1/finance/topup` | Internal credit (Treasury → wallet) |
| `POST` | `/v1/finance/transfer` | Wallet → wallet transfer |
| `POST` | `/v1/finance/withdraw` | Withdraw (DR wallet / CR nostro) |
| `POST` | `/v1/finance/merchant-withdraw` | Merchant settlement + hot-shard sweep |
| `POST` | `/v1/finance/reverse` | Reverse an in-book transfer |
| `POST` | `/v1/finance/topup/reverse` | Reverse a top-up |
| `POST` | `/v1/finance/restraints` | Add a restraint / hold-lien on an account |
| `POST` | `/v1/finance/restraints/:id/release` | Release a restraint |
| `GET`  | `/v1/finance/transactions?acct_no=&limit=&before_seq=` | Account statement (transaction list, keyset-paged) |
| `GET`  | `/v1/finance/transactions/:tran_key` | Transaction detail (all legs of a `tran_internal_key`) |
| `POST` | `/v1/clients` | Create a client master record (identity only; no KYC/onboarding) |
| `PATCH`| `/v1/clients/:client_no` | Update client info |
| `POST` | `/v1/accounts` | Open a wallet (count-limited; CONSUMER 3/CCY, MERCHANT 10) |
| `PATCH`| `/v1/accounts/:acct_no` | Block / close / re-activate (close needs balance 0) |
| `GET`  | `/v1/accounts/:acct_no` | Account profile (no client PII) |
| `GET`  | `/v1/accounts/:acct_no/balance` | Customer balance (realtime / `?as_of_date=`) |
| `GET`  | `/v1/ops/accounts/:acct_no/balance` | Ops full balance view |
| `POST` | `/v1/ops/accounts/balance/batch` | Ops batch balance lookup |
| `POST` | `/v1/treasury/withdrawals/:ref/acked` | Mark withdrawal acknowledged |
| `POST` | `/v1/treasury/withdrawals/:ref/disbursing` | Mark withdrawal disbursing |
| `POST` | `/v1/treasury/withdrawals/:ref/completed` | Mark withdrawal completed |
| `POST` | `/v1/treasury/withdrawals/:ref/reverse` | Reverse a withdrawal |

---

## Database / Cơ sở dữ liệu

| Area | Files | Notes |
|------|-------|-------|
| Schema (DDL + SPs) | `db/export/schema.sql` | docker-init: all tables/indexes/functions/triggers; partitioned parents only. `post_topup/transfer/withdraw/merchant_withdraw`, 4 reversals, balance, withdraw state machine |
| Partitions | `db/export/partitions.sql` | monthly + hash partitions; `fn_ensure_wallet_partitions()` rolls forward |
| Reference seed | `db/export/seed.sql` | GL master, COA map, tran types, currency, account types |
| Fixtures & tests | `db/seeds/`, `db/tests/` | demo / load-test fixtures; SQL assertion suites (accounting, restraint (hold/lien), merchant flow, reconciliation check, reversal, EOD period lock) |

Run the SQL test suites against a seeded DB (each is self-contained — creates its
own fixtures and `ROLLBACK`s, except the read-only `*_check` reconciliation audits):

```bash
docker compose exec -T postgres psql -U postgres -d wallet -v ON_ERROR_STOP=1 -f /dev/stdin \
  < db/tests/wallet_accounting_test.sql
docker compose exec -T postgres psql -U postgres -d wallet -v ON_ERROR_STOP=1 -f /dev/stdin \
  < db/tests/wallet_restraint_test.sql
```

---

## Load testing / Kiểm thử tải

```bash
# HTTP load (k6) against the running service
bash deploy/loadtest/k6.sh -e PEAK=300

# DB/SP tier (pgbench, runs inside the postgres container)
SETUP=1 TEARDOWN=1 bash deploy/loadtest/run.sh 100 60 16

# TPS saturation sweep
LEVELS="100 200 400" bash deploy/loadtest/stress.sh
```

The pgbench tier drives an **8-way mix** (weights /100): `topup` 20 · `transfer`
(TRFOUT, fee) 18 · `withdraw` (WDRAW, fee+VAT) 12 · `reversal` (transfer reversal)
10 · `withdraw_reversal` (reversal **with fee** refund — RVWD+RVFEE) 10 ·
`merchant_topup` (consumer→settlement payment) 12 · `merchant_withdraw` 10 ·
`restraint` (add+remove a DEBIT/PLEDGE hold) 8 — one `deploy/loadtest/<op>.sql` per
scenario. The **k6 HTTP tier** (`k6_wallet.js`) mirrors this same 8-way mix at the
same weights, so the two tiers are directly comparable. `SETUP=1` seeds 10k consumer
wallets + 20 merchant groups (`LT*`); merchant SETTLEMENT wallets (`LTGS0001`… — 8
chars so they pass the HTTP `acct_no` validator) are funded on-ledger via
customer→merchant transfers and SHARDs fill via sweep (`post_topup` is STANDALONE-only),
so every seeded balance reconciles.

> ⚠️ `teardown.sql` ships with its DELETE block commented out (dry-run by design —
> it only prints before/after `LT*`/`PB*` row counts). To actually purge load-test
> data, uncomment the `BEGIN … COMMIT` block; `TEARDOWN=1` is otherwise a no-op.

Latest sweep notes: [docs/specs/k6_sweep.md](docs/specs/k6_sweep.md).

---

## Configuration / Cấu hình

| Scope | File | Key settings |
|-------|------|--------------|
| Infra (docker) | `.env` (from `.env.example`) | `POSTGRES_*`, role passwords, `PGBOUNCER_PORT` |
| Service | `services/wallet-service/.env` | `DB_DSN`, `HTTP_ADDR`, `*_TIMEOUT`, `OTEL_*`, `DB_MAX_CONNS` |

---

## Production Deployment / Triển khai production

The system supports two deployment targets: **AWS (EKS)** and **on-premise
Kubernetes**. Both use the same Kustomize base manifests with
environment-specific overlays.

> 🇻🇳 Hệ thống hỗ trợ triển khai trên **AWS (EKS)** hoặc **Kubernetes on-premise**.
> Cả hai dùng chung Kustomize base, chỉ khác overlay.

### Deployment architecture

```
Internet
    │
    ▼
┌──────────────────┐
│ Ingress          │  AWS: ALB (AWS LB Controller)
│ (TLS termination)│  On-prem: nginx-ingress + MetalLB/F5
└────────┬─────────┘
         │ :8080
         ▼
┌──────────────────────────────────────────────────────┐
│  Kubernetes Pods (HPA: 3–10 replicas)                 │
│  ┌─────────────────────┐  ┌────────────────────────┐ │
│  │  wallet-service      │  │  PgBouncer (sidecar)   │ │
│  │  Go/Gin, OTel        │─▶│  transaction pooling   │ │
│  │  :8080               │  │  localhost:6432        │ │
│  └─────────────────────┘  └───────────┬────────────┘ │
└────────────────────────────────────────┼──────────────┘
                                         │ :5432
                                         ▼
                              ┌────────────────────────┐
                              │  PostgreSQL 17          │
                              │  AWS: RDS (multi-AZ)   │
                              │  On-prem: StatefulSet  │
                              │    or CloudNativePG    │
                              └────────────────────────┘
```

### Directory structure (deploy)

```
deploy/
├── docker/                    # local dev (docker compose)
├── loadtest/                  # k6 + pgbench load tests
├── k8s/                       # ⭐ Kubernetes manifests
│   ├── base/                  #   shared (deployment, service, HPA, PDB, netpol)
│   ├── overlays/aws-eks/      #   AWS: ALB Ingress, IRSA, RDS endpoint
│   └── overlays/on-premise/   #   On-prem: nginx, PG StatefulSet, local storage
└── terraform/                 # ⭐ AWS infra as code
    ├── modules/vpc/           #   VPC 3-AZ, NAT, subnets
    ├── modules/rds/           #   RDS PG17, secrets, read replica
    ├── modules/eks/           #   EKS cluster, node groups, IRSA
    ├── modules/ecs/           #   ECS Fargate (alternative to EKS)
    ├── environments/staging/  #   staging tfvars + backend
    ├── environments/production/ # production tfvars + backend
    └── bootstrap/             #   S3 state bucket + DynamoDB lock + OIDC role
```

### Option A — AWS EKS

**Prerequisites:** AWS account, Terraform, `kubectl`, ACM certificate for TLS.

```bash
# 1. Bootstrap Terraform state (one-time)
cd deploy/terraform/bootstrap
terraform init && terraform apply
# → save output deploy_role_arn to GitHub secrets

# 2. Provision infrastructure (VPC + RDS + EKS)
cd deploy/terraform/environments/staging
terraform init
terraform plan -var="image_tag=$(git rev-parse --short HEAD)"
terraform apply

# 3. Connect kubectl to EKS
aws eks update-kubeconfig --name core-wallet-staging-cluster --region ap-southeast-1

# 4. Deploy wallet-service
kubectl apply -k deploy/k8s/overlays/aws-eks
kubectl -n wallet rollout status deployment/wallet-service

# 5. Load DB schema (first time — via bastion or VPN)
RDS_HOST=$(terraform output -raw rds_endpoint | cut -d: -f1)
PGPASSWORD=<from-secrets-manager> psql -h $RDS_HOST -U postgres -d wallet \
  -f db/export/schema.sql \
  -f db/export/partitions.sql \
  -f db/export/seed.sql
```

### Option B — On-Premise Kubernetes

**Prerequisites:** K8s cluster (kubeadm/RKE2/k3s), nginx-ingress, StorageClass
`fast-ssd` (local-path/ceph-rbd), private container registry.

```bash
# 1. Push images to internal registry
docker build -t registry.internal.local/core-wallet/wallet-service:v1.0.0 \
  services/wallet-service/
docker push registry.internal.local/core-wallet/wallet-service:v1.0.0

# 2. Update secrets (Vault/sealed-secrets — never commit real values)
# Edit deploy/k8s/overlays/on-premise/kustomization.yaml with your DB endpoint

# 3. Deploy (includes PostgreSQL StatefulSet)
kubectl apply -k deploy/k8s/overlays/on-premise
kubectl -n wallet rollout status deployment/wallet-service

# 4. Load DB schema (first time)
kubectl -n wallet exec -it postgres-primary-0 -- \
  psql -U postgres -d wallet \
    -f /docker-entrypoint-initdb.d/01-schema.sql \
    -f /docker-entrypoint-initdb.d/02-partitions.sql \
    -f /docker-entrypoint-initdb.d/03-seed.sql

# 5. Verify
kubectl -n wallet get pods
curl -k https://wallet-api.internal.local/healthz
```

### CI/CD pipeline

| Event | Action | Environment |
|-------|--------|-------------|
| Push to `master` | CI (lint + test + SQL suites) → Build images → Deploy | Staging (auto) |
| Tag `v*` | Build images → Deploy (manual approval) | Production |

Pipelines live in `.github/workflows/`:
- `ci.yml` — Go lint/vet/test + SQL test suites + Terraform validate
- `cd-k8s.yml` — Build images → `kustomize set image` → `kubectl apply`

For on-premise without GitHub connectivity: use **ArgoCD** (watches git repo,
auto-syncs) or a self-hosted runner with `kubeconfig` access.

### Capacity sizing by TPS

| TPS | K8s Pods | CPU/Pod | DB Instance | Est. Cost |
|:---:|:---:|:---:|:---:|:---:|
| 100 | 1–2 | 250m | db.t4g.medium / 2 vCPU | ~$125/mo |
| 500 | 2–4 | 500m | db.r6g.medium / 4 vCPU | ~$350/mo |
| 1,000 | 2–6 | 500m | db.r6g.large / 4 vCPU | ~$550/mo |
| **2,000** | **3–10** | **1000m** | **db.r6g.xlarge / 8 vCPU** | **~$900/mo** |
| 5,000 | 6–15 | 1000m | db.r6g.2xlarge / 16 vCPU | ~$1,800/mo |
| 10,000 | 10–30 | 2000m | db.r6g.4xlarge / 32 vCPU | ~$3,500/mo |

> Bottleneck is always the DB (single-writer PostgreSQL). The Go layer saturates
> at ~5,000 req/s per vCPU — well above what the DB can handle. Horizontal pod
> scaling provides redundancy, not throughput.

Full sizing rationale + storage growth estimates → [deploy/terraform/DEPLOYMENT_ARCHITECTURE.md](deploy/terraform/DEPLOYMENT_ARCHITECTURE.md).

### Key design decisions

| Decision | Rationale |
|----------|-----------|
| PgBouncer as **sidecar** (not shared) | Zero network hop (localhost); each pod gets its own pool; pool count scales with pods |
| **Kustomize** (not Helm) | Simpler, transparent patching; no template logic for a single-service deployment |
| NetworkPolicy + PDB | Least-privilege network; min 2 pods during rolling updates |
| TopologySpreadConstraints | Pods spread across zones — survives single-AZ failure |
| Separate DB overlay | AWS uses managed RDS; on-prem gets a StatefulSet (upgrade to CloudNativePG for HA) |
| IRSA (AWS) / Vault (on-prem) | No long-lived credentials in pods; secrets rotatable without redeploy |

---

## Documentation / Tài liệu

| Document | Description |
|----------|-------------|
| [docs/hld/wallet_HLD.md](docs/hld/wallet_HLD.md) | High-Level Design (objectives, context, NFRs, accounting, lifecycle) |
| [docs/dld/wallet_DLD.md](docs/dld/wallet_DLD.md) | Detailed Low-Level Design (schema, posting algorithms) |
| [docs/specs/finance_transaction.md](docs/specs/finance_transaction.md) | Transaction flows + API specs |
| [docs/specs/wallet_onboarding.md](docs/specs/wallet_onboarding.md) | Onboarding & KYC design |
| [docs/specs/error_management.md](docs/specs/error_management.md) | Error taxonomy & handling |
| [docs/specs/wallet_gl_coa_spec.md](docs/specs/wallet_gl_coa_spec.md) | GL chart-of-accounts spec |
| [docs/INDEX.md](docs/INDEX.md) | Full catalogue |
| [deploy/k8s/README.md](deploy/k8s/README.md) | Kubernetes deployment guide (AWS EKS + on-premise) |
| [deploy/terraform/README.md](deploy/terraform/README.md) | Terraform infrastructure guide |
| [deploy/terraform/DEPLOYMENT_ARCHITECTURE.md](deploy/terraform/DEPLOYMENT_ARCHITECTURE.md) | Deployment model + TPS capacity sizing |

---

## Disclaimer

Internal project. Database credentials in `.env.example` are **development
defaults only** — never reuse them outside local dev. The performance numbers
above are **design targets**, not benchmark results.
