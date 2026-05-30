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

- **Tech stack:** Go 1.23 (Gin) + PostgreSQL 17 (plpgsql stored procedures) + PgBouncer (transaction mode) + OpenTelemetry
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
├── docker-compose.yml        # local dev stack (PG17 + PgBouncer + Adminer)
├── .env.example              # infra env template (copy to .env)
│
├── docs/                     # design documentation
│   ├── INDEX.md              #   doc catalogue
│   ├── hld/                  #   High-Level Design (+ 20-TPS variant)
│   ├── dld/                  #   Detailed Low-Level Design (schema, posting)
│   └── specs/                #   feature specs (finance, errors, onboarding, COA, T24, k6)
│
├── db/                       # PostgreSQL — single source of truth for the ledger
│   ├── ddl/                  #   schema (wallet_ddl.sql, wallet_schema.sql)
│   ├── procedures/           #   posting stored functions (wallet_sp*.sql)
│   ├── seeds/                #   reference + test data (COA, tran-types, fixtures)
│   └── tests/                #   SQL assertion suites (accounting, recon, reversal)
│
├── services/
│   └── wallet-service/       # Go service — thin RPC over the stored procedures
│       ├── cmd/server/       #   main entrypoint
│       ├── internal/         #   domain / usecase / repo / http (clean architecture)
│       └── postman/          #   Postman collection + environment
│
└── deploy/
    ├── docker/               # postgres + pgbouncer config & init scripts
    └── loadtest/             # k6 (HTTP) + pgbench (DB) load tests
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
└─────────────────────────────────────────┘
```

**Timeout layering:** Go context 3 s → PG `statement_timeout` 2.5 s → PG
`lock_timeout` 1.5 s. **Posting** uses a deferred-locking pattern (Phase 1
no-lock validate → Phase 2 atomic UPDATE).

---

## Getting started / Bắt đầu

### 1. Start the database stack

```bash
cp .env.example .env                 # adjust passwords if needed
docker compose up -d                 # PG17 + PgBouncer
docker compose logs -f postgres      # wait for "ready to accept connections"
```

On first start, PostgreSQL auto-loads `db/ddl/wallet_schema.sql` and
`db/procedures/wallet_sp.sql`. The remaining procedure files (balance, merchant,
reversals) and seeds are applied manually:

```bash
# apply the rest of the stored functions + seed reference data
for f in db/procedures/wallet_sp_balance.sql \
         db/procedures/wallet_sp_merchant.sql \
         db/procedures/wallet_sp_topup_reversal.sql \
         db/procedures/wallet_sp_transfer_reversal.sql \
         db/procedures/wallet_sp_restraint.sql \
         db/procedures/wallet_sp_client.sql \
         db/seeds/wallet_coa_seed.sql \
         db/seeds/wallet_tran_type_ext.sql \
         db/seeds/wallet_seed.sql; do
  docker compose exec -T postgres psql -U postgres -d wallet -f "/dev/stdin" < "$f"
done
```

> 🇻🇳 Docker chỉ tự nạp `wallet_schema.sql` + `wallet_sp.sql` khi khởi tạo lần
> đầu. Các stored function còn lại và seed phải nạp thủ công như trên.

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
| `GET`  | `/v1/finance/transactions/:tfr_key` | Transaction detail (all legs of a `tfr_internal_key`) |
| `POST` | `/v1/clients` | Create a client master record (identity only; no KYC/onboarding) |
| `PATCH`| `/v1/clients/:client_no` | Update client info |
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
| Schema (DDL) | `db/ddl/wallet_ddl.sql`, `db/ddl/wallet_schema.sql` | `wallet_schema.sql` is the docker-init schema |
| Posting procedures | `db/procedures/wallet_sp*.sql` | `post_topup/transfer/withdraw/merchant_withdraw`, 4 reversals, balance, withdraw state machine |
| Seeds & reference | `db/seeds/` | Chart of accounts (`coa/`), tran-type extensions, test fixtures |
| SQL test suites | `db/tests/` | Accounting balance, merchant flow, reconciliation check, reversal |

Run the SQL test suites against a seeded DB:

```bash
docker compose exec -T postgres psql -U postgres -d wallet -f /dev/stdin \
  < db/tests/wallet_accounting_test.sql
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

Latest sweep notes: [docs/specs/k6_sweep.md](docs/specs/k6_sweep.md).

---

## Configuration / Cấu hình

| Scope | File | Key settings |
|-------|------|--------------|
| Infra (docker) | `.env` (from `.env.example`) | `POSTGRES_*`, role passwords, `PGBOUNCER_PORT` |
| Service | `services/wallet-service/.env` | `DB_DSN`, `HTTP_ADDR`, `*_TIMEOUT`, `OTEL_*`, `DB_MAX_CONNS` |

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

---

## Disclaimer

Internal project. Database credentials in `.env.example` are **development
defaults only** — never reuse them outside local dev. The performance numbers
above are **design targets**, not benchmark results.
