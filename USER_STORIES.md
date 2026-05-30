# User Story Backlog / Danh sách User Story

Feature backlog for the Core Wallet ledger, with delivery status grounded in the
actual code, stored procedures, and tests in this repository (not the design
docs alone).

> 🇻🇳 Danh sách tính năng kèm trạng thái triển khai. Trạng thái được xác định
> dựa trên **code / stored procedure / test thực tế** trong repo, không chỉ dựa
> trên tài liệu thiết kế.

**Last reviewed / Cập nhật:** 2026-05-30

## Status legend / Chú thích trạng thái

| Symbol | Meaning | Ý nghĩa |
|:------:|---------|---------|
| ✅ | **Done** — implemented with code/SP, runnable | Đã làm — có code/SP, chạy được |
| 🟡 | **Partial** — DB/schema or one layer only; not end-to-end | Một phần — chỉ có schema/1 lớp, chưa trọn vẹn |
| ⬜ | **Not started** — design/spec only, no implementation | Chưa làm — chỉ có thiết kế, chưa code |

## Summary / Tổng quan

| Epic | ✅ | 🟡 | ⬜ |
|------|:--:|:--:|:--:|
| 1. Onboarding & Wallet Management | 1 | 1 | 6 |
| 2. Transactions — Posting | 6 | 0 | 1 |
| 3. Reversals & Refunds | 5 | 2 | 0 |
| 4. Balance & Statements | 5 | 0 | 0 |
| 5. Withdrawal Disbursement | 2 | 0 | 1 |
| 6. Accounting & GL Operations | 0 | 0 | 5 |
| 7. Eventing & Integration | 1 | 0 | 2 |
| 8. Audit, PII & Compliance | 3 | 1 | 1 |
| 9. Platform / Infra / Observability | 9 | 0 | 3 |
| 10. Quality — Testing & Load | 6 | 1 | 0 |
| **Total** | **38** | **7** | **19** |

---

## Epic 1 — Onboarding & Wallet Management / Mở ví & KYC

> Production onboarding flow is **not implemented** in the wallet service — only
> SQL seed helpers (`fn_create_client`, `fn_open_wallet`) exist for test data.
> Spec: [docs/specs/wallet_onboarding.md](docs/specs/wallet_onboarding.md).

| ID | User story | Status | Evidence / Notes |
|----|-----------|:------:|------------------|
| US-1.1 | As a new user, I register & verify OTP to create a Tier-1 client | ⬜ | Spec §3, §7.1–7.2. No `/v1/onboard/*` route. |
| US-1.2 | As a user, I pass eKYC to upgrade to Tier-2 | ⬜ | Spec §5.1, §7.3. Not implemented. |
| US-1.3 | As a Tier-2 user, I open a wallet (ACCT_NO gen + zero-balance snapshot) | 🟡 | `fn_open_wallet` exists in `db/seeds/` **for test seeding only** (spec §12). No production `POST /v1/wallets`. |
| US-1.4 | As the platform, I enforce wallet-count limits per customer | ⬜ | Spec §4.3. Not implemented. |
| US-1.5 | As ops, I block / close a wallet (close requires balance = 0) | ⬜ | Spec §6.2, AC-08. `WLT_ACCT.ACCT_STATUS` exists; no endpoint. |
| US-1.6 | As compliance, KYC downgrade & 12-month re-KYC | ⬜ | Spec §5.2, §13 (open item). |
| US-1.7 | As a corporate customer, I onboard (CORP, legal rep / UBO) | ⬜ | Spec §13 — schema gaps noted; not designed. |
| US-1.8 | As ops, I create/update a **client master record** (identity only, no KYC/onboarding flow) | ✅ | SP `create_client`/`update_client` (SECURITY DEFINER); `POST /v1/clients` + `PATCH /v1/clients/:client_no`. FM_CLIENT (+FM_CLIENT_INDVL). Wallet opening/KYC still out of scope. |

## Epic 2 — Transactions (Posting) / Giao dịch ghi sổ

