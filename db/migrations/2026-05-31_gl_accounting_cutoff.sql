-- =============================================================================
-- 2026-05-31_gl_accounting_cutoff.sql — Incremental migration
-- (tracked incremental migrations live in db/migrations/)
-- =============================================================================
-- Modern-core GL accounting cutoff (Vault/10x style): the 24/7 customer ledger
-- keeps POST_DATE = calendar date and is never period-frozen; the GL/accounting
-- layer cuts at a daily time (default 18:00 GMT+7). A GL entry posted at/after
-- the cutoff carries ACCOUNTING_DATE = next day, so the GL period can be SEALED
-- at the cutoff with NO ledger downtime (post-cutoff entries land in the open
-- period). Period close + freeze move from POST_DATE → ACCOUNTING_DATE.
--
-- SEQUENCING: filename sorts AFTER 2026-05-30_rename_wlt_batch_to_wlt_gl_batch
-- (references WLT_GL_BATCH). This migration adds the SCHEMA dependencies; the
-- freeze/EOD logic (fn_freeze_closed_period, eod_*, run_gl_close) lives in
-- wallet_sp_eod.sql and is applied by reloading that SP file on deploy.
-- Idempotent: safe to re-run.
-- =============================================================================
\set ON_ERROR_STOP on
BEGIN;

-- 1) GL cutoff config (one row) + accounting-date function -------------------
CREATE TABLE IF NOT EXISTS WLT_GL_CONFIG (
  singleton    BOOLEAN     PRIMARY KEY DEFAULT true CHECK (singleton),
  cutoff_time  TIME        NOT NULL DEFAULT '18:00:00',
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
INSERT INTO WLT_GL_CONFIG (singleton) VALUES (true) ON CONFLICT DO NOTHING;

CREATE OR REPLACE FUNCTION fn_accounting_date(p_ts timestamptz DEFAULT now())
RETURNS DATE
LANGUAGE sql STABLE AS $$
  SELECT CASE
           WHEN (p_ts AT TIME ZONE 'Asia/Ho_Chi_Minh')::time
                >= (SELECT cutoff_time FROM WLT_GL_CONFIG WHERE singleton)
           THEN ((p_ts AT TIME ZONE 'Asia/Ho_Chi_Minh')::date + 1)
           ELSE  (p_ts AT TIME ZONE 'Asia/Ho_Chi_Minh')::date
         END;
$$;

-- 2) ACCOUNTING_DATE on the GL journal ---------------------------------------
-- Backfill existing rows to their POST_DATE (they predate the cutoff model),
-- then make it NOT NULL with the cutoff default so posting SPs need no change.
ALTER TABLE WLT_GL_BATCH ADD COLUMN IF NOT EXISTS ACCOUNTING_DATE DATE;
UPDATE WLT_GL_BATCH SET ACCOUNTING_DATE = POST_DATE WHERE ACCOUNTING_DATE IS NULL;
ALTER TABLE WLT_GL_BATCH ALTER COLUMN ACCOUNTING_DATE SET NOT NULL;
ALTER TABLE WLT_GL_BATCH ALTER COLUMN ACCOUNTING_DATE SET DEFAULT fn_accounting_date();

-- 3) Indexes: trial-balance scan by accounting date; GL-feed pending by it ----
CREATE INDEX IF NOT EXISTS idx_gl_batch_acctdate ON WLT_GL_BATCH(ACCOUNTING_DATE, CCY);
DROP INDEX IF EXISTS idx_gl_batch_pending;
CREATE INDEX idx_gl_batch_pending ON WLT_GL_BATCH(ACCOUNTING_DATE) WHERE STATUS = 'P';

-- 4) Grants for the cutoff objects (local stack = wallet_app) -----------------
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'wallet_app') THEN
    GRANT SELECT ON WLT_GL_CONFIG TO wallet_app;
    GRANT EXECUTE ON FUNCTION fn_accounting_date(timestamptz) TO wallet_app;
  END IF;
END $$;

COMMIT;

-- 5) AFTER this migration, reload db/procedures/wallet_sp_eod.sql to apply the
--    ACCOUNTING_DATE-based freeze (fn_freeze_closed_period), the GL-feed /
--    trial-balance / close repointed to ACCOUNTING_DATE, and run_gl_close.
