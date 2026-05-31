# User Story Backlog / Danh sách User Story

Feature backlog for the Core Wallet ledger, with delivery status grounded in the
actual code, stored procedures, and tests in this repository (not the design
docs alone).

> 🇻🇳 Danh sách tính năng kèm trạng thái triển khai. Trạng thái được xác định
> dựa trên **code / stored procedure / test thực tế** trong repo, không chỉ dựa
> trên tài liệu thiết kế.

**Last reviewed / Cập nhật:** 2026-05-31

## Status legend / Chú thích trạng thái

| Symbol | Meaning | Ý nghĩa |
|:------:|---------|---------|
| ✅ | **Done** — implemented with code/SP, runnable | Đã làm — có code/SP, chạy được |
| 🟡 | **Partial** — DB/schema or one layer only; not end-to-end | Một phần — chỉ có schema/1 lớp, chưa trọn vẹn |
| ⬜ | **Not started** — design/spec only, no implementation | Chưa làm — chỉ có thiết kế, chưa code |

## Summary / Tổng quan

| Epic | ✅ | 🟡 | ⬜ |
|------|:--:|:--:|:--:|
| 1. Onboarding & Wallet Management | 5 | 0 | 10 |
| 2. Transactions — Posting | 6 | 0 | 0 |
| 3. Reversals & Refunds | 6 | 0 | 1 |
| 4. Balance & Statements | 5 | 0 | 0 |
| 5. Withdrawal Disbursement | 2 | 0 | 1 |
| 6. Accounting & GL Operations | 6 | 1 | 2 |
| 7. Eventing & Integration | 1 | 0 | 2 |
| 8. Audit, PII & Compliance | 2 | 1 | 2 |
| 9. Platform / Infra / Observability | 11 | 0 | 6 |
| 10. Quality — Testing & Load | 8 | 1 | 0 |
| **Total** | **52** | **3** | **24** |

---

## Epic 1 — Onboarding & Wallet Management / Mở ví & KYC

> **Onboarding is OTP-free** (OTP register removed 2026-05-31). The target flow
> is a **4-step workflow**: **(1)** create the client **and** open a
> zero-balance wallet in one step (US-1.1), **(2)** update KYC info / eKYC to
> raise the tier (US-1.2), **(3)** attach related documents (US-1.13), **(4)**
> link a bank account, which returns a `linkId` token (US-1.14). KYC for
> **individuals *and* organizations** is centralized in **one** `FM_CLIENT_KYC`
> table (renamed from `WLT_CLIENT_KYC`, US-9.16) carrying a JSONB `extra_data`
> key-value bag for type-specific fields — `FM_CLIENT_INDVL` folds in (US-1.15).
> Client master CRUD (US-1.8) and wallet open/block/close (US-1.3/1.5) with
> count limits (US-1.4) are implemented; the end-to-end onboarding wrapper that
> chains the 4 steps is **not**.
> Spec: [docs/specs/wallet_onboarding.md](docs/specs/wallet_onboarding.md).
>
> Merchant **hot-wallet lifecycle**: activation (US-1.9) is done; group
> provisioning (US-1.10), cold→hot deposit routing (US-1.11) and rescaling
> (US-1.12) are pending — see
> [docs/specs/finance_transaction.md](docs/specs/finance_transaction.md) §3/§4.8.

