-- =============================================================================
-- wallet_gl_cutoff_test.sql — GL accounting-cutoff (modern-core model) asserts
-- =============================================================================
-- Verifies: (1) fn_accounting_date rolls at the cutoff; (2) WLT_GL_BATCH fills
-- ACCOUNTING_DATE from the DEFAULT (posting SPs unchanged); (3) the write-freeze
-- keys off ACCOUNTING_DATE, not POST_DATE; (4) the 24/7 customer ledger
-- WLT_TRAN_HIST is NOT period-frozen. All work runs inside one txn and is rolled
-- back, so the suite is repeatable and persists nothing.
--   docker compose exec -T postgres psql -U postgres -d wallet -f /dev/stdin < db/tests/wallet_gl_cutoff_test.sql
-- =============================================================================
\set ON_ERROR_STOP on
BEGIN;

DO $$
DECLARE
  v_gl      TEXT := (SELECT gl_code FROM fm_gl_mast LIMIT 1);
  v_cut     TIME := (SELECT cutoff_time FROM wlt_gl_config WHERE singleton);
  v_acct    DATE;
  v_blocked BOOLEAN := false;
BEGIN
  -- (1) cutoff function rolls the accounting date at cutoff_time (GMT+7)
  ASSERT fn_accounting_date(('2026-05-30 ' || (v_cut - INTERVAL '1 min') || '+07')::timestamptz)
         = DATE '2026-05-30', 'before cutoff → same day';
  ASSERT fn_accounting_date(('2026-05-30 ' || v_cut || '+07')::timestamptz)
         = DATE '2026-05-31', 'at cutoff → next day';
  ASSERT fn_accounting_date('2026-05-30 23:59:00+07'::timestamptz)
         = DATE '2026-05-31', 'after cutoff → next day';

  -- (2) ACCOUNTING_DATE auto-fills from the column DEFAULT (no SP change needed)
  INSERT INTO wlt_gl_batch(tran_key, seq_no, gl_code, amount, tran_nature, ccy, post_date, value_date)
  VALUES (-9910001, 1, v_gl, 100, 'DR', 'VND', CURRENT_DATE, CURRENT_DATE);
  SELECT accounting_date INTO v_acct FROM wlt_gl_batch WHERE tran_key = -9910001;
  ASSERT v_acct = fn_accounting_date(), 'DEFAULT fills ACCOUNTING_DATE';
  ASSERT v_acct >= CURRENT_DATE, 'accounting date is today or later (never in the past)';

  -- (3) freeze keys off ACCOUNTING_DATE: seal an accounting day, then a GL row
  --     dated into it is rejected (P0092) while an open-period row is accepted.
  INSERT INTO wlt_period(biz_date, status, closed_at, closed_by)
       VALUES (CURRENT_DATE - 1, 'CLOSED', now(), 'TEST')
  ON CONFLICT (biz_date) DO UPDATE SET status = 'CLOSED';
  BEGIN
    INSERT INTO wlt_gl_batch(tran_key, seq_no, gl_code, amount, tran_nature, ccy,
                             post_date, value_date, accounting_date)
    VALUES (-9910002, 1, v_gl, 100, 'DR', 'VND', CURRENT_DATE, CURRENT_DATE, CURRENT_DATE - 1);
  EXCEPTION WHEN sqlstate 'P0092' THEN v_blocked := true;
  END;
  ASSERT v_blocked, 'freeze blocks a closed ACCOUNTING_DATE';

  -- post-cutoff entry (accounting date defaults to today/next, > sealed) is allowed
  INSERT INTO wlt_gl_batch(tran_key, seq_no, gl_code, amount, tran_nature, ccy, post_date, value_date)
  VALUES (-9910003, 1, v_gl, 100, 'DR', 'VND', CURRENT_DATE, CURRENT_DATE);
  ASSERT EXISTS (SELECT 1 FROM wlt_gl_batch WHERE tran_key = -9910003), 'open accounting period accepts new GL';

  -- (4) the 24/7 customer ledger is NOT period-frozen in the modern model
  ASSERT NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_freeze_hist'),
         'WLT_TRAN_HIST has no period-freeze trigger';

  RAISE NOTICE 'GL CUTOFF TEST: ALL ASSERTIONS PASSED';
END $$;

ROLLBACK;  -- discard all test side-effects
