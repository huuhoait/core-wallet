-- =============================================================================
-- 2026-05-30_rename_wlt_batch_to_wlt_gl_batch.sql — Incremental migration
-- (tracked incremental migrations live in db/migrations/)
-- =============================================================================
-- Renames the GL-journal table WLT_BATCH → WLT_GL_BATCH (clearer: it is the GL
-- feed, not a generic batch), plus its indexes / constraints / PK and the
-- balanced-posting trigger function body.
--
-- ORDERING: this file sorts AFTER the migrations that create WLT_BATCH objects
-- (eod_period_locking, ledger_integrity), so on an existing-DB upgrade those run
-- first (against WLT_BATCH) and this renames last. Fresh installs use
-- wallet_schema.sql, which already carries the final WLT_GL_BATCH name.
--
-- Grants and the trg_batch_balanced / trg_freeze_batch triggers are keyed by
-- table OID, so they follow the rename automatically. Only function BODIES that
-- hard-code the table name need fixing: fn_assert_batch_balanced lives ONLY in a
-- migration (ledger_integrity) so it is replaced here; the GL-feed / freeze
-- functions live in wallet_sp_eod.sql and are re-pointed when that SP file is
-- reloaded on deploy.
--
-- Function/trigger NAMES (fn_assert_batch_balanced / trg_batch_balanced) are
-- intentionally kept — only the table + its indexes/constraints are renamed.
-- Idempotent: safe to re-run.
-- =============================================================================
\set ON_ERROR_STOP on
BEGIN;

-- 1) Table
ALTER TABLE IF EXISTS WLT_BATCH RENAME TO WLT_GL_BATCH;

-- 2) Indexes
ALTER INDEX IF EXISTS idx_batch_gl_date RENAME TO idx_gl_batch_gl_date;
ALTER INDEX IF EXISTS idx_batch_ref     RENAME TO idx_gl_batch_ref;
ALTER INDEX IF EXISTS idx_batch_acct    RENAME TO idx_gl_batch_acct;
ALTER INDEX IF EXISTS idx_batch_pending RENAME TO idx_gl_batch_pending;

-- 3) Constraints + PK (RENAME CONSTRAINT has no IF EXISTS → guard each)
DO $$
DECLARE
  r TEXT[];
  renames TEXT[][] := ARRAY[
    ['wlt_batch_pkey',     'wlt_gl_batch_pkey'],
    ['fk_batch_gl',        'fk_gl_batch_gl'],
    ['fk_batch_ccy',       'fk_gl_batch_ccy'],
    ['chk_batch_nat',      'chk_gl_batch_nat'],
    ['chk_batch_amt',      'chk_gl_batch_amt'],
    ['chk_batch_status',   'chk_gl_batch_status']
  ];
BEGIN
  FOREACH r SLICE 1 IN ARRAY renames LOOP
    IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = r[1]) THEN
      EXECUTE format('ALTER TABLE WLT_GL_BATCH RENAME CONSTRAINT %I TO %I', r[1], r[2]);
    END IF;
  END LOOP;
END $$;

-- 4) Balanced-posting trigger function — re-point its body at the new table.
--    (Trigger trg_batch_balanced moved with the table on rename; only the body
--    referenced the old name. No-op trigger if it was never created.)
CREATE OR REPLACE FUNCTION fn_assert_batch_balanced()
RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public, pg_catalog AS $fn$
DECLARE
  v_dr NUMERIC(20,2);
  v_cr NUMERIC(20,2);
BEGIN
  SELECT COALESCE(SUM(AMOUNT) FILTER (WHERE TRAN_NATURE = 'DR'), 0),
         COALESCE(SUM(AMOUNT) FILTER (WHERE TRAN_NATURE = 'CR'), 0)
    INTO v_dr, v_cr
    FROM WLT_GL_BATCH
   WHERE TRAN_KEY = NEW.TRAN_KEY
     AND CCY      = NEW.CCY;

  IF v_dr <> v_cr THEN
    RAISE EXCEPTION 'BATCH_UNBALANCED: tran_key=% ccy=% DR=% CR=%',
      NEW.TRAN_KEY, NEW.CCY, v_dr, v_cr
      USING ERRCODE = 'P0091';
  END IF;
  RETURN NULL;  -- AFTER trigger: result ignored
END
$fn$;

COMMIT;