> Core of the system. All posting is atomic double-entry inside PostgreSQL
> stored functions. Spec: [docs/specs/finance_transaction.md](docs/specs/finance_transaction.md).

| ID | User story | Status | Evidence / Notes |
|----|-----------|:------:|------------------|
| US-2.1 | As Treasury, I top-up a wallet (internal s2s credit) | ✅ | SP `post_topup`; `POST /v1/transactions/topup`. |
| US-2.2 | As a user, I transfer wallet → wallet (deadlock-safe lock ordering) | ✅ | SP `post_transfer` (5-leg); `POST /v1/transactions/transfer`. |
| US-2.3 | As a user, I withdraw to bank (DR wallet / CR nostro, fee + VAT) | ✅ | SP `post_withdraw`; `POST /v1/transactions/withdraw`. |
| US-2.4 | As a merchant, I withdraw with hot-shard sweep + settlement | ✅ | SP `post_merchant_withdraw`, `post_sweep_shard`, `fn_resolve_shard_acct_no`; `POST /v1/transactions/merchant-withdraw`. |
| US-2.5 | As finance, fees + VAT are computed and posted as separate legs | ✅ | Fee/VAT engine inside posting SPs; GL revenue + VAT payable. |
| US-2.6 | As an agent, I process a cash-in **deposit** (fee + VAT variant) | ⬜ | Spec §3. No `post_deposit` SP / route. |
| US-2.7 | As risk/ops, each posting carries metadata + a client-info snapshot | ✅ | SP `fn_validate_metadata`, `fn_build_client_info`; `WLT_TRAN_HIST.METADATA` / `CLIENT_INFO`. |

> **Cross-cutting (✅):** posting is **idempotent** by `reference` (`ON CONFLICT` /
> duplicate guard in `wallet_sp.sql`), and honours holds via `WLT_RESTRAINTS`.

## Epic 3 — Reversals & Refunds / Đảo & hoàn giao dịch

| ID | User story | Status | Evidence / Notes |
|----|-----------|:------:|------------------|
| US-3.1 | As ops, I reverse an in-book transfer (refund incl. fee + VAT) | ✅ | SP `post_transfer_reversal`; `POST /v1/transactions/reverse`; test `wallet_transfer_reversal_test.sql`. |
| US-3.2 | As ops, I reverse a top-up | ✅ | SP `post_topup_reversal`; `POST /v1/transactions/topup/reverse`. |
| US-3.3 | As Treasury, I reverse a withdrawal (refund amount + fee + VAT) | ✅ | SP `post_withdraw_reversal`; `POST /v1/treasury/withdrawals/:ref/reverse`. |
| US-3.4 | As ops, I reverse a merchant withdrawal | ✅ | SP `post_merchant_withdraw_reversal`. |
| US-3.5 | Reversals are idempotent and refund fee + VAT legs | ✅ | Reversal SPs write outbox + refund all legs. |
| US-3.6 | Reversal is rejected outside the allowed time window | 🟡 | Spec §6.4. Window rules designed; enforcement to be confirmed per SP. |
| US-3.7 | VAT reversal across a closed period is handled correctly | 🟡 | Spec §6.8 — depends on period close (Epic 6, not built). |

## Epic 4 — Balance & Statements / Số dư & sao kê

| ID | User story | Status | Evidence / Notes |
|----|-----------|:------:|------------------|
| US-4.1 | As a customer, I view my realtime balance | ✅ | SP `get_balance`; `GET /v1/wallets/:acct_no/balance`. |
| US-4.2 | As a customer, I view a historical balance (`as_of_date`) | ✅ | SP `get_balance_asof`; `?as_of_date=`. |
| US-4.3 | As ops, I view the full balance breakdown for a wallet | ✅ | SP `get_balance_ops`; `GET /v1/ops/wallets/:acct_no/balance`. |
| US-4.4 | As ops, I look up balances in batch | ✅ | SP `get_balance_batch`; `POST /v1/ops/wallets/balance/batch`. |
| US-4.5 | As a customer, I retrieve a transaction history / account statement | ✅ | `GET /v1/finance/transactions?acct_no=` (keyset-paged) + `GET /v1/finance/transactions/:tfr_key` (all legs) + `GET /v1/accounts/:acct_no` (profile). Direct SELECT on WLT_*. |