| ID | User story | Status | Evidence / Notes |
|----|-----------|:------:|------------------|
| US-1.1 | As a new user, I register with basic identity (**no OTP**) and the platform creates my client record **and** a zero-balance wallet in one onboarding step | ⬜ | **Step 1** of the flow. OTP register removed (2026-05-31). Building blocks exist — `create_client` (US-1.8) + `open_account` (US-1.3) — but no single `/v1/onboard` call chains them in one TX. Spec §3, §7.1. |
| US-1.2 | As a user, I submit / update KYC info (eKYC) to raise my KYC tier | ⬜ | **Step 2** of the flow. Writes `FM_CLIENT_KYC` (tier, eKYC score / liveness, type-specific `extra_data`). Spec §5.1, §7.2. Not implemented. |
| US-1.3 | As ops, I open a wallet (ACCT_NO gen, zero balance) | ✅ | SP `open_account`; `POST /v1/accounts`. ACCT_NO = `9701`+10 (seq_acct_no), `ACTUAL_BAL=0`. (KYC-tier gate **not** enforced — onboarding out of scope; EOD makes the historical snapshot.) |
| US-1.4 | As the platform, I enforce wallet-count limits per customer | ✅ | In `open_account` (§4.3): CONSUMER 3/CCY, MERCHANT 10 (closed excluded) → `MAX_WALLET_PER_CLIENT_EXCEEDED` (409). |
| US-1.5 | As ops, I block / close / re-activate a wallet (close requires balance = 0) | ✅ | SP `update_account_status`; `PATCH /v1/accounts/:acct_no`. State machine A↔B→C; close→`ACCT_CLOSE_NONZERO_BAL` if bal≠0; mutate closed→`ACCT_NOT_ACTIVE`. |
| US-1.6 | As compliance, KYC downgrade & 12-month re-KYC | ⬜ | Spec §5.2, §13 (open item). |
| US-1.7 | As a corporate / organization customer, I onboard (CORP / MER, legal rep / UBO) | ⬜ | No longer needs a separate ORG table — org-specific fields (legal_rep, ubo[], business_reg_no, …) live in `FM_CLIENT_KYC.extra_data` (US-1.15). `create_client` already accepts CORP / MER; the org KYC payload + UBO capture are still undesigned end-to-end. Spec §1, §13. |
| US-1.8 | As ops, I create/update a **client master record** (identity only, no KYC/onboarding flow) | ✅ | SP `create_client`/`update_client` (SECURITY DEFINER); `POST /v1/clients` + `PATCH /v1/clients/:client_no`. FM_CLIENT (+FM_CLIENT_INDVL — to fold into `FM_CLIENT_KYC.extra_data` per US-1.15). Wallet opening/KYC still out of scope. |
| US-1.9 | As ops, I **activate a merchant hot wallet** (promote a cold group, 0 shards → N) | ✅ | SP `activate_hot_wallet(group_id, shard_count:=4)` (SECURITY DEFINER); `POST /v1/merchant-groups/:group_id/activate`. Creates N empty `SHARD` sub-accounts (index 0..N-1, balance 0 — no funds move, same invariant as `open_account`), flips `WLT_ACCT_GROUP.SHARD_COUNT`. Tiers 4/8/16 (4 = default); groups are now created **cold** (`SHARD_COUNT` default 0, `chk_shard_count IN (0,4,8,16)`). One-way from cold → `GROUP_ALREADY_ACTIVATED` (P0053); bad tier → `INVALID_SHARD_COUNT` (P0052); missing settlement → `SETTLEMENT_NOT_FOUND` (P0054). Tests: `wallet_activate_hotwallet_test.sql` (12/12) + `dto/group_test.go` + `repo/errors_test.go`. |
| US-1.10 | As ops, I **provision a merchant/agent group** (group row + settlement account in one TX) | ⬜ | No SP yet — `WLT_ACCT_GROUP` + its `SETTLEMENT` account are created by hand (tests/seed). DLD §3.7 names `provision_acct_group(...)` but it does not exist. Prerequisite for US-1.9 on a real merchant (deferred settlement FK needs the same-TX pattern). |
| US-1.11 | As the platform, I **route merchant deposits** to settlement while cold (0 shards), to a shard once hot | ⬜ | `fn_resolve_shard_acct_no` raises `GROUP_NOT_FOUND` (P0050) for a cold group (proved in `wallet_cold_merchant_test.sql` TC4); **no caller branch** chooses settlement-vs-shard. Deposit/payment posting into a merchant group is not wired. |
| US-1.12 | As ops, I **rescale a hot wallet** (4→8→16) and rebalance existing shards | ⬜ | `activate_hot_wallet` is one-way cold→hot only. No SP adds shards to an already-hot group or rebalances balances across the new fan-out. |
| US-1.13 | As a user / ops, I attach & update **related documents** (CCCD images, business licence, UBO proofs) on a client's KYC | ⬜ | **Step 3** of the flow. Replaces the single scalar `FM_CLIENT_KYC.doc_url` with a `related_docs` JSONB array — `[{doc_type, link, status, uploaded_at}]` where `link` is an object-store URL / handle. No SP / endpoint yet. Spec §7.3, §11. |
| US-1.14 | As a user, I **link a bank account** during onboarding and receive a `linkId` token to reference it | ⬜ | **Step 4** of the flow. `link_client_bank` (`POST /v1/clients/:client_no/banks`) already returns `link_id` and encrypts `acct_no` → `ACCT_NO_ENC`; the **onboarding wrapper** that treats `link_id` as the client-facing opaque token (used by the default-bank `PUT`) and ties linkage to tier progression is pending. Spec §3.2, §7.4. |
| US-1.15 | As the platform, I centralize **individual *and* organization** KYC into one `FM_CLIENT_KYC` table with a JSONB `extra_data` key-value bag | ⬜ | Design-only. Folds `FM_CLIENT_INDVL` (surname / given_name / birth_date / sex / resident_status / …) and a new ORG branch (legal_rep, ubo[], business_reg_no, incorporation_date, industry_code) into `extra_data` JSONB on the single KYC row — no per-type child tables. Pairs with the `WLT_CLIENT_KYC` → `FM_CLIENT_KYC` rename (US-9.16); sequence both in one migration. Spec §2, §5. |

