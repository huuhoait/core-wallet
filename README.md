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
│   ├── export/               #   the DB: schema.sql + partitions.sql + seed.sql (docker-init)
│   ├── seeds/                #   demo / load-test fixtures (testdata, bulk generator, COA src)
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
