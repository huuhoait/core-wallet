-- =============================================================================
-- wallet_eod_period_lock_test.sql — GL period write-freeze (accounting-date) +
-- high-water mark + GL-feed transition  (modern-core model)
-- =============================================================================
-- Deterministic, fully transactional (BEGIN .. ROLLBACK). Asserts the GL period
-- lock (US-6.1) under the modern-core model:
--   * the freeze keys off WLT_GL_BATCH.ACCOUNTING_DATE (NOT post_date) — once an
--     accounting day is closed its GL rows are immutable (no INSERT/UPDATE/DELETE);
--   * the 24/7 customer ledger WLT_TRAN_HIST is NOT period-frozen (append-only by
--     convention; reversals are compensating entries in the open period);
--   * the high-water mark + the GL-feed 'P'→'S' transition (T3) still hold.
--
-- The high-water date is pinned to CURRENT_DATE-1; the suite SKIPS itself if the
-- DB already carries any closed period (so it only runs on a fresh seeded DB).
-- The COMMIT-looping procedures (eod_gl_feed_post / eod_close_period via
-- run_gl_close) cannot run inside this rollback-scoped suite — exercise them with
-- run_gl_close(CURRENT_DATE) on the stack (see README / CHANGELOG EOD section).
-- =============================================================================
BEGIN;
CREATE TEMP TABLE _t (id serial, name text, ok boolean, detail text) ON COMMIT DROP;

DO $$
DECLARE
  v_hw    DATE := CURRENT_DATE - 1;        -- becomes the closed high-water accounting date
  v_below DATE := CURRENT_DATE - 2;        -- strictly inside the closed range
  v_open  DATE := fn_accounting_date();    -- the current OPEN accounting date (> high-water)
  v_ik    BIGINT := COALESCE((SELECT internal_key FROM wlt_acct LIMIT 1), 1);
  v_through DATE;
  v_upd   BIGINT;
  v_s     INTEGER;
