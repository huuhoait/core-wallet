# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Core Wallet is a double-entry e-wallet **ledger**. The defining architectural decision: the Go service is a **thin RPC client** — it validates input and calls **one PostgreSQL stored function per operation**. All balance validation, double-entry posting, fee/VAT, and reversal logic live in plpgsql, executed atomically inside a single DB transaction. When changing business behavior, the change usually belongs in the PL/pgSQL stored functions (consolidated in `db/export/schema.sql`), not in Go.

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

**DB init:** on first volume init docker loads the entire DB from three pg_dump-generated files in `db/export/`, mounted into `/docker-entrypoint-initdb.d/` in order: `01-schema.sql` (all DDL — tables, indexes, SP functions, triggers), `02-partitions.sql` (creates the monthly + hash partitions), `03-seed.sql` (GL/COA/tran-type reference data). A plain `docker compose up` therefore yields a complete, ready DB — **no manual psql steps**. To change schema or an SP, edit `db/export/schema.sql` (or apply to a running DB) and re-init / regenerate — see `db/export/README.md` for the `pg_dump` regenerate commands. After any change, validate with `docker compose down -v && up`.

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

When adding a new write operation: add the SP function in `db/export/schema.sql`, add the method to the `WalletRepository` port, implement it in `postgres.go` following this exact pattern, then wire usecase → handler → route.

### Client-master change auditing (HARD RULE)

**Every API / SP that updates a client-master record MUST track the change and write an OLD→NEW diff row into the client audit log (`FM_CLIENT_AUDIT_LOG`).** Non-negotiable for compliance (US-8.1): all client identity / KYC / bank / document changes must be fully attributable — who (`audit.actor`), when, channel, `trace_id`, and before→after values. This covers `create_client`, `update_client`, `link_client_bank`, `set_default_client_bank`, and every future onboarding step that mutates client data (update-KYC, related-documents, etc.).

The mechanism is the `AFTER INSERT OR UPDATE OR DELETE` trigger `fn_audit_client_change`, attributed by the audit GUCs that `withTx` sets per-TX (step 3 above). So the rule has two halves:

1. **The write path runs through `withTx`** so the GUCs are set — never mutate a client table on a raw pool connection (that yields an unattributed `SYSTEM` row).
2. **The mutated table carries the `fn_audit_client_change` AFTER trigger.** When you add a client-master table or a new mutating SP, attach it (mirror `trg_audit_fm_client_bk` / `trg_audit_wlt_kyc`).

**Current coverage — close the gaps when you touch these:** the diff trigger fires today only on `FM_CLIENT_BANKS` (`trg_audit_fm_client_bk`) and `FM_CLIENT_KYC` (`trg_audit_fm_kyc`). `FM_CLIENT`, `FM_CLIENT_INDVL`, `FM_CLIENT_CONTACT`, `FM_CLIENT_IDENTIFIERS` only have the BEFORE `trg_audit_cols` (which stamps `created_by` / `updated_by`) — they do **not** yet write a diff row, so `update_client` (mutates `FM_CLIENT` / `FM_CLIENT_INDVL`) is **not** fully audited. Closing this (US-8.5) means adding `fn_audit_client_change` as an **`AFTER UPDATE`** trigger on those four tables — **UPDATE only, not INSERT** (a create has no before→after diff and is already attributed by `created_by` / `created_at`; soft-delete is an `UPDATE status='C'`, so it's covered).

### Error model — keep Go and SQL in sync

`domain.Error` carries a stable `Code`, an `HTTPStatus`, a client-safe `Detail`, and a wrapped `Cause`. **The codes in `internal/domain/errors.go` mirror the `RAISE EXCEPTION` codes in the SP functions (`db/export/schema.sql`)** — when you add or change an SP error, update both sides. `mapPgError` (in `repo/errors.go`) translates pg/ctx/lock/statement-timeout failures into the right `domain.Error`; the HTTP layer renders an RFC 7807 envelope with ISO 20022 reason mapping (`domain/iso20022.go`). Read-only balance/account queries skip the audit TX.

### Timeout layering (inner fires first)

PG `lock_timeout` 1.5s → PG `statement_timeout` 2.5s → pgx → HTTP request ctx 10s. Inner rings fire first so the customer gets a fast 503/504 rather than a hang. Values come from `services/wallet-service/.env` (`DB_LOCK_TIMEOUT`, `DB_STATEMENT_TIMEOUT`, `HTTP_REQUEST_TIMEOUT`).

## Database layout

The DB is the source of truth for the ledger. It is defined by three pg_dump-generated files in `db/export/`, loaded in order by docker-init (regenerate commands in `db/export/README.md`):

- `db/export/schema.sql` — all DDL: tables (incl. the 4 partitioned **parents**, no child partitions), sequences, indexes, constraints, the PL/pgSQL posting functions + procedures, and triggers (incl. the balanced-posting constraint trigger). Posting uses a **deferred-locking** pattern: Phase 1 validates with no lock, Phase 2 does the atomic balance UPDATE.
- `db/export/partitions.sql` — `fn_ensure_wallet_partitions(from, to)` creates the monthly partitions (`wlt_tran_hist` also HASH-subpartitioned, modulus 8) + a DEFAULT per parent. Idempotent; re-run to roll partitions forward.
- `db/export/seed.sql` — reference/master data only (GL master `fm_gl_mast`, COA map `wlt_gl_map`, tran types `wlt_tran_def`, currency, account types).
- `db/seeds/` — demo / load-test fixtures (`wallet_testdata_10.sql`, the `wallet_seed.sql` bulk generator, `coa/` source); **not** part of the init export.
- `db/tests/` — SQL assertion suites (accounting balance, merchant flow, reconciliation, reversal).

Key tables: `WLT_ACCT`, `WLT_ACCT_BAL`, `WLT_TRAN_HIST`, `WLT_OUTBOX` (transactional outbox), `WLT_WITHDRAW_TRACK`, `FM_CLIENT_AUDIT_LOG`. Load-test data is prefixed `LT*`/`PB*` (clients `LTC*`/`LTGC*`, groups `LTG*`, refs `LT-*`/`PB-*`) so `deploy/loadtest/teardown.sql` can scope cleanup without touching baseline `C*` data.

**HARD RULE — DDL lives in `db/export/schema.sql`.** Any DDL change (new or altered table, column, index, constraint, sequence, trigger, or PL/pgSQL function / SP) MUST be written into `db/export/schema.sql` as part of the same change — even when you also applied it live to a running DB. `schema.sql` is the source of truth docker-init loads; an `ALTER`/`CREATE` that only ran against a local DB and isn't reflected here is **lost on the next `docker compose down -v && up`** and never reaches review or other environments. Partition DDL belongs in `partitions.sql`, reference/master data in `seed.sql`. After editing, validate with `docker compose down -v && up` (regenerate via `pg_dump` per `db/export/README.md` if you changed the live DB first).

## Docs

`docs/INDEX.md` is the catalogue. `docs/hld/` = High-Level Design, `docs/dld/` = schema + posting algorithms, `docs/specs/` = feature/API specs (finance, errors, onboarding, COA). API contract: `docs/specs/finance_transaction.md` + `services/wallet-service/postman/`.