## Epic 2 — Transactions (Posting) / Giao dịch ghi sổ

> Core of the system. All posting is atomic double-entry inside PostgreSQL
> stored functions. Spec: [docs/specs/finance_transaction.md](docs/specs/finance_transaction.md).

| ID | User story | Status | Evidence / Notes |
|----|-----------|:------:|------------------|
| US-2.1 | As Treasury, I top-up a wallet (internal s2s credit) | ✅ | SP `post_topup`; `POST /v1/finance/topup`. |
| US-2.2 | As a user, I transfer wallet → wallet (deadlock-safe lock ordering) | ✅ | SP `post_transfer` (5-leg); `POST /v1/finance/transfer`. |
| US-2.3 | As a user, I withdraw to bank (DR wallet / CR nostro, fee + VAT) | ✅ | SP `post_withdraw`; `POST /v1/finance/withdraw`. |
| US-2.4 | As a merchant, I withdraw with hot-shard sweep + settlement | ✅ | SP `post_merchant_withdraw`, `post_sweep_shard`, `fn_resolve_shard_acct_no`; `POST /v1/finance/merchant-withdraw`. Groups are now created **cold** (0 shards) and promoted via `activate_hot_wallet` (US-1.9); withdraw still works cold (URGENT sweep loops over 0 shards → debits settlement directly). Deposit-side shard routing for cold groups = US-1.11. |
| US-2.5 | As finance, fees + VAT are computed and posted as separate legs | ✅ | Fee/VAT engine inside posting SPs; GL revenue + VAT payable. |
| US-2.7 | As risk/ops, each posting carries a metadata bag | ✅ | SP `fn_validate_metadata`; `WLT_TRAN_HIST.METADATA` (≤1KB, P1-forbidden). Client-info snapshot **retired**: `CLIENT_INFO` + `fn_build_client_info` removed (write-only, no reader); redundant `TRAN_DATE`/`EFFECT_DATE` also dropped (they always equalled `POST_DATE`). |

> **Cross-cutting (✅):** posting is **idempotent** by `reference` (`ON CONFLICT` /
> duplicate guard in `wallet_sp.sql`), and honours holds via `WLT_RESTRAINTS`.

## Epic 3 — Reversals & Refunds / Đảo & hoàn giao dịch

| ID | User story | Status | Evidence / Notes |
|----|-----------|:------:|------------------|
| US-3.1 | As ops, I reverse an in-book transfer (refund incl. fee + VAT) | ✅ | SP `post_transfer_reversal`; `POST /v1/finance/reverse`; test `wallet_transfer_reversal_test.sql`. |
| US-3.2 | As ops, I reverse a top-up | ✅ | SP `post_topup_reversal`; `POST /v1/finance/topup/reverse`. |
| US-3.3 | As Treasury, I reverse a withdrawal (refund amount + fee + VAT) | ✅ | SP `post_withdraw_reversal`; `POST /v1/treasury/withdrawals/:ref/reverse`. |
| US-3.4 | As ops, I reverse a merchant withdrawal | ✅ | SP `post_merchant_withdraw_reversal`. |
| US-3.5 | Reversals are idempotent and refund fee + VAT legs | ✅ | Reversal SPs write outbox + refund all legs. |
| US-3.6 | Reversal is rejected outside the allowed time window | ⬜ | Spec §6.4 defines the window, but **no reversal SP enforces it** (no `WINDOW_EXPIRED` / time check in any `*_reversal` SP). |
| US-3.7 | VAT reversal across a closed period is handled correctly | ✅ | Period locking (US-6.1) now makes a closed day immutable, so the closed VAT period (e.g. May) cannot be mutated; a reversal posts `POST_DATE = CURRENT_DATE` into the open period (June) per spec §6.8. Guaranteed by the write-freeze (`fn_freeze_closed_period`), proved in `db/tests/wallet_eod_period_lock_test.sql`. |

