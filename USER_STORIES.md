# User Story Backlog / Danh sách User Story

Feature backlog for the Core Wallet ledger, with delivery status grounded in the
actual code, stored procedures, and tests in this repository (not the design
docs alone).

> 🇻🇳 Danh sách tính năng kèm trạng thái triển khai. Trạng thái được xác định
> dựa trên **code / stored procedure / test thực tế** trong repo, không chỉ dựa
> trên tài liệu thiết kế.

**Last reviewed / Cập nhật:** 2026-06-10 (PRs #40–#45 — masked client list + account search + client-360 read surface, Swagger/OpenAPI docs, Go 1.26 + shared `otelx`/`pgxdb`/`kafkax` module, end-to-end W3C trace propagation REST→DB→relay→Kafka + Jaeger)

## Status legend / Chú thích trạng thái

| Symbol | Meaning | Ý nghĩa |
|:------:|---------|---------|
| ✅ | **Done** — implemented with code/SP, runnable | Đã làm — có code/SP, chạy được |
| 🟡 | **Partial** — DB/schema or one layer only; not end-to-end | Một phần — chỉ có schema/1 lớp, chưa trọn vẹn |
| ⬜ | **Not started** — design/spec only, no implementation | Chưa làm — chỉ có thiết kế, chưa code |

## Summary / Tổng quan

| Epic | ✅ | 🟡 | ⬜ |
|------|:--:|:--:|:--:|
| 1. Onboarding & Wallet Management | 12 | 2 | 1 |
| 2. Transactions — Posting | 7 | 0 | 0 |
| 3. Reversals & Refunds | 7 | 0 | 0 |
| 4. Balance & Statements | 7 | 0 | 0 |
| 5. Withdrawal Disbursement | 3 | 0 | 0 |
| 6. Accounting & GL Operations | 6 | 1 | 3 |
| 7. Eventing & Integration | 2 | 0 | 2 |
| 8. Audit, PII & Compliance | 3 | 1 | 1 |
| 9. Platform / Infra / Observability | 17 | 0 | 2 |
| 10. Quality — Testing & Load | 9 | 1 | 0 |
| **Total** | **73** | **5** | **9** |

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
> count limits (US-1.4) are implemented. The onboarding workflow has shipped:
> step 1 (`onboard_client` → `POST /v1/onboard`, US-1.1, incl. ORG path US-1.7),
> step 2 (`update_kyc` → `POST /v1/clients/:client_no/kyc`, US-1.2) and bank
> linking (`link_client_bank`, US-1.14) are wired with integration tests;
> centralized KYC with `extra_data` JSONB is live (US-1.15). Pending: related-doc
> attachment writer (US-1.13, schema slot only) and the tier-progression framing.
> Spec: [docs/specs/wallet_onboarding.md](docs/specs/wallet_onboarding.md).
>
> Merchant **hot-wallet lifecycle** is now complete end-to-end: group
> provisioning (US-1.10), activation (US-1.9), cold→hot deposit routing (US-1.11)
> and rescaling with rebalance (US-1.12) are all implemented (SP + Go + tests) —
> see [docs/specs/finance_transaction.md](docs/specs/finance_transaction.md) §3/§4.8.

| ID | User story | Status | Evidence / Notes |
|----|-----------|:------:|------------------|
| US-1.1 | As a new user, I register with basic identity (**no OTP**) and the platform creates my client record **and** a zero-balance wallet in one onboarding step | ✅ | **Step 1** done. SP `onboard_client` (`db/export/schema.sql`) chains `create_client` + `open_account` in one TX (RETURNS client_no + acct_no + tier); `POST /v1/onboard` → `h.Onboard` (`server.go`). Integration test `internal/repo/onboard_integration_test.go`. OTP register removed (2026-05-31). Spec §3, §7.1. |
| US-1.2 | As a user, I submit / update KYC info (eKYC) to raise my KYC tier | ✅ | **Step 2** done. SP `update_kyc` (tier / status / risk / eKYC provider+ref / face-match / liveness / `extra_data`) writes `FM_CLIENT_KYC`; `POST /v1/clients/:client_no/kyc` → `h.UpdateKYC` (`server.go`), repo `client.go`. Spec §5.1, §7.2. |
| US-1.3 | As ops, I open a wallet (ACCT_NO gen, zero balance) | ✅ | SP `open_account`; `POST /v1/accounts`. ACCT_NO = `9701`+10 (seq_acct_no), `ACTUAL_BAL=0`. (KYC-tier gate **not** enforced — onboarding out of scope; EOD makes the historical snapshot.) |
| US-1.4 | As the platform, I enforce wallet-count limits per customer | ✅ | In `open_account` (§4.3): CONSUMER 3/CCY, MERCHANT 10 (closed excluded) → `MAX_WALLET_PER_CLIENT_EXCEEDED` (409). |
| US-1.5 | As ops, I block / close / re-activate a wallet (close requires balance = 0) | ✅ | SP `update_account_status`; `PATCH /v1/accounts/:acct_no`. State machine A↔B→C; close→`ACCT_CLOSE_NONZERO_BAL` if bal≠0; mutate closed→`ACCT_NOT_ACTIVE`. |
| US-1.6 | As compliance, KYC downgrade & 12-month re-KYC | ⬜ | Spec §5.2, §13 (open item). |
| US-1.7 | As a corporate / organization customer, I onboard (CORP / MER, legal rep / UBO) | ✅ | ORG path wired in `onboard_client`: BR-09 `ORG_FIELDS_REQUIRED` (P0077) enforces `business_reg_no` + `legal_rep`; org-specific fields land in `FM_CLIENT_KYC.extra_data` (no separate ORG table — US-1.15). Test `TestOnboardClient_Org_Integration` (`onboard_integration_test.go`). Remaining polish: structured UBO[] capture is still a loose `extra_data` bag. Spec §1, §13. |
| US-1.8 | As ops, I create/update a **client master record** (identity only, no KYC/onboarding flow) | ✅ | SP `create_client`/`update_client` (SECURITY DEFINER); `POST /v1/clients` + `PATCH /v1/clients/:client_no`. FM_CLIENT (+FM_CLIENT_INDVL — to fold into `FM_CLIENT_KYC.extra_data` per US-1.15). Wallet opening/KYC still out of scope. |
| US-1.9 | As ops, I **activate a merchant hot wallet** (promote a cold group, 0 shards → N) | ✅ | SP `activate_hot_wallet(group_id, shard_count:=4)` (SECURITY DEFINER); `POST /v1/merchant-groups/:group_id/activate`. Creates N empty `SHARD` sub-accounts (index 0..N-1, balance 0 — no funds move, same invariant as `open_account`), flips `WLT_ACCT_GROUP.SHARD_COUNT`. Tiers 4/8/16 (4 = default); groups are now created **cold** (`SHARD_COUNT` default 0, `chk_shard_count IN (0,4,8,16)`). One-way from cold → `GROUP_ALREADY_ACTIVATED` (P0053); bad tier → `INVALID_SHARD_COUNT` (P0052); missing settlement → `SETTLEMENT_NOT_FOUND` (P0054). Tests: `wallet_activate_hotwallet_test.sql` (12/12) + `dto/group_test.go` + `repo/errors_test.go`. |
| US-1.10 | As ops, I **provision a merchant/agent group** (group row + settlement account in one TX) | ✅ | SP `provision_acct_group` (SECURITY DEFINER); `POST /v1/merchant-groups`. Creates the `WLT_ACCT_GROUP` row **cold** (`SHARD_COUNT=0`) + its `SETTLEMENT` account atomically — solves the chicken-and-egg via the deferred `fk_group_settlement` (group inserted first, settlement acct second). Validates client/acct-type/group-type, duplicate `group_id` → `GROUP_ALREADY_EXISTS` (P0056), bad type → `INVALID_GROUP_TYPE` (P0055). Go: domain/repo/usecase/handler/dto/route. Tests: `wallet_merchant_group_lifecycle_test.sql` TC1–TC5. Prereq for US-1.9 satisfied. |
| US-1.11 | As the platform, I **route merchant deposits** to settlement while cold (0 shards), to a shard once hot | ✅ | SP `post_merchant_deposit` (SECURITY DEFINER); `POST /v1/finance/merchant-deposit`. The settlement-vs-shard branch lives in the **caller** (the resolver `fn_resolve_shard_acct_no` stays shard-only and still raises P0050 for cold groups — `wallet_cold_merchant_test.sql` TC4 unchanged): a deposit credits the `SETTLEMENT` account while cold and a reference-hashed `SHARD` once hot. Idempotent by reference, balanced double-entry (DR payment-clearing `109.03.001` / CR merchant liability), new `MERCHDEP` tran-def. Tests: lifecycle TC6–TC11. |
| US-1.12 | As ops, I **rescale a hot wallet** (4→8→16) and rebalance existing shards | ✅ | SP `rescale_hot_wallet` (SECURITY DEFINER); `POST /v1/merchant-groups/:group_id/rescale`. Grows an already-hot group up a tier (upscale-only; `INVALID_SHARD_COUNT` P0052 if not larger, `GROUP_NOT_ACTIVATED` P0057 if cold). **Rebalance** = drain every existing shard back to settlement via `post_sweep_shard` URGENT (shards are transient buffers, settlement is source of truth — group total conserved, verified), then materialise the new shards at the high index range. Go: domain/repo/usecase/handler/dto/route. Tests: lifecycle TC12–TC17. |
| US-1.13 | As a user / ops, I attach & update **related documents** (CCCD images, business licence, UBO proofs) on a client's KYC | 🟡 | **Step 3** — schema slot only. `FM_CLIENT_KYC.related_docs` JSONB array + `chk_kyc_reldocs_arr` CHECK already exist (`db/export/schema.sql`), shape `[{doc_type, link, status, uploaded_at}]`. **No SP / endpoint writes it yet** — the attach/update path is not implemented. Spec §7.3, §11. |
| US-1.14 | As a user, I **link a bank account** during onboarding and receive a `linkId` token to reference it | 🟡 | **Step 4** — core linking done, onboarding integration pending. SP `link_client_bank` returns `link_id` + encrypts `acct_no` → `ACCT_NO_ENC`; `POST /v1/clients/:client_no/banks` (`h.LinkClientBank`) + `PUT /v1/clients/:client_no/banks/:link_id/default` (`h.SetDefaultClientBank`, SP `set_default_client_bank`). Pending: treating `link_id` as the client-facing opaque token and tying linkage to tier progression. Spec §3.2, §7.4. |
| US-1.15 | As the platform, I centralize **individual *and* organization** KYC into one `FM_CLIENT_KYC` table with a JSONB `extra_data` key-value bag | ✅ | Implemented. `FM_CLIENT_KYC.extra_data jsonb NOT NULL` + `chk_kyc_extra_obj` on the single KYC row; `FM_CLIENT_INDVL` **folded in and removed** (no per-type child table — only referenced in comments now); INDVL fields + the ORG branch (legal_rep, business_reg_no, …) land in `extra_data`, written by `onboard_client`/`update_kyc`. Rename to `FM_CLIENT_KYC` (US-9.16) also done. Spec §2, §5. |

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
| US-2.8 | As finance/ops, I charge a **standalone fee + VAT** against a wallet (annual / penalty / service fee) not tied to any money movement | ✅ | SP `post_fee_charge` (+ `post_fee_charge_reversal`), `SECURITY DEFINER`; `POST /v1/finance/fee-charge` (+ `/fee-charge/reverse`). **DR** wallet liability (gross) / **CR** fee revenue (net) / **CR** VAT payable 203.01 — VAT-inclusive `vat = round(gross×rate/(1+rate))`; 1 `FEECHG` TRAN_HIST leg (VAT is GL-only). Revenue GL resolved per acct_type via `WLT_GL_MAP('FEE_CR')` (consumer 401.01 / merchant 401.02). Guards: amount>0 (P0010), acct active (P0021/P0022), `calc_bal ≥ gross` (P0026); idempotent by `reference`; outbox `wallet.fee.charged.v1`; reversal refunds gross + flips revenue/VAT (`RVFEE`), idempotent. New tran-def `FEECHG`. Go: domain/repo/usecase/handler/dto/port/routes. Tests: `db/tests/wallet_fee_charge_test.sql` (13/13). |

> **Cross-cutting (✅):** posting is **idempotent** by `reference` (`ON CONFLICT` /
> duplicate guard in `wallet_sp.sql`), and honours holds via `WLT_RESTRAINTS`.

## Epic 3 — Reversals & Refunds / Đảo & hoàn giao dịch

| ID | User story | Status | Evidence / Notes |
|----|-----------|:------:|------------------|
| US-3.1 | As ops, I reverse an in-book transfer (refund incl. fee + VAT) | ✅ | SP `post_transfer_reversal`; `POST /v1/finance/reverse`; test `wallet_transfer_reversal_test.sql`. |
| US-3.2 | As ops, I reverse a top-up | ✅ | SP `post_topup_reversal`; `POST /v1/finance/topup/reverse`. |
| US-3.3 | As Treasury, I reverse a withdrawal (refund amount + fee + VAT) | ✅ | SP `post_withdraw_reversal`; `POST /v1/treasury/withdrawals/:ref/reverse`. |
| US-3.4 | As ops, I reverse a merchant withdrawal | ✅ | **Done (2026-06-05, PR #39).** SP `post_merchant_withdraw_reversal` now fully wired: domain types `MerchantWithdrawReversalInput/Result`, repo method via `withTx` calling `post_merchant_withdraw_reversal($1..$6)`, usecase + handler + DTO, route `POST /v1/finance/merchant-withdraw/reverse`. Idempotent on the original reference (returns `was_already_reversed=true` on retry). Credits principal + fee/VAT back to the settlement account; emits `wallet.merchant_withdraw.reversed.v1` on the outbox. Reversal window honoured (US-3.6). |
| US-3.5 | Reversals are idempotent and refund fee + VAT legs | ✅ | Reversal SPs write outbox + refund all legs. |
| US-3.6 | Reversal is rejected outside the allowed time window | ✅ | **Done (2026-06-05, PR #39).** New column `WLT_TRAN_DEF.reversal_window_hours INT NULL` (NULL = no restriction → fail-open). Seeded to **168h (7 days)** for every forward type carrying a `reversal_tran_type`. All 5 reversal SPs (`post_fee_charge_reversal`, `post_merchant_withdraw_reversal`, `post_topup_reversal`, `post_transfer_reversal`, `post_withdraw_reversal`) compare `clock_timestamp() - v_orig.PROCESSED_AT` (or `v_track.SUBMITTED_AT` for treasury) against the forward type's window **after the idempotency return** — out-of-window raises `REVERSAL_WINDOW_EXPIRED` (SQLSTATE `P0060`, HTTP **422**); idempotent retries of an already-reversed orig bypass the check by design. Go: `CodeReversalWindowExpired` + ISO 20022 metadata (E6105, reason AG09, RJCT) + 422 mapping. Tests `db/tests/wallet_reversal_window_test.sql` 6/6 PASS (in-window OK, out-of-window 422, idempotent retry bypass, NULL fail-open, transfer parity). |
| US-3.7 | VAT reversal across a closed period is handled correctly | ✅ | Period locking (US-6.1) makes a closed accounting day immutable, so the closed VAT period (e.g. May) cannot be mutated; a reversal posts `POST_DATE = CURRENT_DATE` into the open period (June) per spec §6.8. Guaranteed by the write-freeze (`fn_freeze_closed_period`, attached to `WLT_GL_BATCH` via `trg_freeze_batch` — keys off `ACCOUNTING_DATE`), proved in `db/tests/wallet_eod_period_lock_test.sql`. |

## Epic 4 — Balance & Statements / Số dư & sao kê

| ID | User story | Status | Evidence / Notes |
|----|-----------|:------:|------------------|
| US-4.1 | As a customer, I view my realtime balance | ✅ | SP `get_balance`; `GET /v1/accounts/:acct_no/balance`. |
| US-4.2 | As a customer, I view a historical balance (`as_of_date`) | ✅ | SP `get_balance_asof`; `?as_of_date=`. |
| US-4.3 | As ops, I view the full balance breakdown for a wallet | ✅ | SP `get_balance_ops`; `GET /v1/ops/accounts/:acct_no/balance`. |
| US-4.4 | As ops, I look up balances in batch | ✅ | SP `get_balance_batch`; `POST /v1/ops/accounts/balance/batch`. |
| US-4.5 | As a customer, I retrieve a transaction history / account statement | ✅ | `GET /v1/finance/transactions?acct_no=&from=&to=` (optional `post_date` range, 200 items/page, keyset `next_cursor`→`?before_seq=`) + `GET /v1/finance/transactions/:tran_key` (all legs) + `GET /v1/accounts/:acct_no` (profile). Direct SELECT on WLT_*. |
| US-4.6 | As ops / a service, I **list and look up clients and their wallets**, with PII masked by default and an unmasked twin for privileged ops | ✅ | **Done (PR #40 2026-06-06, PR #42 2026-06-08).** Masked customer/ops path over the security-barrier views (`wallet_app`, read-only — no TX, no audit GUC): `GET /v1/clients` (keyset list by `client_no` ASC, `?status=&client_type=&limit=&after=`, `next_cursor`), `GET /v1/clients/:client_no` (masked profile), `GET /v1/clients/:client_no/accounts` (all wallets owned). Unmasked privileged twins gated by `wallet.ops.read` RBAC + `wallet_pii_ro` (raw + decrypted phone/email): `GET /v1/ops/clients`, `/v1/ops/clients/:client_no`. Repo reads `v_client_masked`; clamps limits (`DefaultClientPageSize`/`MaxClientPageSize`). Go: domain `ClientListQuery`/`ClientView`/`ClientFullView`, port/usecase `ListClients`/`ListClientsFull`/`ListAccountsByClient`, repo `client.go`, dto/handler. |
| US-4.7 | As ops, I **search accounts** by acct_no / client_no (and client name on the privileged path) and view a **client-360 aggregate** | ✅ | **Done (PR #42 2026-06-08).** **Search:** `GET /v1/accounts/search?q=&limit=` (q≥6, returns masked client name) + unmasked twin `GET /v1/ops/search` (`wallet.ops.read`, also matches & returns the RAW client name). Backed by `acct_desc` now defaulting to the owning client's full name in `open_account` (denormalised for display/search). **Client 360:** `GET /v1/clients/:client_no/360` (masked) + `GET /v1/ops/clients/:client_no/360` (unmasked) aggregate profile + wallets + linked banks + restraints in one call — banks via the new `v_client_banks_masked` view (decrypt-then-remask `****`+last4, cf. US-8.4). Go: domain `Client360`/`ClientBankView`/`AccountSearchItem`, port/usecase `SearchAccounts`/`SearchAccountsFull`/`GetClient360`, repo `client360.go`, dto `client360.go`. |

## Epic 5 — Withdrawal Disbursement / Theo dõi giải ngân rút tiền

| ID | User story | Status | Evidence / Notes |
|----|-----------|:------:|------------------|
| US-5.1 | Track withdrawal lifecycle SUBMITTED→ACKED→DISBURSING→COMPLETED/FAILED→REVERSED | ✅ | `WLT_WITHDRAW_TRACK`; SPs `mark_withdraw_acked/disbursing/completed`. |
| US-5.2 | As Treasury, I push disbursement state transitions | ✅ | `POST /v1/treasury/withdrawals/:ref/{acked,disbursing,completed}`. |
| US-5.3 | Auto-reverse withdrawals stuck > 24h (SLA-timeout janitor) | ✅ | **Done (2026-06-10).** SP `reverse_stuck_withdrawals(p_limit)` (SECURITY DEFINER) sweeps `WLT_WITHDRAW_TRACK` rows still in `SUBMITTED`/`ACKED`/`DISBURSING` past `FINAL_DEADLINE` (default `SUBMITTED_AT + 24h`), taken `FOR UPDATE SKIP LOCKED` (multi-runner safe), and delegates each to `post_withdraw_reversal` (`fail_code=SLA_TIMEOUT`, `initiator=JANITOR`) so ledger/GL/outbox/audit semantics match a Treasury reverse (US-3.3). Each reversal runs in its own `BEGIN/EXCEPTION` subtx → one bad row can't abort the batch; returns `(reversed, failed, expired)` where `expired` counts rows already past WDRAW's 168h reversal window (US-3.6, P0060 → needs manual handling, RAISE WARNING). Index `idx_wd_final_overdue` extended to include `SUBMITTED` so the sweep is index-driven. Driver: in-process Go scheduler `internal/janitor` (interval ticker, opt-in `WD_JANITOR_ENABLED` + `WD_JANITOR_INTERVAL`/`BATCH_SIZE`/`RUN_TIMEOUT`), runs on the ordinary app pool (single bounded statement, PgBouncer-safe — no dedicated DSN like EOD), wired in `cmd/server/main.go` (one replica; SKIP LOCKED makes extras harmless). Tests: `db/tests/wallet_withdraw_sla_janitor_test.sql` 9/9 (fresh-not-candidate, SUBMITTED+ACKED reversed, balance credited back, idempotent replay, batch-limit oldest-first, 168h-window expired) + Go `internal/janitor/withdraw_test.go`. |

## Epic 6 — Accounting & GL Operations / Kế toán & vận hành sổ cái

> Subsystem §9b. The **EOD batch** (write-DB, posting-safe) is implemented in
> `db/export/schema.sql` (the single source of truth — there is **no**
> `db/procedures/` directory) as two orchestrators: `run_eod` (customer close:
> T1 snapshot → T2 prev-day roll → T5 restraint expiry) and `run_gl_close` (GL
> close: T3 gl-feed → T6 trial balance → T7 close period). Covers US-6.1 (period
> locking) + US-6.3 + US-6.6–6.9, plus the GL-feed post of US-6.2. The full
> suspense/clearing GL framework, e-invoice and manual-JE workflows (US-6.2
> remainder / 6.4 / 6.5) remain HLD design only.

| ID | User story | Status | Evidence / Notes |
|----|-----------|:------:|------------------|
| US-6.1 | EOD close & period locking | ✅ | `db/export/schema.sql`. The GL-close chain is `run_gl_close` (T3 gl-feed → T6 trial balance → **T7 `eod_close_period`**) — *not* `run_eod` (which is the customer chain T1→T2→T5). **Period locking** done: `eod_close_period(D)` seals the accounting day in `WLT_PERIOD` (runs last, only after its tasks are DONE), advancing the high-water mark; the `fn_freeze_closed_period` trigger `trg_freeze_batch` on **`WLT_GL_BATCH`** (keys off `ACCOUNTING_DATE`) makes a closed day **immutable** (no INSERT/UPDATE/DELETE, SQLSTATE P0092 → `PERIOD_CLOSED`/409). Verified + `db/tests/wallet_eod_period_lock_test.sql`. Unblocks US-3.7. |
| US-6.2 | Suspense / clearing GL framework | 🟡 | **GL-feed post** built: `eod_gl_feed_post(D)` (T3) finalises the day's GL journal `WLT_GL_BATCH` `'P'`→`'S'`, chunked + restart-safe. Full suspense/clearing GL framework (HLD §9b) still design only. |
| US-6.3 | Daily trial-balance materialization + signed proof | ✅ | SP `eod_trial_balance` (`db/export/schema.sql`, T6 in `run_gl_close`). Per-`(gl_code,ccy)` from `WLT_GL_BATCH` → `WLT_TRIAL_BALANCE` (opening carry-forward + period DR/CR + closing); proves ΣDR=ΣCR ∧ Σclosing=0; seals each day in `WLT_TRIAL_BALANCE_PROOF` via a `sha256` **hash chain** (`chain=H(totals‖content‖prev)`). `eod_verify_chain()` re-derives & detects tampering (verified: editing a sealed line flips `chain_ok`→false). |
| US-6.4 | E-invoice integration (Decree 123/2020, Circular 78/2021) | ⬜ | HLD §9b. Design only. |
| US-6.5 | Maker-checker manual journal entry workflow | ⬜ | HLD §9b. Design only. |
| US-6.6 | EOD daily balance snapshot → `WLT_ACCT_BAL[D]` | ✅ | SP `eod_snapshot` (`db/export/schema.sql`, T1 in `run_eod`). Sparse (accounts that moved on D); close = last `WLT_TRAN_HIST` leg (ledger-authoritative, 24/7-correct); **finalises** the row posting maintains intraday (`ON CONFLICT DO UPDATE`), incl. `calc_bal` = close − final restraint overlay. Chunked short-TX (`COMMIT`/chunk → no xmin pinning), restart-safe. |
| US-6.7 | EOD prev-day balance roll | ✅ | SP `eod_prev_day_roll`. `WLT_ACCT.prev_day_actual_bal := close(D)` from the snapshot; sparse, skips no-ops (`IS DISTINCT FROM`), HOT update (non-indexed col, fillfactor 80), chunk 10k; depends on US-6.6. |
| US-6.8 | EOD restraint auto-expiry | ✅ | SP `eod_expire_restraints`. Restraints past `END_DATE` (`A`→`E`, `removed_by='EOD'`) + recompute `WLT_ACCT.{total_restrained_amt,cr_blocked,restraint_present}` (mirrors `release_restraint`); one account / TX. cf. US-8.2. |
| US-6.9 | EOD run history (audit log) + restart / failure handling | ✅ | Append-only `WLT_EOD_AUDIT_LOG` (status, started/finished, duration, rows — one row per run, via `eod_log`) + `WLT_EOD_RUN` resume cursor (`last_key`); `eod_mark_failed` records FAILED and keeps the cursor for retry. Batch/scheduler-driven (pg_cron / direct primary — no HTTP route by design). |
| US-6.10 | As accounting/ops, I tag the GL config with the owning **branch / legal-entity** code so the ledger records which booking entity it belongs to | ⬜ | **Label-only**, design. Add `branch_code varchar(20)` to **`WLT_GL_CONFIG`** (the singleton config row) as descriptive entity identity — it does **not** enter `fn_accounting_date()` nor the period-close / write-freeze logic. **Deliberately NOT on `WLT_PERIOD`**: that table is one row per `biz_date`, so a non-key `branch_code` could only hold one value per day (a redundant constant); representing multiple branches per day would force `branch_code` into the PK `(branch_code, biz_date)` and propagate the dimension through `WLT_GL_BATCH` → account/posting → trial balance → `fn_freeze_closed_period` — i.e. full multi-branch GL, a separate epic, not a label. No FK target yet (no branch master table) — free-text label (optionally a CHECK). Confirms the **keep-separate** decision: entity identity is global/singleton (`WLT_GL_CONFIG`), period status is per-day operational (`WLT_PERIOD`). Touch points: `db/export/schema.sql` (`ADD COLUMN`), `db/export/seed.sql` (`COPY` for the singleton row). No Go change if the app does not read the label. |

## Epic 7 — Eventing & Integration / Sự kiện & tích hợp

| ID | User story | Status | Evidence / Notes |
|----|-----------|:------:|------------------|
| US-7.1 | Every posting writes a Kafka event row atomically (transactional outbox) | ✅ | `WLT_OUTBOX`; `INSERT INTO WLT_OUTBOX` inside every posting SP. |
| US-7.2 | Relay outbox → Kafka (Debezium CDC primary, Go polling worker fallback) | ✅ | **Dual-mode implemented (2026-06-05).** `services/outbox-relay`: switchable via `RELAY_MODE` env: (1) **polling** (default) — 4 Go workers poll `WLT_OUTBOX` with `FOR UPDATE SKIP LOCKED`, publish via Sarama SyncProducer (idempotent, acks=all), mark SENT with kafka_partition/offset; (2) **cdc** — Debezium CDC via Kafka Connect EventRouter, relay manages connector lifecycle (auto-register/pause/resume) + CDC consumer marks rows SENT. `docker-compose.cdc.yml` adds Kafka Connect (debezium/connect:2.6). Config: `debezium/config.json` (EventRouter transform routes each row to its `topic` column). Both modes proven at-least-once; `SKIP LOCKED` guarantees no duplicate publish across workers. **Hardened (PRs #44/#45 2026-06-09/10):** the relay now **continues the distributed trace across the async outbox→Kafka hop** — extracts the W3C `traceparent` from `WLT_OUTBOX.HEADERS` (stamped by the posting SP, see US-9.5) and emits a child Kafka PRODUCER span, so a request is followable REST → DB SP → relay → Kafka → consumer (`internal/telemetry` OTLP exporter; `OTEL_ENABLED=false` → no-op tracer). Connection/producer wiring extracted into the shared `pgxdb`/`kafkax`/`otelx` module. Graceful shutdown is now **bounded by a timeout with force-quit** (PR #45) so a worker stuck mid-publish or an unreachable broker can no longer hang termination. |
| US-7.3 | Downstream consumers react to `withdraw.posted` etc. | ⬜ | Out of scope here (Treasury Service). |
| US-7.4 | As a downstream consumer, every outbox event carries a **consistent transaction-metadata envelope** (reference, tran_type, channel, actor, occurred_at, client/counterparty, schema version) so events are self-describing and routable **without joining back to the ledger** | ⬜ | **Enrichment of US-7.1**, not greenfield: the `INSERT INTO WLT_OUTBOX` in every posting/reversal SP (`db/export/schema.sql`) already emits *some* business fields (`tran_internal_id`, `amount`, `fee_gross`/`vat_amount`, `ext_payout_ref`, `ccy`, `group_id`), but the shape **varies per SP** and key meta is missing: most payloads omit the client **`reference`** (idempotency/external ref) and **`tran_type`**; `HEADERS` carries only `traceparent`; the `WLT_OUTBOX.CHANNEL` column is left **NULL** (posting INSERTs don't pass it) and `CREATED_BY` falls back to `SYSTEM` instead of `audit.actor`; `EVENT_VERSION` is a flat `'v1'` with no documented schema. Scope: define one canonical event envelope (meta keys + headers), populate it uniformly across all emitters (incl. the `CHANNEL`/`CREATED_BY`/`occurred_at` columns from the per-TX audit GUCs that `withTx` already sets), and pin a versioned JSON schema. Prerequisite for clean relay (US-7.2) and consumer routing/replay (US-7.3). Design-only. |

## Epic 8 — Audit, PII & Compliance / Audit, PII & tuân thủ

| ID | User story | Status | Evidence / Notes |
|----|-----------|:------:|------------------|
| US-8.1 | Capture client changes (OLD/NEW diff, maker-checker) in an audit log | ✅ | `FM_CLIENT_AUDIT_LOG`; trigger fns `fn_audit_client_change`, `fn_set_audit_columns`. Coverage today: `FM_CLIENT_BANKS` (`trg_audit_fm_client_bk`) + `FM_CLIENT_KYC` (`trg_audit_fm_kyc`) only — UPDATE diffs on the four **core** client tables are tracked in US-8.5. |
| US-8.2 | Apply holds/restraints (add/release) that block debits/credits | ✅ | SP `add_restraint`/`release_restraint`; `POST /v1/finance/restraints` (+ `/:id/release`); rolls up `TOTAL_RESTRAINED_AMT`/`CR_BLOCKED`, enforced in posting. Maker-checker/idempotency = gateway (deferred). |
| US-8.3 | Record reconciliation breaks | ⬜ | No `WLT_RECON_BREAK` table or live recon engine in the current schema (`db/export/schema.sql`) — verified absent. Only artifact is the read-only assertion script `db/tests/wallet_reconciliation_check.sql`, which *detects* breaks but does not record them. |
| US-8.5 | Audit **UPDATEs** to the core client-master tables as OLD→NEW diff rows | ✅ | **Done (2026-06-10).** Closes the gap behind US-8.1 and satisfies the "Client-master change auditing" HARD RULE in `CLAUDE.md`. Added `fn_audit_client_change` as an **`AFTER UPDATE`** trigger on the two surviving core tables: `trg_audit_fm_client` on **`FM_CLIENT`** and `trg_audit_fm_client_ct` on **`FM_CLIENT_CONTACT`** — so `update_client` (which mutates `FM_CLIENT`) now writes an attributed OLD→NEW diff into `FM_CLIENT_AUDIT_LOG`. **UPDATE only, not INSERT** (a create has no before→after diff, already attributed by `created_by`/`created_at`) and **not DELETE** (core client rows are never hard-deleted; soft-delete is an `UPDATE status='C'`, captured). **Scope note:** the originally-listed `FM_CLIENT_INDVL` and `FM_CLIENT_IDENTIFIERS` no longer exist — US-1.15 folded them into `FM_CLIENT_KYC.extra_data` (which already carries `trg_audit_fm_kyc`), so the two remaining `client_no`-bearing core tables are the full scope. The shared `fn_audit_client_change` was left unchanged (it already diffs generically by `TG_TABLE_NAME`/`CLIENT_NO`); note `updated_at` is stamped by the BEFORE `trg_audit_cols` so it always appears in `changed_fields` alongside the real business change. Test: `db/tests/wallet_client_audit_test.sql` 5/5 (INSERT silent, UPDATE writes one attributed diff, precise changed-fields, FM_CLIENT_CONTACT parity). |
| US-8.4 | PII protection: classification, encryption, masking, retention, access log | 🟡 | **Encryption + masking done**: `FM_CLIENT_KYC.PHONE_NO_ENC`/`EMAIL_ENC` via `pgcrypto` `pgp_sym_encrypt` (DEK from `app.pii_dek`), `PHONE_NO_HASH` for unique lookup, + masked read views (`v_kyc_masked` etc.). Remaining (HLD §8.3): data classification, retention policy, and the `WLT_PII_ACCESS_LOG` access trail. |

## Epic 9 — Platform / Infra / Observability

| ID | User story | Status | Evidence / Notes |
|----|-----------|:------:|------------------|
| US-9.1 | Clean-architecture Go service (domain/usecase/repo/http) | ✅ | `services/wallet-service/internal/`. Now **Go 1.26** (toolchain bump, PR #43 2026-06-08); cross-service connection/telemetry/Kafka wiring extracted into a shared module `services/shared` (`otelx`/`pgxdb`/`kafkax`) imported by both wallet-service and outbox-relay (PRs #44/#45). |
| US-9.2 | Env-driven configuration | ✅ | `internal/config/config.go`; `.env.example`. |
| US-9.3 | Graceful shutdown with context deadline | ✅ | `internal/http/server.go` `Start()`. |
| US-9.4 | Request-ID + audit-context middleware | ✅ | `internal/http/middleware/`. |
| US-9.5 | OpenTelemetry tracing | ✅ | `internal/telemetry/otel.go`, `otelgin`. **Extended end-to-end (PRs #44/#45 2026-06-09/10):** every wallet handler is now explicitly span-wrapped; `otelpgx` traces each DB Query/Exec (via shared `pgxdb`); and the trace is **carried into the async pipeline** — middleware serialises the active span into a full W3C `traceparent`, `setAuditGUCs` stamps it into the `app.trace_id` GUC, and the posting SPs copy it into `WLT_OUTBOX.HEADERS->>'traceparent'` so the relay can resume it (US-7.2). No SP/schema change (bare 32-hex trace-id still used for responses/logs/audit). Shared span helpers live in the new `services/shared/otelx`. **Jaeger** all-in-one backend added under a `tracing` docker-compose profile so the propagated trace is collectable/viewable locally. |
| US-9.6 | Connection pooling via PgBouncer (transaction mode) | ✅ | `deploy/docker/pgbouncer/`; pgxpool. |
| US-9.7 | Dockerized local dev stack | ✅ | `docker-compose.yml` (PG17 + PgBouncer + Adminer). |
| US-9.8 | Liveness health check | ✅ | `GET /healthz`. |
| US-9.9 | Input validators (money, acct_no) + timeout layering | ✅ | `server.go` custom validators; 3s/2.5s/1.5s layering. |
| US-9.10 | AuthN / AuthZ + rate limiting | ✅ | **Done (2026-06-05, PR #39)** — defense-in-depth alongside the gateway. Bearer-token validation + per-route RBAC inside wallet-service, opt-in via `JWT_ENABLED` (default off → keeps existing `X-Caller-Subject` / `X-Channel` header path). Supports **HS256** (`JWT_HMAC_SECRET`) and **RS256** (`JWT_RSA_PUBLIC_KEY` inline PEM); validates `iss` / `aud` / `exp` with configurable `JWT_CLOCK_SKEW`. JWT middleware extracts `sub`, `roles`, and `channel` claims into the gin context; `resolveActor` / `resolveChannel` now prefer JWT-derived values over headers so the per-TX audit GUCs (`audit.actor`, `audit.channel`) are attributed to the verified token rather than a forwardable header. `RequireAnyRole(...)` (`middleware/rbac.go`) returns 403 on missing role; passthrough when JWT disabled. **Role catalog**: `wallet.finance.reverse` (4 reversal endpoints), `wallet.ops.read` (`/v1/ops/*`), `wallet.treasury` (`/v1/treasury/*`). Misconfig (HS256 without secret, unknown algorithm, bad PEM) fails fast at startup. Secret bound with `env:"JWT_HMAC_SECRET,unset"` so it's wiped from the process env after load. 18 unit tests in `middleware/jwt_test.go` + `rbac_test.go` cover valid/expired/missing/malformed/wrong-iss/wrong-aud/bad-sig/missing-sub + channel claim propagation + RBAC happy/sad/passthrough/empty-roles. Rate-limiting still a gateway concern (HLD §3). |
| US-9.11 | CI/CD pipeline | ✅ | **Implemented (2026-06-05).** `.github/workflows/ci.yml` (Go lint/vet/test + SQL test suites on PG17 service container + Terraform validate), `.github/workflows/cd-k8s.yml` (build multi-arch images → GHCR, deploy via kustomize to staging on push-to-master, production on tag `v*` with manual approval). GitHub OIDC → AWS (keyless). Supports both EKS and on-premise (self-hosted runner). |
| US-9.12 | Metrics endpoint (Prometheus) | ✅ | **Done (2026-06-10).** `GET /metrics` now served via the OTel metrics SDK + Prometheus exporter (`telemetry.SetupMetrics` installs a `MeterProvider` backed by `otel/exporters/prometheus`; `promhttp.Handler()` mounted in `server.go`). Gated by `METRICS_ENABLED` (default on, independent of `OTEL_ENABLED` — no collector needed). `middleware.Metrics()` records **`wallet_requests_total`** + **`wallet_request_duration_seconds`** (labels `method`/`route`/`status`; `route` = matched gin template, not raw path → no param cardinality blow-up); the central `renderError` emits **`wallet_errors_total{code}`** keyed on the canonical domain code (`BATCH_UNBALANCED`/`TIMEOUT`/`VERSION_CONFLICT`/…). These are exactly the series the **already-deployed** Prometheus alert rules (`deploy/k8s/base/observability/prometheus.yaml`) key on, and the wallet-service Deployment already carries `prometheus.io/scrape` + `prometheus.io/path: /metrics` — so scraping is live end-to-end. Test `internal/http/middleware/metrics_test.go` asserts the scraped names, the matched-template route label, the no-leak cardinality guard, and the error series. **Observability stack** (deployed 2026-06-05): `deploy/k8s/base/observability/` — OTel Collector + Prometheus + Tempo + Loki + Grafana (datasources + wallet-overview dashboard + alert rules). |
| US-9.13 | Read-replica routing for lag-tolerant reads | ✅ | `DB_READ_DSN` → separate read pool (`cmd/server`, `repo.readPool`). Only `GetAccount` (profile) + `ListTransactions` (statement) read it; unset → primary (strong consistency). Balance-realtime / tx-detail / ops stay on primary (read-your-writes). Both paths verified live. |
| US-9.14 | Rename `tran_internal_key` → `tran_internal_id` for clarity (it groups the legs of **every** transaction type, not just transfers) | ✅ | Done. `tran`="transfer" was a misnomer — the column is the per-transaction grouping key for topup/transfer/withdraw/merchant/reversal. Renamed the **DB column** on `WLT_TRAN_HIST` (+ all partitions), `WLT_WITHDRAW_TRACK`, `WLT_SWEEP_LOG`; all posting/reversal SP bodies + `RETURNS` + idempotency-cache & outbox jsonb keys (`db/export/schema.sql`); SQL test suites; Go identifiers (`TranInternalKey`→`TranInternalID`) + repo SQL strings; DLD/HLD/spec docs. **API kept stable** — HTTP JSON field `tran_internal_key` / `reversal_tran_key` (Go DTO json tags) + route `:tran_key` unchanged, so no client breaks (events/internals now use `tran_internal_id`). Verified: fresh `docker compose up` (0 init errors, 202 cols renamed), all SQL suites pass, `go build` + `go test -race` green. Siblings `TFR_SEQ_NO`/`seq_tran` left as-is (out of scope). |
| US-9.15 | Rename cryptic `TRAN_TYPE` codes for clarity — e.g. `WDRAW`→`WITHDRAW`, `TRFOUT`→`TRANSF_OUT` — the column is `varchar(10)` but codes use 5–6-char abbreviations that waste the headroom | ⬜ | Deferred (logged from a load-test session, 2026-05-31). `WLT_TRAN_DEF.TRAN_TYPE` is the PK (`varchar(10)`); referenced by `WLT_TRAN_HIST.TRAN_TYPE` (`varchar(10)`, NOT NULL — **no DB FK**, link is logical) and self-referenced via `reversal_tran_type` / `fee_tran_type`. For consistency, rename the whole family, not just the two named: `TRFOUT`/`TRFIN`/`TRFOUTF`, `WDRAW`/`RVWD`/`FEEWD`, `MERCHWD`/`FEEMW`/`RVMWD`, `TOPUP`/`RVTPUP`, `FEETRF`/`RVTRF`/`RVFEE`. **Blast radius** (mirror US-9.14): seed defs (`db/export/seed.sql` `wlt_tran_def`), SP `DEFAULT` args + bodies (`db/export/schema.sql`, e.g. `post_transfer(... p_tran_type DEFAULT 'TRFOUT')`), Go (`internal/domain/types.go`, `http/dto/dto.go`, `repo/postgres.go`), load tests (`deploy/loadtest/k6_wallet.js` + `transfer.sql`/`withdraw*.sql`/`reversal.sql`/`setup.sql`/`merchant_topup.sql`), `postman/`, SQL suites (`db/tests/*`), docs (`docs/specs/finance_transaction.md`, DLD/HLD, COA spec). **Open decisions (defer to roadmap):** (1) **final names** — `varchar(10)` fits `WITHDRAW` (8) but **not** `TRANSFEROUT` (11) → choose `TRANSF_OUT`/`XFER_OUT`/`TRF_OUT`; (2) **history migration** — existing `WLT_TRAN_HIST` rows already carry old codes, so either `UPDATE` them in place or keep old codes read-valid (cf. US-9.14's API-stable approach); (3) widen the column if 10 chars proves too tight. |
| US-9.16 | Re-prefix `WLT_CLIENT_KYC` → `FM_CLIENT_KYC` (it is client master-data, not wallet ledger) | ✅ | **Done (2026-06-02)** — schema/code/DB already on `FM_CLIENT_KYC` (table + PK/indexes/constraints + masked view `v_kyc_masked` + Go `repo/client.go` + `trg_audit_fm_kyc`); this change synced the docs (DLD/HLD/onboarding/CLAUDE). KYC belongs to the **client-master (`FM_`) domain** — siblings already use it (`FM_CLIENT`, `FM_CLIENT_INDVL`, `FM_CLIENT_CONTACT`, `FM_CLIENT_IDENTIFIERS`, `FM_CLIENT_BANKS`); only `WLT_CLIENT_KYC` + `WLT_CLIENT_AUDIT_LOG` (US-9.17) still wear the wrong `WLT_` (ledger) prefix. Plain `ALTER TABLE … RENAME` + rename PK/indexes/constraints (`wlt_client_kyc_*`→`fm_client_kyc_*`) and any FK to `FM_CLIENT`. **Blast radius** (~97 refs): `db/export/schema.sql` (DDL, pgcrypto cols `PHONE_NO_ENC`/`EMAIL_ENC`/`PHONE_NO_HASH` + masked view `v_kyc_masked` — cf. US-8.4), Go `internal/repo/client.go`, seeds (`wallet_seed.sql`, `wallet_testdata_10.sql`), load test (`deploy/loadtest/setup.sql`), `db/maintenance/truncate_operational_data.sql`, docs (DLD/HLD/onboarding), `CHANGELOG.md`. **API impact:** none (no HTTP field/route is named after the table). Pairs with US-9.17 — do both in one migration. **US-1.15** layers the JSONB `extra_data` centralization (folding `FM_CLIENT_INDVL` + an ORG branch) onto this rename — sequence them together. |
| US-9.17 | Re-prefix `WLT_CLIENT_AUDIT_LOG` → `FM_CLIENT_AUDIT_LOG` (audit trail of client-master changes) | ✅ | **Done (2026-06-02)** — schema/code/DB already on `FM_CLIENT_AUDIT_LOG` (partitioned parent + monthly child partitions + `fn_ensure_wallet_partitions` + PK/indexes + `fn_audit_client_change`/`fn_set_audit_columns`); this change synced the docs. Same rationale as US-9.16 — it records OLD/NEW diffs of `FM_CLIENT` (US-8.1), so it belongs to the `FM_` client-master family, not the `WLT_` ledger. **Partitioned table** → rename the parent **and** its monthly child partitions + the creation logic in `db/export/partitions.sql` (`fn_ensure_wallet_partitions`) + PK/indexes. **Blast radius** (~86 refs): `db/export/schema.sql` (DDL + the trigger fns that write it, `fn_audit_client_change`/`fn_set_audit_columns`), `db/export/partitions.sql`, `CLAUDE.md` ("Key tables"), `db/maintenance/truncate_operational_data.sql`, docs (DLD ~32 refs, HLD). **API impact:** none. Pairs with US-9.16. |
| US-9.19 | Interactive **Swagger / OpenAPI docs** with an embedded business error-code catalogue | ✅ | **Done (PR #41 2026-06-06).** `swaggo/swag` + `gin-swagger` serve `/swagger/index.html`, gated by `SWAGGER_ENABLED` (default on; off in prod). All **38 operations across 34 paths** annotated (finance, clients, accounts, merchant-groups, ops, treasury, health) + general API info & 7 tags in `cmd/server/main.go`. A **55-row error-code catalogue** (`errorCode` \| `internal_code` \| HTTP \| ISO 20022 \| description) sourced from `domain/iso20022.go` + `repo/errors.go` is embedded in the API description; `dto.ProblemDetails` (enriched with field examples) is the 4xx/5xx schema on every endpoint. Generated spec committed under `services/wallet-service/docs/` (`docs.go`, `swagger.json`, `swagger.yaml`); `make swagger` regenerates. |
| US-9.18 | Uniform HTTP response envelope — same `{ errorCode, errorMessage }` shape for success + error so the client branches on `errorCode` first | ✅ | **Done (2026-06-05, PR #39).** **Success** (every 2xx except `/healthz` probe): `{ "errorCode": "00000", "errorMessage": "Success!", "data": {…}, "trace_id", "timestamp" }` — `dto.SuccessEnvelope` + `dto.Ok()` + `handler.writeOK` wrapper; `00000` mirrors SQLSTATE `successful_completion`. **Error**: `errorCode = pgErr.Code` (real SQLSTATE — P0060/40001/23505/…) for PG-raised, `MetaFor(code).InternalCode` (E#### synthetic) for Go-side (JWT/RBAC/validation/timeout). `errorMessage = pgErr.Message` verbatim or `"CODE: detail"` synthesized. **Whitelist gate** (`domain.IsClientSafeCode`, §3.3): only codes registered in `codeMeta` or matching `*_NOT_FOUND` / `*_NOT_ACTIVE` / `*_RESTRAINT_ACTIVE` families surface; everything else (incl. raw pg failures, panics, `CodeInternal`) collapses to `{ "errorCode": "999999", "errorMessage": "Internal Error" }` + HTTP 500 with every internal field stripped. **Body slimmed**: `type`, `title`, `instance`, `status`, `internal_code`, `retry` removed (status is the HTTP header; the rest were redundant). **New codes added to whitelist**: `REVERSAL_WINDOW_EXPIRED` (P0060, 422 — US-3.6), `GROUP_RESTRAINED` (P0025, 423 — merchant-withdraw guard). Tests: `dto/dto_test.go` covers success-envelope shape + `omitempty` for nil data; `handler/errors_test.go` covers error shape, 999999 fallback, and **negative assertions** so the body never re-grows the stripped fields. **Logs** carry both `code` (canonical name, for grep/alerts) and `sql_state` (matches client `errorCode` for trace correlation) via `usecase.WalletService.logFailure`. |

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

### Recently shipped (2026-06-06 → 06-10, PRs #40–#45)

| Story | Delivered |
|-------|-----------|
| US-4.6 | Masked client list/profile/wallets (`GET /v1/clients`, `/:client_no`, `/:client_no/accounts`) + unmasked ops twins (`/v1/ops/clients*`, `wallet.ops.read`) — PR #40/#42 |
| US-4.7 | Account search (`/v1/accounts/search` masked + `/v1/ops/search` unmasked) backed by `acct_desc`=client name, and client-360 aggregate (`/v1/clients/:client_no/360` + ops twin) via new `v_client_banks_masked` view — PR #42 |
| US-9.19 | Swagger/OpenAPI docs at `/swagger` (38 ops, 34 paths, 7 tags) + embedded 55-row error-code catalogue, `SWAGGER_ENABLED` gate — PR #41 |
| US-9.5 / US-7.2 | End-to-end W3C trace propagation REST → DB SP → outbox → relay → Kafka; all handlers span-wrapped, `otelpgx` DB spans, Jaeger backend; relay shutdown bounded by timeout — PRs #44/#45 |
| US-9.1 | Go 1.26 toolchain bump + shared `services/shared` module (`otelx`/`pgxdb`/`kafkax`) — PRs #43/#44/#45 |
| — | Consistency polish (PR #42): posting status strings unified `Success`→`SUCCESS`; `statusFor` shared across topup/transfer/withdraw handlers. |

### Shipped 2026-06-05 (PR #39)

| Story | Delivered |
|-------|-----------|
| US-9.10 | JWT validation + per-route RBAC (HS256/RS256, opt-in, role catalog, channel claim, 18 unit tests) |
| US-3.4 | Wired `POST /v1/finance/merchant-withdraw/reverse` end-to-end (domain → repo → usecase → handler → route) |
| US-3.6 | `reversal_window_hours` column on WLT_TRAN_DEF + check in all 5 reversal SPs + `REVERSAL_WINDOW_EXPIRED` (P0060/422); 6/6 SQL tests pass |
| US-9.18 | Uniform response envelope: success `{ errorCode: "00000", errorMessage: "Success!", data, trace_id, timestamp }`; error `errorCode = SQLSTATE` + raw message, with whitelist fallback to `999999 / Internal Error`. Body slimmed (type/title/instance/status/internal_code/retry dropped). Added `GROUP_RESTRAINED` to whitelist so merchant-withdraw restraint path surfaces 423 instead of 500. |

### Phase 1 — Production-ready (blocker cho go-live)

> ✅ **Phase 1 complete (2026-06-10).** US-9.12 (Prometheus `/metrics`) and US-5.3
> (withdrawal SLA-timeout janitor) both shipped — no go-live blockers remain.
> Next focus is Phase 2 (compliance & quality).

### Phase 2 — Compliance & quality

| # | Story | Task | Effort |
|---|-------|------|:------:|
| 4 | US-7.4 | **Outbox event envelope** — standardize payload shape (reference, tran_type, channel, actor) across all SPs | 3d |
| 5 | US-10.7 | **Go integration tests** — testcontainers + real PG for posting paths | 5d |
| 6 | US-1.13 | **Related-doc attachment** — SP + endpoint for `FM_CLIENT_KYC.related_docs` | 2d |

> ✅ US-8.5 (client-master UPDATE audit triggers) shipped 2026-06-10 — the "Client-master change auditing" HARD RULE is now satisfied for the surviving core tables (`FM_CLIENT`, `FM_CLIENT_CONTACT`).

### Phase 3 — Scale & polish (backlog)

| # | Story | Task | Effort |
|---|-------|------|:------:|
| 7 | US-8.3 | Record reconciliation breaks (`WLT_RECON_BREAK` table + SP) | 3d |
| 8 | US-8.4 | PII access log (`WLT_PII_ACCESS_LOG`) | 2d |
| 9 | US-1.6 | KYC downgrade & 12-month re-KYC | 3d |
| 10 | US-6.10 | Branch/legal-entity label on GL config | 1d |
| 11 | US-9.15 | Rename TRAN_TYPE codes (high blast radius, schedule in quiet sprint) | 5d |

### Deferred (not MVP)

- US-6.2 remainder (full suspense GL) — when finance team needs GL recon with core banking
- US-6.4 (e-invoice) — when launching consumer receipts
- US-6.5 (maker-checker JE) — when ops needs manual adjustments
- US-7.3 (downstream consumers) — Treasury Service scope

> Phase 1 đã xong (US-9.12 + US-5.3 shipped 2026-06-10) — không còn blocker go-live. Tiếp theo là Phase 2 (compliance & quality).
> Phase 2 cần cho internal audit pass. Phase 3 là nice-to-have, lên kế hoạch theo roadmap.
