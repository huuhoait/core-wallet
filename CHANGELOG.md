# Changelog

All notable changes to this project. Format based on
[Keep a Changelog](https://keepachangelog.com/); the design-document history is
condensed from the HLD changelog.

> 🇻🇳 Lịch sử thay đổi. Phần lịch sử tài liệu được rút gọn từ changelog của HLD.

## [Unreleased]

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