## Epic 4 — Balance & Statements / Số dư & sao kê

| ID | User story | Status | Evidence / Notes |
|----|-----------|:------:|------------------|
| US-4.1 | As a customer, I view my realtime balance | ✅ | SP `get_balance`; `GET /v1/accounts/:acct_no/balance`. |
| US-4.2 | As a customer, I view a historical balance (`as_of_date`) | ✅ | SP `get_balance_asof`; `?as_of_date=`. |
| US-4.3 | As ops, I view the full balance breakdown for a wallet | ✅ | SP `get_balance_ops`; `GET /v1/ops/accounts/:acct_no/balance`. |
| US-4.4 | As ops, I look up balances in batch | ✅ | SP `get_balance_batch`; `POST /v1/ops/accounts/balance/batch`. |
| US-4.5 | As a customer, I retrieve a transaction history / account statement | ✅ | `GET /v1/finance/transactions?acct_no=&from=&to=` (optional `post_date` range, 200 items/page, keyset `next_cursor`→`?before_seq=`) + `GET /v1/finance/transactions/:tfr_key` (all legs) + `GET /v1/accounts/:acct_no` (profile). Direct SELECT on WLT_*. |

## Epic 5 — Withdrawal Disbursement / Theo dõi giải ngân rút tiền

| ID | User story | Status | Evidence / Notes |
|----|-----------|:------:|------------------|
| US-5.1 | Track withdrawal lifecycle SUBMITTED→ACKED→DISBURSING→COMPLETED/FAILED→REVERSED | ✅ | `WLT_WITHDRAW_TRACK`; SPs `mark_withdraw_acked/disbursing/completed`. |
| US-5.2 | As Treasury, I push disbursement state transitions | ✅ | `POST /v1/treasury/withdrawals/:ref/{acked,disbursing,completed}`. |
| US-5.3 | Auto-reverse withdrawals stuck > 24h (SLA-timeout janitor) | ⬜ | Designed (HLD v1.9). No janitor SP / worker. |

## Epic 6 — Accounting & GL Operations / Kế toán & vận hành sổ cái

> Subsystem §9b. The **EOD-close batch** (write-DB, posting-safe) is implemented
> in `db/procedures/wallet_sp_eod.sql` — US-6.1 (incl. period locking) + US-6.3 +
> US-6.6–6.9, plus the GL-feed post of US-6.2. The full suspense/clearing GL
> framework, e-invoice and manual-JE workflows (US-6.2 remainder / 6.4 / 6.5)
> remain HLD design only.

| ID | User story | Status | Evidence / Notes |
|----|-----------|:------:|------------------|
| US-6.1 | EOD close & period locking | ✅ | Close batch `run_eod` (T1→T2→T5→T3→T6→**T7 close**), `wallet_sp_eod.sql`. **Period locking** done: `eod_close_period(D)` seals each past day in `WLT_PERIOD` (D < CURRENT_DATE; runs last, only after all tasks DONE), advancing the high-water mark; `fn_freeze_closed_period` triggers on `WLT_GL_BATCH`/`WLT_TRAN_HIST` make a closed day **fully immutable** (no INSERT/UPDATE/DELETE, SQLSTATE P0092 → `PERIOD_CLOSED`/409). Verified end-to-end + `db/tests/wallet_eod_period_lock_test.sql` (10/10). Unblocks US-3.7. |
| US-6.2 | Suspense / clearing GL framework | 🟡 | **GL-feed post** built: `eod_gl_feed_post(D)` (T3) finalises the day's GL journal `WLT_GL_BATCH` `'P'`→`'S'`, chunked + restart-safe. Full suspense/clearing GL framework (HLD §9b) still design only. |
| US-6.3 | Daily trial-balance materialization + signed proof | ✅ | SP `eod_trial_balance` (`wallet_sp_eod.sql`, T6 in `run_eod`). Per-`(gl_code,ccy)` from `WLT_GL_BATCH` → `WLT_TRIAL_BALANCE` (opening carry-forward + period DR/CR + closing); proves ΣDR=ΣCR ∧ Σclosing=0; seals each day in `WLT_TRIAL_BALANCE_PROOF` via a `sha256` **hash chain** (`chain=H(totals‖content‖prev)`). `eod_verify_chain()` re-derives & detects tampering (verified: editing a sealed line flips `chain_ok`→false). |
| US-6.4 | E-invoice integration (Decree 123/2020, Circular 78/2021) | ⬜ | HLD §9b. Design only. |
| US-6.5 | Maker-checker manual journal entry workflow | ⬜ | HLD §9b. Design only. |
| US-6.6 | EOD daily balance snapshot → `WLT_ACCT_BAL[D]` | ✅ | SP `eod_snapshot` (`wallet_sp_eod.sql`). Sparse (accounts that moved on D); close = last `WLT_TRAN_HIST` leg (ledger-authoritative, 24/7-correct); **finalises** the row posting maintains intraday (`ON CONFLICT DO UPDATE`), incl. `calc_bal` = close − final restraint overlay. Chunked short-TX (`COMMIT`/chunk → no xmin pinning), restart-safe. |
| US-6.7 | EOD prev-day balance roll | ✅ | SP `eod_prev_day_roll`. `WLT_ACCT.prev_day_actual_bal := close(D)` from the snapshot; sparse, skips no-ops (`IS DISTINCT FROM`), HOT update (non-indexed col, fillfactor 80), chunk 10k; depends on US-6.6. |
| US-6.8 | EOD restraint auto-expiry | ✅ | SP `eod_expire_restraints`. Restraints past `END_DATE` (`A`→`E`, `removed_by='EOD'`) + recompute `WLT_ACCT.{total_restrained_amt,cr_blocked,restraint_present}` (mirrors `release_restraint`); one account / TX. cf. US-8.2. |
| US-6.9 | EOD run history (audit log) + restart / failure handling | ✅ | Append-only `WLT_EOD_AUDIT_LOG` (status, started/finished, duration, rows — one row per run, via `eod_log`) + `WLT_EOD_RUN` resume cursor (`last_key`); `eod_mark_failed` records FAILED and keeps the cursor for retry. Batch/scheduler-driven (pg_cron / direct primary — no HTTP route by design). |

