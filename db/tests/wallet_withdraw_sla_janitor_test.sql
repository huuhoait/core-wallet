-- =============================================================================
-- wallet_withdraw_sla_janitor_test.sql — tests for reverse_stuck_withdrawals(),
-- the withdrawal SLA-timeout janitor (US-5.3). It auto-reverses withdrawals
-- still in SUBMITTED/ACKED/DISBURSING once FINAL_DEADLINE has passed, delegating
-- to post_withdraw_reversal so the ledger/GL/outbox semantics match a Treasury
-- reverse (US-3.3).
--
-- Isolation: the SP scans the whole WLT_WITHDRAW_TRACK table, so to stay correct
-- even on a DB already holding other in-flight withdrawals (e.g. load-test data)
-- we backdate THIS test's rows to a year-2000 FINAL_DEADLINE. That makes them the
-- globally-OLDEST candidates, so a batch=1 sweep (ORDER BY final_deadline) targets
-- exactly our row and never touches anyone else's. On a clean/CI DB ours are the
-- only candidates anyway. The whole thing runs in BEGIN…ROLLBACK.
-- =============================================================================
SET app.pii_dek = 'dev-test-pii-dek-do-not-use-in-prod';

BEGIN;
CREATE TEMP TABLE _t (id serial, name text, ok boolean, detail text) ON COMMIT DROP;

DO $$
DECLARE
  c1 text;
  k1 bigint; a1 text;
  v_bal_before numeric; v_bal_after numeric;
  v_status text;
  v_rev int; v_failed int; v_expired int;
  v_already boolean;
  v_amt numeric := 80000;
  -- distinct ancient deadlines so our rows sort deterministically among themselves
  d2 timestamptz := timestamptz '2000-01-01 00:00:02';
  d4 timestamptz := timestamptz '2000-01-01 00:00:04';
  d6a timestamptz := timestamptz '2000-01-01 00:00:06';
  d6b timestamptz := timestamptz '2000-01-01 00:00:07';
  d5 timestamptz := timestamptz '2000-01-01 00:00:09';
