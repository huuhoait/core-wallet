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
| 1. Onboarding & Wallet Management | 5 | 0 | 7 |
| 2. Transactions — Posting | 6 | 0 | 0 |
| 3. Reversals & Refunds | 5 | 1 | 1 |
| 4. Balance & Statements | 5 | 0 | 0 |
| 5. Withdrawal Disbursement | 2 | 0 | 1 |
| 6. Accounting & GL Operations | 5 | 1 | 3 |
| 7. Eventing & Integration | 1 | 0 | 2 |
| 8. Audit, PII & Compliance | 2 | 1 | 1 |
| 9. Platform / Infra / Observability | 10 | 0 | 3 |
| 10. Quality — Testing & Load | 6 | 1 | 0 |
| **Total** | **47** | **4** | **18** |

---

## Epic 1 — Onboarding & Wallet Management / Mở ví & KYC

> Client master CRUD (US-1.8) and wallet open/block/close (US-1.3/1.5) with
> count limits (US-1.4) are implemented. The **onboarding flow** (OTP, eKYC, KYC
> tier progression) is **not** — that remains seed-only / out of scope.
> Spec: [docs/specs/wallet_onboarding.md](docs/specs/wallet_onboarding.md).
>
> Merchant **hot-wallet lifecycle**: activation (US-1.9) is done; group
> provisioning (US-1.10), cold→hot deposit routing (US-1.11) and rescaling
> (US-1.12) are pending — see
> [docs/specs/finance_transaction.md](docs/specs/finance_transaction.md) §3/§4.8.

