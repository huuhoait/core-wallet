-- =============================================================================
-- 2026-05-31_drop_tranhist_columns.sql — Incremental migration
-- (tracked incremental migrations live in db/migrations/)
-- =============================================================================
-- Trims WLT_TRAN_HIST:
--   * TRAN_DATE, EFFECT_DATE — always equalled POST_DATE (redundant duplicates),
--     so POST_DATE / VALUE_DATE alone carry the dating.
--   * CLIENT_INFO — the per-posting client snapshot (US-2.7) is retired; it was
--     write-only (no reader). Its sole builder fn_build_client_info is dropped.
-- After this, reload db/procedures/wallet_sp*.sql (the posting SPs no longer write
-- these columns nor call fn_build_client_info). Idempotent: safe to re-run.
-- =============================================================================
\set ON_ERROR_STOP on
BEGIN;

ALTER TABLE WLT_TRAN_HIST DROP COLUMN IF EXISTS TRAN_DATE;
ALTER TABLE WLT_TRAN_HIST DROP COLUMN IF EXISTS EFFECT_DATE;
ALTER TABLE WLT_TRAN_HIST DROP COLUMN IF EXISTS CLIENT_INFO;

DROP FUNCTION IF EXISTS fn_build_client_info(VARCHAR);

COMMIT;
