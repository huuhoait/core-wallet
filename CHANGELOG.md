# Changelog

All notable changes to this project. Format based on
[Keep a Changelog](https://keepachangelog.com/); the design-document history is
condensed from the HLD changelog.

> 🇻🇳 Lịch sử thay đổi. Phần lịch sử tài liệu được rút gọn từ changelog của HLD.

## [Unreleased]

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