| ID | User story | Status | Evidence / Notes |
|----|-----------|:------:|------------------|
| US-1.1 | As a new user, I register & verify OTP to create a Tier-1 client | ⬜ | Spec §3, §7.1–7.2. No `/v1/onboard/*` route. |
| US-1.2 | As a user, I pass eKYC to upgrade to Tier-2 | ⬜ | Spec §5.1, §7.3. Not implemented. |
| US-1.3 | As ops, I open a wallet (ACCT_NO gen, zero balance) | ✅ | SP `open_account`; `POST /v1/accounts`. ACCT_NO = `9701`+10 (seq_acct_no), `ACTUAL_BAL=0`. (KYC-tier gate **not** enforced — onboarding out of scope; EOD makes the historical snapshot.) |
| US-1.4 | As the platform, I enforce wallet-count limits per customer | ✅ | In `open_account` (§4.3): CONSUMER 3/CCY, MERCHANT 10 (closed excluded) → `MAX_WALLET_PER_CLIENT_EXCEEDED` (409). |
| US-1.5 | As ops, I block / close / re-activate a wallet (close requires balance = 0) | ✅ | SP `update_account_status`; `PATCH /v1/accounts/:acct_no`. State machine A↔B→C; close→`ACCT_CLOSE_NONZERO_BAL` if bal≠0; mutate closed→`ACCT_NOT_ACTIVE`. |
| US-1.6 | As compliance, KYC downgrade & 12-month re-KYC | ⬜ | Spec §5.2, §13 (open item). |
| US-1.7 | As a corporate customer, I onboard (CORP, legal rep / UBO) | ⬜ | Spec §13 — schema gaps noted; not designed. |
| US-1.8 | As ops, I create/update a **client master record** (identity only, no KYC/onboarding flow) | ✅ | SP `create_client`/`update_client` (SECURITY DEFINER); `POST /v1/clients` + `PATCH /v1/clients/:client_no`. FM_CLIENT (+FM_CLIENT_INDVL). Wallet opening/KYC still out of scope. |
| US-1.9 | As ops, I **activate a merchant hot wallet** (promote a cold group, 0 shards → N) | ✅ | SP `activate_hot_wallet(group_id, shard_count:=4)` (SECURITY DEFINER); `POST /v1/merchant-groups/:group_id/activate`. Creates N empty `SHARD` sub-accounts (index 0..N-1, balance 0 — no funds move, same invariant as `open_account`), flips `WLT_ACCT_GROUP.SHARD_COUNT`. Tiers 4/8/16 (4 = default); groups are now created **cold** (`SHARD_COUNT` default 0, `chk_shard_count IN (0,4,8,16)`). One-way from cold → `GROUP_ALREADY_ACTIVATED` (P0053); bad tier → `INVALID_SHARD_COUNT` (P0052); missing settlement → `SETTLEMENT_NOT_FOUND` (P0054). Tests: `wallet_activate_hotwallet_test.sql` (12/12) + `dto/group_test.go` + `repo/errors_test.go`. |
| US-1.10 | As ops, I **provision a merchant/agent group** (group row + settlement account in one TX) | ⬜ | No SP yet — `WLT_ACCT_GROUP` + its `SETTLEMENT` account are created by hand (tests/seed). DLD §3.7 names `provision_acct_group(...)` but it does not exist. Prerequisite for US-1.9 on a real merchant (deferred settlement FK needs the same-TX pattern). |
| US-1.11 | As the platform, I **route merchant deposits** to settlement while cold (0 shards), to a shard once hot | ⬜ | `fn_resolve_shard_acct_no` raises `GROUP_NOT_FOUND` (P0050) for a cold group (proved in `wallet_cold_merchant_test.sql` TC4); **no caller branch** chooses settlement-vs-shard. Deposit/payment posting into a merchant group is not wired. |
| US-1.12 | As ops, I **rescale a hot wallet** (4→8→16) and rebalance existing shards | ⬜ | `activate_hot_wallet` is one-way cold→hot only. No SP adds shards to an already-hot group or rebalances balances across the new fan-out. |

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
| US-8.1 | Capture every client change (OLD/NEW diff, maker-checker) in an audit log | ✅ | `WLT_CLIENT_AUDIT_LOG`; trigger fns `fn_audit_client_change`, `fn_set_audit_columns`. |
| US-8.2 | Apply holds/restraints (add/release) that block debits/credits | ✅ | SP `add_restraint`/`release_restraint`; `POST /v1/finance/restraints` (+ `/:id/release`); rolls up `TOTAL_RESTRAINED_AMT`/`CR_BLOCKED`, enforced in posting. Maker-checker/idempotency = gateway (deferred). |
| US-8.3 | Record reconciliation breaks | 🟡 | `WLT_RECON_BREAK` table + `db/tests/wallet_reconciliation_check.sql`; no live recon engine. |
| US-8.4 | PII protection: classification, encryption, masking, retention, access log | ⬜ | HLD §8.3 design. App-level controls/`WLT_PII_ACCESS_LOG` not built. |

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

## Epic 10 — Quality: Testing & Load / Chất lượng: test & tải

| ID | User story | Status | Evidence / Notes |
|----|-----------|:------:|------------------|
| US-10.1 | SQL accounting/balance assertion suite | ✅ | `db/tests/wallet_accounting_test.sql`. |
| US-10.2 | Merchant flow + hot-wallet tests | ✅ | `db/tests/wallet_merchant_flow_test.sql`, `wallet_merchant_hotwallet_test.sql`, `wallet_activate_hotwallet_test.sql` (activation, 12/12), `wallet_cold_merchant_test.sql` (0-shard accounting & normal-wallet isolation, 7/7). |
| US-10.3 | Reconciliation check | ✅ | `db/tests/wallet_reconciliation_check.sql`. |
| US-10.4 | Reversal test | ✅ | `db/tests/wallet_transfer_reversal_test.sql`. |
| US-10.5 | k6 HTTP load test + ledger-row attribution | ✅ | `deploy/loadtest/k6.sh`, `k6_wallet.js`, `k6_sweep.sh`. |
| US-10.6 | pgbench DB/SP load + TPS saturation sweep | ✅ | `deploy/loadtest/run.sh`, `stress.sh`. |
| US-10.7 | Go unit / integration tests | 🟡 | Error-envelope + ISO-20022 mapping covered (`internal/domain/iso20022_test.go`, `internal/http/handler/errors_test.go`); posting paths still only via SQL. |

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