BEGIN
  c1 := fn_create_client('Janitor A','888500000001','0885500001','a@jan.test','IND','2');
  SELECT internal_key, acct_no INTO k1, a1 FROM fn_open_wallet(c1,'CONSUMER',1000000);

  -- ───── TC1: a fresh withdrawal (deadline in the future) is NOT a candidate ─────
  PERFORM post_withdraw(a1, v_amt, 'JAN-W1', 'JAN-PAYOUT-1', 'VCB', '111122223333');
  SELECT count(*) INTO v_rev FROM wlt_withdraw_track
   WHERE ext_payout_ref = 'JAN-PAYOUT-1'
     AND status IN ('SUBMITTED','ACKED','DISBURSING') AND final_deadline < now();
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC1 fresh withdrawal (deadline in future) is not a janitor candidate',
     v_rev = 0,
     format('candidate_rows=%s', v_rev));

  -- ───── TC2: a SUBMITTED withdrawal past FINAL_DEADLINE is auto-reversed ─────
  SELECT actual_bal INTO v_bal_before FROM wlt_acct WHERE internal_key = k1;
  UPDATE wlt_withdraw_track SET final_deadline = d2 WHERE ext_payout_ref = 'JAN-PAYOUT-1';
  SELECT reversed_count, failed_count, expired_count
    INTO v_rev, v_failed, v_expired FROM reverse_stuck_withdrawals(1);  -- targets our oldest row
  SELECT status INTO v_status FROM wlt_withdraw_track WHERE ext_payout_ref = 'JAN-PAYOUT-1';
  SELECT actual_bal INTO v_bal_after FROM wlt_acct WHERE internal_key = k1;
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC2 stuck SUBMITTED withdrawal is reversed',
     v_rev = 1 AND v_failed = 0 AND v_expired = 0 AND v_status = 'REVERSED',
     format('reversed=%s failed=%s expired=%s status=%s', v_rev, v_failed, v_expired, v_status));
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC2b reversal credits principal + fee/VAT back to the wallet',
     v_bal_after > v_bal_before,
     format('bal_before=%s bal_after=%s', v_bal_before, v_bal_after));

  -- ───── TC3: idempotent — re-reversing the same ref is a no-op replay ─────
  -- (the janitor relies on post_withdraw_reversal being idempotent on REVERSED)
  SELECT was_already_reversed INTO v_already
    FROM post_withdraw_reversal('JAN-PAYOUT-1','SLA_TIMEOUT','retry','JANITOR','SYS','JANITOR');
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC3 re-reversing an already-REVERSED withdrawal is an idempotent replay',
     v_already = true,
     format('was_already_reversed=%s', v_already));

  -- ───── TC4: an ACKED (in-flight) withdrawal past deadline is also reversed ─────
  PERFORM post_withdraw(a1, v_amt, 'JAN-W4', 'JAN-PAYOUT-4', 'VCB', '111122224444');
  PERFORM mark_withdraw_acked('JAN-PAYOUT-4', 'BATCH-X', 'TREASURY', 't');
  UPDATE wlt_withdraw_track SET final_deadline = d4 WHERE ext_payout_ref = 'JAN-PAYOUT-4';
  SELECT reversed_count INTO v_rev FROM reverse_stuck_withdrawals(1);
  SELECT status INTO v_status FROM wlt_withdraw_track WHERE ext_payout_ref = 'JAN-PAYOUT-4';
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC4 stuck ACKED withdrawal is reversed too',
     v_rev = 1 AND v_status = 'REVERSED',
     format('reversed=%s status=%s', v_rev, v_status));

  -- ───── TC5: batch limit is honoured — two stuck rows, limit 1 → one per sweep ──
  PERFORM post_withdraw(a1, v_amt, 'JAN-W6A', 'JAN-PAYOUT-6A', 'VCB', '111122226661');
  PERFORM post_withdraw(a1, v_amt, 'JAN-W6B', 'JAN-PAYOUT-6B', 'VCB', '111122226662');
  UPDATE wlt_withdraw_track SET final_deadline = d6a WHERE ext_payout_ref = 'JAN-PAYOUT-6A';
  UPDATE wlt_withdraw_track SET final_deadline = d6b WHERE ext_payout_ref = 'JAN-PAYOUT-6B';
  SELECT reversed_count INTO v_rev FROM reverse_stuck_withdrawals(1);
  SELECT status INTO v_status FROM wlt_withdraw_track WHERE ext_payout_ref = 'JAN-PAYOUT-6A';
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC5 batch limit caps rows reversed per sweep (oldest first)',
     v_rev = 1 AND v_status = 'REVERSED',
     format('reversed=%s 6A_status=%s', v_rev, v_status));
  SELECT status INTO v_status FROM wlt_withdraw_track WHERE ext_payout_ref = 'JAN-PAYOUT-6B';
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC5b the second stuck row is still pending after a limit-1 sweep',
     v_status = 'SUBMITTED',
     format('6B_status=%s', v_status));
  SELECT reversed_count INTO v_rev FROM reverse_stuck_withdrawals(1);  -- next sweep clears it
  SELECT status INTO v_status FROM wlt_withdraw_track WHERE ext_payout_ref = 'JAN-PAYOUT-6B';
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC5c next sweep clears the remaining stuck row',
     v_rev = 1 AND v_status = 'REVERSED',
     format('reversed=%s 6B_status=%s', v_rev, v_status));

  -- ───── TC6: a withdrawal stuck PAST the 168h reversal window is NOT reversed,
  --            counted as expired (needs manual handling), status unchanged ─────
  -- (run last: this row stays a candidate, so we don't sweep again after it)
  PERFORM post_withdraw(a1, v_amt, 'JAN-W5', 'JAN-PAYOUT-5', 'VCB', '111122225555');
  UPDATE wlt_withdraw_track
     SET final_deadline = d5,
         submitted_at   = clock_timestamp() - interval '169 hours'  -- older than WDRAW 168h window
   WHERE ext_payout_ref = 'JAN-PAYOUT-5';
  SELECT reversed_count, failed_count, expired_count
    INTO v_rev, v_failed, v_expired FROM reverse_stuck_withdrawals(1);
  SELECT status INTO v_status FROM wlt_withdraw_track WHERE ext_payout_ref = 'JAN-PAYOUT-5';
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC6 withdrawal past 168h window is reported expired, not reversed',
     v_rev = 0 AND v_expired = 1 AND v_status = 'SUBMITTED',
     format('reversed=%s expired=%s status=%s', v_rev, v_expired, v_status));
END $$;

-- ───── results ─────
SELECT id, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, name, detail
  FROM _t ORDER BY id;

DO $$
DECLARE n_fail int;
BEGIN
  SELECT count(*) INTO n_fail FROM _t WHERE NOT ok;
  IF n_fail > 0 THEN
    RAISE EXCEPTION 'wallet_withdraw_sla_janitor_test: % case(s) FAILED', n_fail;
  END IF;
  RAISE NOTICE 'wallet_withdraw_sla_janitor_test: ALL PASS';
END $$;

ROLLBACK;