## Epic 5 — Withdrawal Disbursement / Theo dõi giải ngân rút tiền

| ID | User story | Status | Evidence / Notes |
|----|-----------|:------:|------------------|
| US-5.1 | Track withdrawal lifecycle SUBMITTED→ACKED→DISBURSING→COMPLETED/FAILED→REVERSED | ✅ | `WLT_WITHDRAW_TRACK`; SPs `mark_withdraw_acked/disbursing/completed`. |
| US-5.2 | As Treasury, I push disbursement state transitions | ✅ | `POST /v1/treasury/withdrawals/:ref/{acked,disbursing,completed}`. |
| US-5.3 | Auto-reverse withdrawals stuck > 24h (SLA-timeout janitor) | ⬜ | Designed (HLD v1.9). No janitor SP / worker. |

## Epic 6 — Accounting & GL Operations / Kế toán & vận hành sổ cái

> Subsystem §9b — designed in the HLD, **not implemented**. No SP, table set, or
> worker for any of the below exists yet.

| ID | User story | Status | Evidence / Notes |
|----|-----------|:------:|------------------|
| US-6.1 | EOD close & period locking | ⬜ | HLD §9b. Design only. |
| US-6.2 | Suspense / clearing GL framework | ⬜ | HLD §9b. Design only. |
| US-6.3 | Daily trial-balance materialization + signed proof | ⬜ | HLD §9b. Design only. |
| US-6.4 | E-invoice integration (Decree 123/2020, Circular 78/2021) | ⬜ | HLD §9b. Design only. |
| US-6.5 | Maker-checker manual journal entry workflow | ⬜ | HLD §9b. Design only. |

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

## Epic 10 — Quality: Testing & Load / Chất lượng: test & tải

| ID | User story | Status | Evidence / Notes |
|----|-----------|:------:|------------------|
| US-10.1 | SQL accounting/balance assertion suite | ✅ | `db/tests/wallet_accounting_test.sql`. |
| US-10.2 | Merchant flow + hot-wallet tests | ✅ | `db/tests/wallet_merchant_flow_test.sql`, `wallet_merchant_hotwallet_test.sql`. |
| US-10.3 | Reconciliation check | ✅ | `db/tests/wallet_reconciliation_check.sql`. |
| US-10.4 | Reversal test | ✅ | `db/tests/wallet_transfer_reversal_test.sql`. |
| US-10.5 | k6 HTTP load test + ledger-row attribution | ✅ | `deploy/loadtest/k6.sh`, `k6_wallet.js`, `k6_sweep.sh`. |
| US-10.6 | pgbench DB/SP load + TPS saturation sweep | ✅ | `deploy/loadtest/run.sh`, `stress.sh`. |
| US-10.7 | Go unit / integration tests | 🟡 | Error-envelope + ISO-20022 mapping covered (`internal/domain/iso20022_test.go`, `internal/http/handler/errors_test.go`); posting paths still only via SQL. |

---

## Next priorities (suggested) / Ưu tiên tiếp theo (gợi ý)

1. **Account/client CRUD + getClient** (Epic 1) — onboarding write path; needs production SPs (getClient needs the masked view).
2. **Outbox relay worker** (US-7.2) — events are written but never published.
3. **SLA-timeout janitor** (US-5.3) — stuck withdrawals never auto-reverse.
4. **Go test coverage** (US-10.7) — posting paths verified only via SQL today.
5. **Onboarding service** (Epic 1) — currently seed-only; no production path.

> These are suggestions based on the gap analysis above — confirm against the
> product roadmap before scheduling. / Đây là gợi ý dựa trên phân tích khoảng
> trống ở trên; cần đối chiếu roadmap sản phẩm trước khi lên kế hoạch.
