# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Core Wallet is a double-entry e-wallet **ledger**. The defining architectural decision: the Go service is a **thin RPC client** — it validates input and calls **one PostgreSQL stored function per operation**. All balance validation, double-entry posting, fee/VAT, and reversal logic live in plpgsql, executed atomically inside a single DB transaction. When changing business behavior, the change usually belongs in `db/procedures/*.sql`, not in Go.

**Scope boundary:** internal synchronous posting only (top-up, transfer, withdraw, merchant settlement, fee/VAT, reversal). External rails (NAPAS, partner banks, card 3DS, MT940 recon) are deliberately out of scope and belong to a separate Treasury Service — do not add them here.

Tech: Go 1.23 (Gin) + PostgreSQL 17 (plpgsql) + PgBouncer (transaction-mode pooling) + OpenTelemetry.

## Git workflow (HARD RULE)

**Never merge directly into `master`. Every change reaches `master` only through a reviewed Pull Request.**

1. Branch off `master`: `git checkout -b feature/<name>` (never commit on `master`).
2. Commit on the feature branch, then push it: `git push -u origin feature/<name>`.
3. Open a PR into `master`: `gh pr create --base master`. Merge only after review + green CI.

Do **NOT** run `git merge <branch>` into a local `master`, and do **NOT** `git push origin master` directly. `master` advances exclusively by merging an approved PR. If a local `master` ever gets ahead of `origin/master` outside this flow, reset it (`git reset --hard origin/master`) and redo the change as a PR.

## Common commands

All Go commands run from `services/wallet-service/`:

```bash
make run          # run against local PgBouncer (:6432), OTel off, listens :8080
make build        # CGO_ENABLED=0 static binary → bin/wallet-service
make test         # go test -race -count=1 ./...
make lint         # golangci-lint run ./...  (brew install golangci-lint)
make vet          # go vet ./...
make smoke        # curl a top-up against a running stack
```

Run a single test:

```bash
go test -race -run TestName ./internal/domain/        # one package
go test -race -run TestName/subtest ./internal/...     # one subtest
```

Database stack (from repo root):

```bash
docker compose up -d                 # PG17 + PgBouncer + Adminer
docker compose logs -f postgres      # wait for "ready to accept connections"
```

**Critical init nuance:** docker only auto-loads `db/ddl/wallet_schema.sql` + `db/procedures/wallet_sp.sql` on first volume init. The remaining procedures (`wallet_sp_balance/merchant/topup_reversal/transfer_reversal/restraint/client`) and all seeds (`db/seeds/`) must be applied **manually** afterward — see README "Getting started". A fresh feature in a not-yet-loaded SP file will silently be missing until you load it. After editing any `wallet_sp*.sql`, re-apply it:

```bash
docker compose exec -T postgres psql -U postgres -d wallet -f /dev/stdin < db/procedures/wallet_sp.sql
```

SQL test suites (run against a seeded DB) and load tests:

```bash
docker compose exec -T postgres psql -U postgres -d wallet -f /dev/stdin < db/tests/wallet_accounting_test.sql
bash deploy/loadtest/k6.sh -e PEAK=300                          # HTTP tier
SETUP=1 TEARDOWN=1 bash deploy/loadtest/run.sh 100 60 16         # DB/SP tier (pgbench)
```

## Architecture

### Layering (clean architecture, strictly enforced)

```
http (gin) → handler → usecase → repo → PostgreSQL stored functions
                          ↓ depends on ↓
                        domain (pure types + errors)
```

- `internal/domain/` — pure types and the canonical `Error`. No framework imports.
- `internal/usecase/` — application services + **driven ports** (`port.go` defines `WalletRepository`). **Hard rule (see `port.go`): usecase imports `domain` only — never gin, pgx, or any framework.**
- `internal/repo/` — `PgWalletRepo` implements `WalletRepository` against `pgxpool`.
- `internal/http/` — `server.go` (routing), `handler/`, `dto/`, `middleware/`.

Wiring is in `cmd/server/main.go`: `config → otel → pgxpool → repo → usecase → http`.

### CQRS Pattern (Command Query Responsibility Segregation)

To maximize performance, minimize locking overhead, and support massive throughput, the repository implements a strict CQRS pattern:

- **Commands (Write Paths)**: All mutating operations (e.g., `Topup`, `Transfer`, `Withdraw`, `Reverse`, `AddRestraint`, `OpenAccount`) MUST go through `PgWalletRepo.withTx` in `internal/repo/postgres.go`. This opens an active transaction, sets localized timeouts (`statement_timeout`, `lock_timeout`), registers session-safe audit GUCs (`set_config(...)`), and invokes the corresponding write-heavy PL/pgSQL stored procedure.
- **Queries (Read Paths)**: All read-only operations (e.g., `GetBalance`, `GetBalanceOps`, `GetBalanceAsOf`, `GetBalanceBatch` in `repo/balance.go`, and transactions/account queries in `repo/transaction.go`) bypass transaction wrapping and audit GUC setups. They call `r.pool.Query` or `r.pool.QueryRow` directly on the `pgxpool`. This conforms to `BAL-05` (balance reads must not write an OLTP audit row) and avoids unnecessary transactional overhead.
- **Consistency & Routing**: Write commands always run on the primary. Read queries default to running on the primary database pool to ensure strong consistency (e.g., `BAL-06: read-after-write consistency`), but the isolation of read ports makes the codebase fully prepared to route high-volume reporting queries to read replicas if needed.

### The repo transaction pattern (most important to understand)

Every write goes through `PgWalletRepo.withTx` (`internal/repo/postgres.go`). Each call:

1. Opens a pgx transaction.
2. `SET LOCAL statement_timeout / lock_timeout` — **per-TX, not per-session**, because PgBouncer transaction-mode may route consecutive TXs to different server connections. Session-level `SET` is unreliable here.
3. Sets audit GUCs via `SELECT set_config('audit.actor'/'audit.channel'/'app.trace_id'/…, value, true)` (the `true` = is_local, scoped to this TX). The DB trigger `trg_audit_cols` and `fn_audit_client_change` read these via `current_setting()` to attribute the change.
4. Calls exactly one SP (`post_topup`, `post_transfer`, `post_withdraw`, `post_merchant_withdraw`, the reversals, `mark_withdraw_*`, etc.), passing positional params.
5. Commits. A deferred unconditional `Rollback` uses a **fresh context** (not the caller's, which may already be timed out) so cleanup always reaches the server.

When adding a new write operation: add the SP in `db/procedures/`, add the method to the `WalletRepository` port, implement it in `postgres.go` following this exact pattern, then wire usecase → handler → route.

### Error model — keep Go and SQL in sync

`domain.Error` carries a stable `Code`, an `HTTPStatus`, a client-safe `Detail`, and a wrapped `Cause`. **The codes in `internal/domain/errors.go` mirror the `RAISE EXCEPTION` codes in `db/procedures/wallet_sp.sql`** — when you add or change an SP error, update both sides. `mapPgError` (in `repo/errors.go`) translates pg/ctx/lock/statement-timeout failures into the right `domain.Error`; the HTTP layer renders an RFC 7807 envelope with ISO 20022 reason mapping (`domain/iso20022.go`). Read-only balance/account queries skip the audit TX.

### Timeout layering (inner fires first)

PG `lock_timeout` 1.5s → PG `statement_timeout` 2.5s → pgx → HTTP request ctx 10s. Inner rings fire first so the customer gets a fast 503/504 rather than a hang. Values come from `services/wallet-service/.env` (`DB_LOCK_TIMEOUT`, `DB_STATEMENT_TIMEOUT`, `HTTP_REQUEST_TIMEOUT`).

## Database layout

The DB is the source of truth for the ledger.

- `db/ddl/` — `wallet_schema.sql` is the docker-init schema and the single source of truth for the DDL.
- `db/procedures/wallet_sp*.sql` — posting SPs. Posting uses a **deferred-locking** pattern: Phase 1 validates with no lock, Phase 2 does the atomic balance UPDATE.
- `db/seeds/` — chart of accounts (`coa/`), tran-type extensions, fixtures.
- `db/tests/` — SQL assertion suites (accounting balance, merchant flow, reconciliation, reversal).

Key tables: `WLT_ACCT`, `WLT_ACCT_BAL`, `WLT_TRAN_HIST`, `WLT_OUTBOX` (transactional outbox), `WLT_WITHDRAW_TRACK`, `WLT_CLIENT_AUDIT_LOG`. Load-test data is prefixed `LT*`/`PB*` (clients `LTC*`/`LTGC*`, groups `LTG*`, refs `LT-*`/`PB-*`) so `deploy/loadtest/teardown.sql` can scope cleanup without touching baseline `C*` data.

## Docs

`docs/INDEX.md` is the catalogue. `docs/hld/` = High-Level Design, `docs/dld/` = schema + posting algorithms, `docs/specs/` = feature/API specs (finance, errors, onboarding, COA). API contract: `docs/specs/finance_transaction.md` + `services/wallet-service/postman/`.