## Epic 7 — Eventing & Integration / Sự kiện & tích hợp

| ID | User story | Status | Evidence / Notes |
|----|-----------|:------:|------------------|
| US-7.1 | Every posting writes a Kafka event row atomically (transactional outbox) | ✅ | `WLT_OUTBOX`; `INSERT INTO WLT_OUTBOX` inside every posting SP. |
| US-7.2 | Relay outbox → Kafka (Debezium CDC primary, Go polling worker fallback) | ⬜ | HLD v1.9. Table only; no relay worker (`cmd/` has server only). |
| US-7.3 | Downstream consumers react to `withdraw.posted` etc. | ⬜ | Out of scope here (Treasury Service). |

## Epic 8 — Audit, PII & Compliance / Audit, PII & tuân thủ

| ID | User story | Status | Evidence / Notes |
|----|-----------|:------:|------------------|
| US-8.1 | Capture client changes (OLD/NEW diff, maker-checker) in an audit log | ✅ | `WLT_CLIENT_AUDIT_LOG`; trigger fns `fn_audit_client_change`, `fn_set_audit_columns`. Coverage today: `FM_CLIENT_BANKS` (`trg_audit_fm_client_bk`) + `WLT_CLIENT_KYC` (`trg_audit_wlt_kyc`) only — UPDATE diffs on the four **core** client tables are tracked in US-8.5. |
| US-8.2 | Apply holds/restraints (add/release) that block debits/credits | ✅ | SP `add_restraint`/`release_restraint`; `POST /v1/finance/restraints` (+ `/:id/release`); rolls up `TOTAL_RESTRAINED_AMT`/`CR_BLOCKED`, enforced in posting. Maker-checker/idempotency = gateway (deferred). |
| US-8.3 | Record reconciliation breaks | ⬜ | No `WLT_RECON_BREAK` table or live recon engine in the current schema (`db/export/schema.sql`) — verified absent. Only artifact is the read-only assertion script `db/tests/wallet_reconciliation_check.sql`, which *detects* breaks but does not record them. |
| US-8.5 | Audit **UPDATEs** to the core client-master tables (`FM_CLIENT`, `FM_CLIENT_INDVL`, `FM_CLIENT_CONTACT`, `FM_CLIENT_IDENTIFIERS`) as OLD→NEW diff rows | ⬜ | Closes the gap behind US-8.1: `fn_audit_client_change` fires today only on `FM_CLIENT_BANKS` + `WLT_CLIENT_KYC`; the four core tables only stamp `created_by`/`updated_by` via the BEFORE `trg_audit_cols`, so `update_client` writes **no** diff row. Add an **`AFTER UPDATE`** trigger (mirror `trg_audit_fm_client_bk`) on each — **UPDATE only, not INSERT** (a create has no before→after diff and is already captured by `created_by`/`created_at`). Soft-delete is an `UPDATE status='C'`, so it's covered; client-master rows are never hard-deleted. Satisfies the "Client-master change auditing" HARD RULE in `CLAUDE.md`. Design-only. |
| US-8.4 | PII protection: classification, encryption, masking, retention, access log | 🟡 | **Encryption + masking done**: `WLT_CLIENT_KYC.PHONE_NO_ENC`/`EMAIL_ENC` via `pgcrypto` `pgp_sym_encrypt` (DEK from `app.pii_dek`), `PHONE_NO_HASH` for unique lookup, + masked read views (`v_kyc_masked` etc.). Remaining (HLD §8.3): data classification, retention policy, and the `WLT_PII_ACCESS_LOG` access trail. |

