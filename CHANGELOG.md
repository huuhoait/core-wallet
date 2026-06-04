# Changelog

All notable changes to this project. Format based on
[Keep a Changelog](https://keepachangelog.com/); the design-document history is
condensed from the HLD changelog.

> 🇻🇳 Lịch sử thay đổi. Phần lịch sử tài liệu được rút gọn từ changelog của HLD.

## [Unreleased]

### Changed — Close US-9.16 / US-9.17: doc sync for `WLT_CLIENT_*` → `FM_CLIENT_*` (2026-06-02)
- The table re-prefix `WLT_CLIENT_KYC` → `FM_CLIENT_KYC` (US-9.16) and
  `WLT_CLIENT_AUDIT_LOG` → `FM_CLIENT_AUDIT_LOG` (US-9.17) was **already present in
  schema/code/DB** (verified against `origin/master` + the live DB: tables,
  partitions of the audit log, PK/indexes, masked view `v_kyc_masked`, triggers
  `trg_audit_fm_kyc`/`fn_audit_client_change`, and Go `repo/client.go`).
- This change closes the stories by **syncing the lagging documentation** to the
  new names: `docs/dld/wallet_DLD.md`, `docs/hld/*`, `docs/specs/wallet_onboarding.md`,
  `docs/specs/web_portal.md`, `claudedocs/`, and `CLAUDE.md` (incl. fixing the stale
  `trg_audit_wlt_kyc` → `trg_audit_fm_kyc`). `USER_STORIES.md` US-9.16/9.17 → ✅.
- **No API / schema / code change** — provenance mentions ("renamed from …",
  "`WLT_` → `FM_`") are intentionally preserved in story/changelog text.

### Changed — Complete the `tfr` → `tran` rename, incl. the public API (2026-06-02)
- Finishes what US-9.14 left backward-compatible: every remaining `tfr` token is
  renamed to `tran`, **except the `TFR_SEQ_NO` family** (`TFR_SEQ_NO` /
  `tfr_seq_no` / Go `TFRSeqNo` — the per-leg pointer to the origin leg — kept).
- **BREAKING — HTTP response contract.** The JSON fields the previous step kept
  for compatibility are now renamed:
  - `tfr_internal_key` → `tran_internal_key`
  - `reversal_tfr_key` → `reversal_tran_key`
  - route param `:tfr_key` → `:tran_key` (`GET /v1/finance/transactions/:tran_key`)
  Postman collection/environment and the finance/web-portal specs updated to match.
- **DB:** sequence `seq_tfr` → `seq_tran`; column `WLT_WITHDRAW_TRACK.reversal_tfr_key`
  → `reversal_tran_key`; `fm_gl_mast.tfr_ind` → `tran_ind` (+ seed COPY header);
  index `idx_hist_tfr` → `idx_hist_tran`; all SP locals/params.
- **Go:** `ReversalTFRKey` → `ReversalTranKey`, `TFRInternalKey` → `TranInternalKey`,
  local `tfrKey`/`tfr` → `tranKey`/`tran`. `go build` + `go vet` green.

### Changed — Rename `tfr_internal_key` → `tran_internal_id` (US-9.14, 2026-05-31)
- The per-transaction grouping key was misnamed `tfr_internal_key` (`tfr`="transfer")
  although it links the legs of **every** posting type (topup/transfer/withdraw/
  merchant/reversal). Renamed for clarity:
  - **DB column** on `WLT_TRAN_HIST` (+ all partitions), `WLT_WITHDRAW_TRACK`,
    `WLT_SWEEP_LOG`; indexes follow.
  - **All SPs** (`db/export/schema.sql`): bodies, params, `RETURNS TABLE` columns,
    and the idempotency-cache / outbox `jsonb` keys (consistent write+read).
  - **Go** internals: `TFRInternalKey`→`TranInternalID` + repo SQL `SELECT`/`WHERE`.
  - SQL test suites + DLD/HLD/spec docs.
- **API kept backward-compatible** — the HTTP JSON response field stays
  `tfr_internal_key` / `reversal_tfr_key` (Go DTO json tags) and the route param
  stays `:tfr_key`; only events/internals move to `tran_internal_id`. Siblings
  `TFR_SEQ_NO` / `seq_tfr` are out of scope (unchanged).
- Verified: fresh `docker compose up` re-init (0 errors, 202 columns renamed),
  all SQL assertion suites pass, `go build` + `go test -race` green.

### Added — Load-test scenarios: merchant topup, fee reversal, restraint (2026-05-31)
- **3 new pgbench scripts** wired into the `run.sh` / `stress.sh` 8-way mix:
  - `deploy/loadtest/merchant_topup.sql` — consumer→merchant **SETTLEMENT** payment
    (the only on-ledger merchant-credit path; `post_topup` rejects non-STANDALONE).
  - `deploy/loadtest/withdraw_reversal.sql` — withdraw + `post_withdraw_reversal`,
    exercising the **reversal-with-fee** path (RVWD principal + RVFEE refund + DR
    reversal of revenue 401.01 / VAT 203.01 + treasury-status transition).
  - `deploy/loadtest/restraint.sql` — `add_restraint` (DEBIT/PLEDGE) + `release_restraint`
    lifecycle (balance-neutral; `\gset` threads the new `restraint_id` into the release).
  - New mix (/100): topup 20 / transfer 18 / withdraw 12 / reversal 10 /
    withdraw_reversal 10 / merchant_topup 12 / merchant_withdraw 10 / restraint 8.
    Verified end-to-end: 537 txns, **0 failed** across all 8 scripts.
- **Fixed `deploy/loadtest/setup.sql`** — it funded merchant settlement/shard
  sub-accounts via `post_topup`, which now raises `P0028` (ACCT_ROLE_INVALID — topup
  is STANDALONE-only), aborting the whole seed. Settlement/shards are now seeded with
  a direct opening `actual_bal` (the pattern the merchant SQL suites already use);
  consumer wallets stay on `post_topup`.

### Added — Restraint test suite + seed schema fix (2026-05-31)
- **`db/tests/wallet_restraint_test.sql`** — 25 self-contained, rollback-scoped
  cases covering `add_restraint` / `release_restraint` (previously untested):
  rollup of all 4 types (DEBIT/CREDIT/ALL/INFO) onto `WLT_ACCT`
  (`TOTAL_RESTRAINED_AMT`/`CR_BLOCKED`/`RESTRAINT_PRESENT`/`VERSION`), validation
  errors `P0060`–`P0064`/`P0001`/`P0004`, **posting-path enforcement** (DEBIT pledge
  shrinks `CALC_BAL` → withdraw `P0026`; full block `P0025`; credit block → topup
  `P0029`), and release semantics (restore, free-funds, `P0065`–`P0067`,
  multi-restraint recompute). 25/25 pass.
- **Fixed `db/seeds/wallet_seed.sql`** — `fn_create_client` still wrote the dropped
  `WLT_CLIENT_KYC.PHONE_NO`/`EMAIL` columns; updated to the encrypted schema
  (`PHONE_NO_ENC`/`PHONE_NO_HASH`/`EMAIL_ENC` via `pgp_sym_encrypt`+`digest`),
  matching `wallet_testdata_10.sql`. The documented seed flow ran clean again.

### Changed — Trim WLT_TRAN_HIST (2026-05-31)
- Dropped `TRAN_DATE` + `EFFECT_DATE` — they always equalled `POST_DATE` (redundant);
  ledger dating is now `POST_DATE` + `VALUE_DATE` only.
- Dropped `CLIENT_INFO` (per-posting client snapshot, US-2.7) — write-only with no
  reader; its sole builder `fn_build_client_info` is removed too.
- Posting SPs (`wallet_sp*.sql`) no longer write these columns; migration
  `db/migrations/2026-05-31_drop_tranhist_columns.sql` drops them on existing DBs.
  Verified regression-clean: accounting 17/17, merchant 10/10, transfer-reversal 3/3,
  reconciliation 13/13.

### Added — EOD period locking + GL-feed post (2026-05-30) — US-6.1/6.2, unblocks US-3.7
- **Period write-freeze (full immutability).** New `WLT_PERIOD` control table (one
  row per closed business date) + `fn_period_closed_through()` high-water mark.
  `BEFORE INSERT/UPDATE/DELETE` triggers (`fn_freeze_closed_period`) on `WLT_GL_BATCH`
  and `WLT_TRAN_HIST` reject any change to a row in a closed period — a sealed
  day's trial balance + hash chain (US-6.3) are now tamper-proof. SQLSTATE `P0092`
  → domain `PERIOD_CLOSED` → HTTP 409 (ISO 20022 `DT01`).
- **GL-feed post (T3).** `eod_gl_feed_post(D)` finalises the day's GL journal
  `WLT_GL_BATCH` `'P'`→`'S'`, chunked (COMMIT/chunk) + restart-safe.
- **Period close (T7).** `eod_close_period(D)` seals a *past* day (`D < CURRENT_DATE`)
  in `WLT_PERIOD` after all tasks are DONE; runs LAST. `run_eod` is now
  T1→T2→T5→T3→T6→T7.
- **Scheduler.** In-process EOD scheduler closes the **prior** day (fires after the
  midnight roll; default `EOD_RUN_AT=00:30`), matching the merged pg_cron schedule
  — a day can only be frozen once strictly in the past.
- Tracked migration `db/migrations/2026-05-30_eod_period_locking_gl_feed.sql`
  (mirrors the objects + hardens grants onto `wallet_eod`); SQL test
  `db/tests/wallet_eod_period_lock_test.sql` (10/10).

### Changed — Repository restructure (2026-05-30)
- Reorganized a flat root directory into a conventional layout:
  `docs/{hld,dld,specs}/`, `db/{ddl,procedures,seeds,tests}/`,
  `services/wallet-service/`, `deploy/{docker,loadtest}/`.
- Added top-level `README.md`, `USER_STORIES.md`, `docs/INDEX.md`, `.gitignore`,
  and initialized git.
- Updated path references in `docker-compose.yml` (init-script + config mounts)
  and `deploy/loadtest/*.sh` (working dir + script paths) to match.
- Replaced the stale root `.dockerignore` with a service-scoped one under
  `services/wallet-service/`.
- Moved legacy spreadsheets to `.archive/` (git-ignored).

> No application logic changed; the Go service still builds and docker-compose
> mounts resolve to the new paths.

---

## Design history (HLD) / Lịch sử thiết kế

> Versions below track the **design documents**, not code releases.

### v1.10 — 2026-05-28
Transaction metadata + client-info snapshot + client change-data audit.
`WLT_TRAN_HIST.METADATA`/`CLIENT_INFO` JSONB columns; `WLT_CLIENT_AUDIT_LOG`
with a SECURITY DEFINER trigger; posting and audit decoupled.

### v1.9 — 2026-05-28
Transactional outbox (`WLT_OUTBOX`) — events written atomically with the ledger.
Withdraw disbursement tracking (`WLT_WITHDRAW_TRACK`) with state machine +
`post_withdraw_reversal` + (designed) SLA-timeout janitor.

### v1.8 — 2026-05-28
Accounting Operations subsystem (§9b): EOD close & period locking, suspense GL,
daily trial balance, e-invoice integration, maker-checker journal entry.

### v1.7.x — 2026-05-28
Data lifecycle/backup/archive strategy (§9a); PII protection standards (§8.3,
Decree 13/2023, Cybersecurity Law, Circular 23/2019, ISO 27001).

### v1.6.x — 2026-05-28
Tech stack set to **Go 1.23 + PostgreSQL plpgsql stored functions** (replacing
Java/Spring). Scope reduced to **internal sync transactions only**; external
rails split into a separate Treasury Service. Deferred-locking posting pattern.

### v1.3–v1.5 — 2026-05-28
PostgreSQL 16 → 17; Fee & VAT engine (fee leg + GL revenue + VAT payable).

### v1.0–v1.2
Initial HLD; two-tier FM + WLT model; scope trimming (FX/SWIFT/onboarding detail
removed).
