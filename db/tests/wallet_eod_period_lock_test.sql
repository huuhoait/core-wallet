-- =============================================================================
-- wallet_eod_period_lock_test.sql — period write-freeze (full immutability) +
-- high-water mark + GL-feed transition
-- =============================================================================
-- Deterministic, fully transactional (BEGIN .. ROLLBACK): asserts the period
-- lock (US-6.1) that makes a closed business date IMMUTABLE — no INSERT, UPDATE
-- or DELETE — the guarantee US-3.7 (cross-period reversal) rests on, plus the
-- high-water mark and the GL-feed 'P'→'S' transition (T3, US-6.2).
--
-- The high-water date is pinned to CURRENT_DATE-1; the suite SKIPS itself if the
-- DB already carries any closed period (so it only runs on a fresh seeded DB,
-- like the other db/tests/* suites), keeping the assertions deterministic.
--
-- The COMMIT-looping procedures (eod_gl_feed_post, eod_close_period via run_eod)
-- cannot run inside this rollback-scoped suite — exercise them with
-- run_eod(CURRENT_DATE-1) on the stack (see README / CHANGELOG EOD section).
-- =============================================================================
BEGIN;
CREATE TEMP TABLE _t (id serial, name text, ok boolean, detail text) ON COMMIT DROP;

DO $$
DECLARE
  v_hw    DATE := CURRENT_DATE - 1;     -- becomes the closed high-water mark
  v_below DATE := CURRENT_DATE - 2;     -- strictly inside the closed range
  v_today DATE := CURRENT_DATE;         -- the live, open date
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

  -- ───── seed two "old" rows on v_hw BEFORE anything is sealed ─────
  INSERT INTO wlt_batch(tran_key,seq_no,gl_code,amount,tran_nature,ccy,post_date,value_date,status)
  VALUES (-7000, 1, '201.01.001', 100, 'DR', 'VND', v_hw, v_hw, 'P');
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

  -- ───── TC2: freeze rejects INSERT dated ON the high-water (P0092) ─────
  BEGIN
    INSERT INTO wlt_batch(tran_key,seq_no,gl_code,amount,tran_nature,ccy,post_date,value_date)
    VALUES (-7001, 1, '201.01.001', 100, 'DR', 'VND', v_hw, v_hw);
    INSERT INTO _t(name,ok,detail) VALUES ('TC2 freeze rejects INSERT post_date = closed', false, 'no exception');
  EXCEPTION WHEN sqlstate 'P0092' THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC2 freeze rejects INSERT post_date = closed', true, SQLERRM);
  WHEN others THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC2 freeze rejects INSERT post_date = closed', false, 'wrong error: '||SQLERRM);
  END;

  -- ───── TC3: freeze rejects INSERT dated BELOW the high-water (P0092) ─────
  BEGIN
    INSERT INTO wlt_batch(tran_key,seq_no,gl_code,amount,tran_nature,ccy,post_date,value_date)
    VALUES (-7002, 1, '201.01.001', 100, 'DR', 'VND', v_below, v_below);
    INSERT INTO _t(name,ok,detail) VALUES ('TC3 freeze rejects INSERT post_date < closed', false, 'no exception');
  EXCEPTION WHEN sqlstate 'P0092' THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC3 freeze rejects INSERT post_date < closed', true, SQLERRM);
  WHEN others THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC3 freeze rejects INSERT post_date < closed', false, 'wrong error: '||SQLERRM);
  END;

  -- ───── TC4: freeze ALLOWS INSERT on the open date (> high-water) ─────
  BEGIN
    INSERT INTO wlt_batch(tran_key,seq_no,gl_code,amount,tran_nature,ccy,post_date,value_date,status)
    VALUES (-7050, 1, '201.01.001', 100, 'DR', 'VND', v_today, v_today, 'S');  -- 'S' so it stays out of the TC6 feed scope
    INSERT INTO _t(name,ok,detail) VALUES ('TC4 freeze allows INSERT post_date = today', true, 'inserted');
  EXCEPTION WHEN others THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC4 freeze allows INSERT post_date = today', false, 'unexpected: '||SQLERRM);
  END;

  -- ───── TC5: freeze guards the customer ledger too (WLT_TRAN_HIST) ─────
  BEGIN
    INSERT INTO wlt_tran_hist(internal_key,tran_type,tran_date,effect_date,post_date,value_date,
                              tran_amt,cr_dr_maint_ind,previous_bal_amt,actual_bal_amt,reference,ccy)
    VALUES (v_ik,'TEST',v_hw,v_hw,v_hw,v_hw,100,'DR',0,0,'FREEZE-NEW-HIST','VND');
    INSERT INTO _t(name,ok,detail) VALUES ('TC5 freeze rejects INSERT WLT_TRAN_HIST post_date = closed', false, 'no exception');
  EXCEPTION WHEN sqlstate 'P0092' THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC5 freeze rejects INSERT WLT_TRAN_HIST post_date = closed', true, SQLERRM);
  WHEN others THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC5 freeze rejects INSERT WLT_TRAN_HIST post_date = closed', false, 'wrong error: '||SQLERRM);
  END;

  -- ───── TC6: GL-feed flips only PENDING legs P→S on the OPEN date ─────
  -- (proves the legitimate pre-close UPDATE is NOT blocked by the freeze)
  INSERT INTO wlt_batch(tran_key,seq_no,gl_code,amount,tran_nature,ccy,post_date,value_date,status) VALUES
    (-7100, 1, '201.01.001', 100, 'DR', 'VND', v_today, v_today, 'P'),
    (-7100, 2, '101.02.001', 100, 'CR', 'VND', v_today, v_today, 'P'),
    (-7101, 1, '201.01.001', 100, 'DR', 'VND', v_today, v_today, 'S');
  UPDATE wlt_batch SET status='S', time_stamp=now()
   WHERE post_date = v_today AND status = 'P' AND tran_key < 0;
  GET DIAGNOSTICS v_upd = ROW_COUNT;
  SELECT count(*) INTO v_s FROM wlt_batch WHERE tran_key IN (-7100,-7101) AND status='S';
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC6 GL-feed flips only PENDING legs P→S (open date)',
     v_upd = 2 AND v_s = 3, format('flipped=%s sent=%s (want 2 / 3)', v_upd, v_s));

  -- ───── TC7: freeze rejects UPDATE of a row in a closed period (P0092) ─────
  BEGIN
    UPDATE wlt_batch SET status='S' WHERE tran_key = -7000;   -- the old v_hw row
    INSERT INTO _t(name,ok,detail) VALUES ('TC7 freeze rejects UPDATE of closed-period WLT_BATCH row', false, 'no exception');
  EXCEPTION WHEN sqlstate 'P0092' THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC7 freeze rejects UPDATE of closed-period WLT_BATCH row', true, SQLERRM);
  WHEN others THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC7 freeze rejects UPDATE of closed-period WLT_BATCH row', false, 'wrong error: '||SQLERRM);
  END;

  -- ───── TC8: freeze rejects DELETE of a row in a closed period (P0092) ─────
  BEGIN
    DELETE FROM wlt_batch WHERE tran_key = -7000;
    INSERT INTO _t(name,ok,detail) VALUES ('TC8 freeze rejects DELETE of closed-period WLT_BATCH row', false, 'no exception');
  EXCEPTION WHEN sqlstate 'P0092' THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC8 freeze rejects DELETE of closed-period WLT_BATCH row', true, SQLERRM);
  WHEN others THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC8 freeze rejects DELETE of closed-period WLT_BATCH row', false, 'wrong error: '||SQLERRM);
  END;

  -- ───── TC9: same immutability on the customer ledger (UPDATE) ─────
  BEGIN
    UPDATE wlt_tran_hist SET narrative='tamper' WHERE reference = 'FREEZE-OLD-HIST';
    INSERT INTO _t(name,ok,detail) VALUES ('TC9 freeze rejects UPDATE of closed-period WLT_TRAN_HIST row', false, 'no exception');
  EXCEPTION WHEN sqlstate 'P0092' THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC9 freeze rejects UPDATE of closed-period WLT_TRAN_HIST row', true, SQLERRM);
  WHEN others THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC9 freeze rejects UPDATE of closed-period WLT_TRAN_HIST row', false, 'wrong error: '||SQLERRM);
  END;

  -- ───── TC10: same immutability on the customer ledger (DELETE) ─────
  BEGIN
    DELETE FROM wlt_tran_hist WHERE reference = 'FREEZE-OLD-HIST';
    INSERT INTO _t(name,ok,detail) VALUES ('TC10 freeze rejects DELETE of closed-period WLT_TRAN_HIST row', false, 'no exception');
  EXCEPTION WHEN sqlstate 'P0092' THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC10 freeze rejects DELETE of closed-period WLT_TRAN_HIST row', true, SQLERRM);
  WHEN others THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC10 freeze rejects DELETE of closed-period WLT_TRAN_HIST row', false, 'wrong error: '||SQLERRM);
  END;
END $$;

SELECT lpad(id::text,2) AS "#", CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, name, detail FROM _t ORDER BY id;
SELECT count(*) AS total, count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed FROM _t;
ROLLBACK;