## Epic 9 — Platform / Infra / Observability

| ID | User story | Status | Evidence / Notes |
|----|-----------|:------:|------------------|
| US-9.1 | Clean-architecture Go service (domain/usecase/repo/http) | ✅ | `services/wallet-service/internal/`. |
| US-9.2 | Env-driven configuration | ✅ | `internal/config/config.go`; `.env.example`. |
| US-9.3 | Graceful shutdown with context deadline | ✅ | `internal/http/server.go` `Start()`. |
| US-9.4 | Request-ID + audit-context middleware | ✅ | `internal/http/middleware/`. |
| US-9.5 | OpenTelemetry tracing | ✅ | `internal/telemetry/otel.go`, `otelgin`. |
| US-9.6 | Connection pooling via PgBouncer (transaction mode) | ✅ | `deploy/docker/pgbouncer/`; pgxpool. |
| US-9.7 | Dockerized local dev stack | ✅ | `docker-compose.yml` (PG17 + PgBouncer + Adminer). |
| US-9.8 | Liveness health check | ✅ | `GET /healthz`. |
| US-9.9 | Input validators (money, acct_no) + timeout layering | ✅ | `server.go` custom validators; 3s/2.5s/1.5s layering. |
| US-9.10 | AuthN / AuthZ + rate limiting | ⬜ | API-gateway concern (HLD §3); not in this service. |
| US-9.11 | CI/CD pipeline | ⬜ | None in repo. |
| US-9.12 | Metrics endpoint (Prometheus) | ⬜ | OTel traces only; no metrics endpoint. |
| US-9.13 | Read-replica routing for lag-tolerant reads | ✅ | `DB_READ_DSN` → separate read pool (`cmd/server`, `repo.readPool`). Only `GetAccount` (profile) + `ListTransactions` (statement) read it; unset → primary (strong consistency). Balance-realtime / tx-detail / ops stay on primary (read-your-writes). Both paths verified live. |
| US-9.14 | Rename `tfr_internal_key` → `tran_internal_id` for clarity (it groups the legs of **every** transaction type, not just transfers) | ✅ | Done. `tfr`="transfer" was a misnomer — the column is the per-transaction grouping key for topup/transfer/withdraw/merchant/reversal. Renamed the **DB column** on `WLT_TRAN_HIST` (+ all partitions), `WLT_WITHDRAW_TRACK`, `WLT_SWEEP_LOG`; all posting/reversal SP bodies + `RETURNS` + idempotency-cache & outbox jsonb keys (`db/export/schema.sql`); SQL test suites; Go identifiers (`TFRInternalKey`→`TranInternalID`) + repo SQL strings; DLD/HLD/spec docs. **API kept stable** — HTTP JSON field `tfr_internal_key` / `reversal_tfr_key` (Go DTO json tags) + route `:tfr_key` unchanged, so no client breaks (events/internals now use `tran_internal_id`). Verified: fresh `docker compose up` (0 init errors, 202 cols renamed), all SQL suites pass, `go build` + `go test -race` green. Siblings `TFR_SEQ_NO`/`seq_tfr` left as-is (out of scope). |
| US-9.15 | Rename cryptic `TRAN_TYPE` codes for clarity — e.g. `WDRAW`→`WITHDRAW`, `TRFOUT`→`TRANSF_OUT` — the column is `varchar(10)` but codes use 5–6-char abbreviations that waste the headroom | ⬜ | Deferred (logged from a load-test session, 2026-05-31). `WLT_TRAN_DEF.TRAN_TYPE` is the PK (`varchar(10)`); referenced by `WLT_TRAN_HIST.TRAN_TYPE` (`varchar(10)`, NOT NULL — **no DB FK**, link is logical) and self-referenced via `reversal_tran_type` / `fee_tran_type`. For consistency, rename the whole family, not just the two named: `TRFOUT`/`TRFIN`/`TRFOUTF`, `WDRAW`/`RVWD`/`FEEWD`, `MERCHWD`/`FEEMW`/`RVMWD`, `TOPUP`/`RVTPUP`, `FEETRF`/`RVTRF`/`RVFEE`. **Blast radius** (mirror US-9.14): seed defs (`db/export/seed.sql` `wlt_tran_def`), SP `DEFAULT` args + bodies (`db/export/schema.sql`, e.g. `post_transfer(... p_tran_type DEFAULT 'TRFOUT')`), Go (`internal/domain/types.go`, `http/dto/dto.go`, `repo/postgres.go`), load tests (`deploy/loadtest/k6_wallet.js` + `transfer.sql`/`withdraw*.sql`/`reversal.sql`/`setup.sql`/`merchant_topup.sql`), `postman/`, SQL suites (`db/tests/*`), docs (`docs/specs/finance_transaction.md`, DLD/HLD, COA spec). **Open decisions (defer to roadmap):** (1) **final names** — `varchar(10)` fits `WITHDRAW` (8) but **not** `TRANSFEROUT` (11) → choose `TRANSF_OUT`/`XFER_OUT`/`TRF_OUT`; (2) **history migration** — existing `WLT_TRAN_HIST` rows already carry old codes, so either `UPDATE` them in place or keep old codes read-valid (cf. US-9.14's API-stable approach); (3) widen the column if 10 chars proves too tight. |
| US-9.16 | Re-prefix `WLT_CLIENT_KYC` → `FM_CLIENT_KYC` (it is client master-data, not wallet ledger) | ⬜ | Deferred. KYC belongs to the **client-master (`FM_`) domain** — siblings already use it (`FM_CLIENT`, `FM_CLIENT_INDVL`, `FM_CLIENT_CONTACT`, `FM_CLIENT_IDENTIFIERS`, `FM_CLIENT_BANKS`); only `WLT_CLIENT_KYC` + `WLT_CLIENT_AUDIT_LOG` (US-9.17) still wear the wrong `WLT_` (ledger) prefix. Plain `ALTER TABLE … RENAME` + rename PK/indexes/constraints (`wlt_client_kyc_*`→`fm_client_kyc_*`) and any FK to `FM_CLIENT`. **Blast radius** (~97 refs): `db/export/schema.sql` (DDL, pgcrypto cols `PHONE_NO_ENC`/`EMAIL_ENC`/`PHONE_NO_HASH` + masked view `v_kyc_masked` — cf. US-8.4), Go `internal/repo/client.go`, seeds (`wallet_seed.sql`, `wallet_testdata_10.sql`), load test (`deploy/loadtest/setup.sql`), `db/maintenance/truncate_operational_data.sql`, docs (DLD/HLD/onboarding), `CHANGELOG.md`. **API impact:** none (no HTTP field/route is named after the table). Pairs with US-9.17 — do both in one migration. **US-1.15** layers the JSONB `extra_data` centralization (folding `FM_CLIENT_INDVL` + an ORG branch) onto this rename — sequence them together. |
| US-9.17 | Re-prefix `WLT_CLIENT_AUDIT_LOG` → `FM_CLIENT_AUDIT_LOG` (audit trail of client-master changes) | ⬜ | Deferred. Same rationale as US-9.16 — it records OLD/NEW diffs of `FM_CLIENT` (US-8.1), so it belongs to the `FM_` client-master family, not the `WLT_` ledger. **Partitioned table** → rename the parent **and** its monthly child partitions + the creation logic in `db/export/partitions.sql` (`fn_ensure_wallet_partitions`) + PK/indexes. **Blast radius** (~86 refs): `db/export/schema.sql` (DDL + the trigger fns that write it, `fn_audit_client_change`/`fn_set_audit_columns`), `db/export/partitions.sql`, `CLAUDE.md` ("Key tables"), `db/maintenance/truncate_operational_data.sql`, docs (DLD ~32 refs, HLD). **API impact:** none. Pairs with US-9.16. |

## Epic 10 — Quality: Testing & Load / Chất lượng: test & tải

| ID | User story | Status | Evidence / Notes |
|----|-----------|:------:|------------------|
| US-10.1 | SQL accounting/balance assertion suite | ✅ | `db/tests/wallet_accounting_test.sql`. |
| US-10.2 | Merchant flow + hot-wallet tests | ✅ | `db/tests/wallet_merchant_flow_test.sql`, `wallet_merchant_hotwallet_test.sql`, `wallet_activate_hotwallet_test.sql` (activation, 12/12), `wallet_cold_merchant_test.sql` (0-shard accounting & normal-wallet isolation, 7/7). |
| US-10.3 | Reconciliation check | ✅ | `db/tests/wallet_reconciliation_check.sql`. |
| US-10.4 | Reversal test | ✅ | `db/tests/wallet_transfer_reversal_test.sql`. |
| US-10.5 | k6 HTTP load test + ledger-row attribution | ✅ | `deploy/loadtest/k6.sh`, `k6_wallet.js`, `k6_sweep.sh`. |
| US-10.6 | pgbench DB/SP load + TPS saturation sweep | ✅ | `deploy/loadtest/run.sh`, `stress.sh`. 8-way mix: topup / transfer / withdraw / reversal / **withdraw_reversal** (reversal w/ fee) / **merchant_topup** / merchant_withdraw / **restraint** (add+remove). Verified 200 TPS × 10 min: 120,043 txns, 0 failed, +305,762 `WLT_TRAN_HIST` rows; double-entry holds across 621k GL legs. |
| US-10.7 | Go unit / integration tests | 🟡 | Error-envelope + ISO-20022 mapping covered (`internal/domain/iso20022_test.go`, `internal/http/handler/errors_test.go`); posting paths still only via SQL. |
| US-10.8 | Restraint (hold/lien) SQL assertion suite | ✅ | `db/tests/wallet_restraint_test.sql` — 25 cases: `add_restraint`/`release_restraint` rollup of all 4 types, validation errors `P0060–P0064`/`P0001`/`P0004`, posting-path enforcement (`P0025`/`P0026`/`P0029`), release restore/free-funds/`P0065–P0067`, multi-restraint recompute. |
| US-10.9 | Reversal check resolves reversal→original by a **type-aware** key (correct at scale) | ✅ | `wallet_reversal_check.sql` `keymap` previously UNIONed `seq_no` and `tran_internal_id` into one `link` column; when the two ranges overlap on large datasets, a value that is both a `SEQ_NO` and a `TRAN_INTERNAL_ID` cross-matched → **false R2 (double-reversal) / R3 (amount mismatch)**. **Fixed:** each key is now tagged by kind — `'seqno'` for `RVTRF`/`RVTPUP`/`RVMWD`, `'trfkey'` for `RVWD` (which links via `WLT_WITHDRAW_TRACK.TRAN_INTERNAL_ID`) — and `resolved` joins on `(link AND kind)`. Surfaced by the 200 TPS × 10 min run: 96,675 ambiguous links; precise checks confirmed **0 real double-reversals / 0 amount mismatches** (the engine was correct, only the check over-reported). Verified by an isolated collision repro (a `seq_no` equal to another txn's `tran_internal_id`): old keymap cross-matched 2 originals, tagged keymap resolves to exactly 1. |

---

## Next priorities (suggested) / Ưu tiên tiếp theo (gợi ý)

1. **getClient** (Epic 1) — `GET /v1/clients/:id` needs the masked PII view (`v_kyc_masked`). (client CRUD + account open/block/close already done — US-1.3/1.4/1.5/1.8.)
2. **Outbox relay worker** (US-7.2) — events are written but never published.
3. **SLA-timeout janitor** (US-5.3) — stuck withdrawals never auto-reverse.
4. **Go test coverage** (US-10.7) — posting paths verified only via SQL today.
5. **Onboarding service** (Epic 1) — currently seed-only; no production path.
6. ~~**EOD period-locking + GL feed** (US-6.1/6.2)~~ — ✅ done: `eod_close_period` write-freeze (full immutability) on closed business dates (unblocks US-3.7) + chunked `eod_gl_feed_post` (`WLT_GL_BATCH` P→S). Remaining Epic-6 gaps: full suspense/clearing GL (US-6.2), e-invoice (US-6.4), maker-checker JE (US-6.5), reversal time-window (US-3.6).
7. **Merchant hot-wallet lifecycle** — activation (US-1.9) ✅ done. Next, in order: group provisioning SP (US-1.10) → cold→hot deposit routing (US-1.11) → hot-wallet rescale 4→8→16 with rebalance (US-1.12).

> These are suggestions based on the gap analysis above — confirm against the
> product roadmap before scheduling. / Đây là gợi ý dựa trên phân tích khoảng
> trống ở trên; cần đối chiếu roadmap sản phẩm trước khi lên kế hoạch.