BEGIN
  IF fn_period_closed_through() IS NOT NULL THEN
    INSERT INTO _t(name,ok,detail) VALUES
      ('SKIPPED: DB already has closed periods (run on a fresh seeded DB)', true,
       'closed_through='||fn_period_closed_through()::text);
    RETURN;
  END IF;

  -- ───── seed an "old" GL row dated INTO the soon-to-be-closed accounting day,
  --       and an old customer-ledger row — both BEFORE anything is sealed ─────
  INSERT INTO wlt_gl_batch(tran_key,seq_no,gl_code,amount,tran_nature,ccy,post_date,value_date,accounting_date,status)
  VALUES (-7000, 1, '201.01.001', 100, 'DR', 'VND', v_hw, v_hw, v_hw, 'P');
  INSERT INTO wlt_tran_hist(internal_key,tran_type,tran_date,effect_date,post_date,value_date,
                            tran_amt,cr_dr_maint_ind,previous_bal_amt,actual_bal_amt,reference,ccy)
  VALUES (v_ik,'TEST',v_hw,v_hw,v_hw,v_hw,100,'DR',0,0,'FREEZE-OLD-HIST','VND');

  -- ───── seal CURRENT_DATE-30 and CURRENT_DATE-1; future date merely OPEN ─────
  INSERT INTO wlt_period(biz_date, status) VALUES
    (CURRENT_DATE - 30, 'CLOSED'), (v_hw, 'CLOSED'), (CURRENT_DATE + 5, 'OPEN');

  -- ───── TC1: high-water = latest CLOSED date, ignoring OPEN rows ─────
  v_through := fn_period_closed_through();
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC1 fn_period_closed_through = latest CLOSED (ignores OPEN)',
     v_through = v_hw, format('closed_through=%s want=%s', v_through, v_hw));

  -- ───── TC2: freeze rejects INSERT with accounting_date ON the high-water ─────
  BEGIN
    INSERT INTO wlt_gl_batch(tran_key,seq_no,gl_code,amount,tran_nature,ccy,post_date,value_date,accounting_date)
    VALUES (-7001, 1, '201.01.001', 100, 'DR', 'VND', v_open, v_open, v_hw);
    INSERT INTO _t(name,ok,detail) VALUES ('TC2 freeze rejects INSERT accounting_date = closed', false, 'no exception');
  EXCEPTION WHEN sqlstate 'P0092' THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC2 freeze rejects INSERT accounting_date = closed', true, SQLERRM);
  WHEN others THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC2 freeze rejects INSERT accounting_date = closed', false, 'wrong error: '||SQLERRM);
  END;

  -- ───── TC3: freeze rejects INSERT with accounting_date BELOW the high-water ─────
  BEGIN
    INSERT INTO wlt_gl_batch(tran_key,seq_no,gl_code,amount,tran_nature,ccy,post_date,value_date,accounting_date)
    VALUES (-7002, 1, '201.01.001', 100, 'DR', 'VND', v_open, v_open, v_below);
    INSERT INTO _t(name,ok,detail) VALUES ('TC3 freeze rejects INSERT accounting_date < closed', false, 'no exception');
  EXCEPTION WHEN sqlstate 'P0092' THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC3 freeze rejects INSERT accounting_date < closed', true, SQLERRM);
  WHEN others THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC3 freeze rejects INSERT accounting_date < closed', false, 'wrong error: '||SQLERRM);
  END;

  -- ───── TC4: freeze ALLOWS INSERT on the open accounting date (> high-water) ─────
  BEGIN
    INSERT INTO wlt_gl_batch(tran_key,seq_no,gl_code,amount,tran_nature,ccy,post_date,value_date,accounting_date,status)
    VALUES (-7050, 1, '201.01.001', 100, 'DR', 'VND', CURRENT_DATE, CURRENT_DATE, v_open, 'S');
    INSERT INTO _t(name,ok,detail) VALUES ('TC4 freeze allows INSERT accounting_date = open', true, 'inserted');
  EXCEPTION WHEN others THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC4 freeze allows INSERT accounting_date = open', false, 'unexpected: '||SQLERRM);
  END;

  -- ───── TC5: the 24/7 customer ledger is NOT period-frozen — INSERT dated into
  --            a closed day is ALLOWED (modern model: ledger ≠ GL period) ─────
  BEGIN
    INSERT INTO wlt_tran_hist(internal_key,tran_type,tran_date,effect_date,post_date,value_date,
                              tran_amt,cr_dr_maint_ind,previous_bal_amt,actual_bal_amt,reference,ccy)
    VALUES (v_ik,'TEST',v_hw,v_hw,v_hw,v_hw,100,'DR',0,0,'FREEZE-NEW-HIST','VND');
    INSERT INTO _t(name,ok,detail) VALUES ('TC5 WLT_TRAN_HIST NOT period-frozen — INSERT allowed', true, 'inserted');
  EXCEPTION WHEN others THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC5 WLT_TRAN_HIST NOT period-frozen — INSERT allowed', false, 'unexpected: '||SQLERRM);
  END;

  -- ───── TC6: GL-feed flips only PENDING legs P→S on the OPEN accounting date ─────
  -- (proves the legitimate pre-close UPDATE is NOT blocked by the freeze)
  INSERT INTO wlt_gl_batch(tran_key,seq_no,gl_code,amount,tran_nature,ccy,post_date,value_date,accounting_date,status) VALUES
    (-7100, 1, '201.01.001', 100, 'DR', 'VND', CURRENT_DATE, CURRENT_DATE, v_open, 'P'),
    (-7100, 2, '101.02.001', 100, 'CR', 'VND', CURRENT_DATE, CURRENT_DATE, v_open, 'P'),
    (-7101, 1, '201.01.001', 100, 'DR', 'VND', CURRENT_DATE, CURRENT_DATE, v_open, 'S');
  UPDATE wlt_gl_batch SET status='S', time_stamp=now()
   WHERE accounting_date = v_open AND status = 'P' AND tran_key < 0;
  GET DIAGNOSTICS v_upd = ROW_COUNT;
  SELECT count(*) INTO v_s FROM wlt_gl_batch WHERE tran_key IN (-7100,-7101) AND status='S';
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC6 GL-feed flips only PENDING legs P→S (open accounting date)',
     v_upd = 2 AND v_s = 3, format('flipped=%s sent=%s (want 2 / 3)', v_upd, v_s));

  -- ───── TC7: freeze rejects UPDATE of a GL row in a closed accounting period ─────
  BEGIN
    UPDATE wlt_gl_batch SET status='S' WHERE tran_key = -7000;   -- the old v_hw row
    INSERT INTO _t(name,ok,detail) VALUES ('TC7 freeze rejects UPDATE of closed-period WLT_GL_BATCH row', false, 'no exception');
  EXCEPTION WHEN sqlstate 'P0092' THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC7 freeze rejects UPDATE of closed-period WLT_GL_BATCH row', true, SQLERRM);
  WHEN others THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC7 freeze rejects UPDATE of closed-period WLT_GL_BATCH row', false, 'wrong error: '||SQLERRM);
  END;

  -- ───── TC8: freeze rejects DELETE of a GL row in a closed accounting period ─────
  BEGIN
    DELETE FROM wlt_gl_batch WHERE tran_key = -7000;
    INSERT INTO _t(name,ok,detail) VALUES ('TC8 freeze rejects DELETE of closed-period WLT_GL_BATCH row', false, 'no exception');
  EXCEPTION WHEN sqlstate 'P0092' THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC8 freeze rejects DELETE of closed-period WLT_GL_BATCH row', true, SQLERRM);
  WHEN others THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC8 freeze rejects DELETE of closed-period WLT_GL_BATCH row', false, 'wrong error: '||SQLERRM);
  END;

  -- ───── TC9: customer ledger UPDATE is ALLOWED (NOT period-frozen) ─────
  BEGIN
    UPDATE wlt_tran_hist SET narrative='edit' WHERE reference = 'FREEZE-OLD-HIST';
    GET DIAGNOSTICS v_upd = ROW_COUNT;
    INSERT INTO _t(name,ok,detail) VALUES ('TC9 WLT_TRAN_HIST UPDATE allowed (not period-frozen)', v_upd >= 1, format('updated=%s', v_upd));
  EXCEPTION WHEN others THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC9 WLT_TRAN_HIST UPDATE allowed (not period-frozen)', false, 'unexpected: '||SQLERRM);
  END;

  -- ───── TC10: customer ledger DELETE is ALLOWED (NOT period-frozen) ─────
  BEGIN
    DELETE FROM wlt_tran_hist WHERE reference = 'FREEZE-OLD-HIST';
    GET DIAGNOSTICS v_upd = ROW_COUNT;
    INSERT INTO _t(name,ok,detail) VALUES ('TC10 WLT_TRAN_HIST DELETE allowed (not period-frozen)', v_upd >= 1, format('deleted=%s', v_upd));
  EXCEPTION WHEN others THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC10 WLT_TRAN_HIST DELETE allowed (not period-frozen)', false, 'unexpected: '||SQLERRM);
  END;
END $$;

SELECT lpad(id::text,2) AS "#", CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, name, detail FROM _t ORDER BY id;
SELECT count(*) AS total, count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed FROM _t;
ROLLBACK;
