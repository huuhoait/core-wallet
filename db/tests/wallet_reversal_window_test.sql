-- =============================================================================
-- wallet_reversal_window_test.sql — tests for WLT_TRAN_DEF.reversal_window_hours
-- enforcement across the 5 reversal SPs. Seeded value is 168 hours (7 days);
-- we backdate WLT_API_MESSAGE.PROCESSED_AT to simulate "old" originals.
-- =============================================================================
-- fn_create_client requires app.pii_dek to encrypt PII columns. In prod this
-- comes from `ALTER DATABASE ... SET app.pii_dek=...`; session-scope it here
-- so this file is self-contained (same trick as wallet_fee_charge_test.sql).
SET app.pii_dek = 'dev-test-pii-dek-do-not-use-in-prod';

BEGIN;
CREATE TEMP TABLE _t (id serial, name text, ok boolean, detail text) ON COMMIT DROP;

DO $$
DECLARE
  c1 text; c2 text;
  k1 bigint; k2 bigint;
  a1 text; a2 text;
  v_rev bigint; v_already boolean; v_nb numeric;
  v_seeded int;
BEGIN
  -- ───── TC0: seed sanity — reversible forward types carry the 168h window ─────
  SELECT count(*) INTO v_seeded
    FROM wlt_tran_def
   WHERE reversal_tran_type IS NOT NULL
     AND reversal_window_hours IS DISTINCT FROM 168;
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC0 every forward type with a reversal_tran_type is seeded to 168h',
     v_seeded = 0,
     format('rows-not-168h=%s', v_seeded));

  c1 := fn_create_client('Window A','888200000001','0882200001','a@win.test','IND','2');
  c2 := fn_create_client('Window B','888200000002','0882200002','b@win.test','IND','2');
  SELECT internal_key, acct_no INTO k1, a1 FROM fn_open_wallet(c1,'CONSUMER',1000000);
  SELECT internal_key, acct_no INTO k2, a2 FROM fn_open_wallet(c2,'CONSUMER',1000000);

  -- ───── TC1: TOPUP inside the window reverses normally ─────
  PERFORM post_topup(a1, 50000, 'WIN-T1', '{}'::jsonb, 'BANK', 't');
  SELECT reversal_tran_key, was_already_reversed
    INTO v_rev, v_already
    FROM post_topup_reversal('WIN-T1', 'inside window', 'OPS_MANUAL', 'SYS', 't');
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC1 topup reversal inside window succeeds',
     v_already = false AND v_rev IS NOT NULL,
     format('rev_tran=%s was_already=%s', v_rev, v_already));

  -- ───── TC2: TOPUP older than 168h is rejected with P0060 ─────
  PERFORM post_topup(a1, 60000, 'WIN-T2', '{}'::jsonb, 'BANK', 't');
  UPDATE wlt_api_message
     SET processed_at = clock_timestamp() - interval '169 hours'
   WHERE object_ref_id = 'WIN-T2' AND object_subject = 'TOPUP';
  BEGIN
    PERFORM post_topup_reversal('WIN-T2', 'too late', 'OPS_MANUAL', 'SYS', 't');
    INSERT INTO _t(name,ok,detail) VALUES
      ('TC2 topup reversal outside window rejected with P0060',
       false, 'no exception raised');
  EXCEPTION WHEN sqlstate 'P0060' THEN
    INSERT INTO _t(name,ok,detail) VALUES
      ('TC2 topup reversal outside window rejected with P0060',
       SQLERRM LIKE 'REVERSAL_WINDOW_EXPIRED:%', SQLERRM);
  WHEN others THEN
    INSERT INTO _t(name,ok,detail) VALUES
      ('TC2 topup reversal outside window rejected with P0060',
       false, 'wrong sqlstate: '||SQLERRM);
  END;

  -- ───── TC3: window check is BYPASSED on the idempotent (already-reversed) path ─────
  -- Reverse fresh, then backdate orig past window, retry — must still report
  -- was_already_reversed=true (ops should not be blocked from re-querying).
  PERFORM post_topup(a1, 70000, 'WIN-T3', '{}'::jsonb, 'BANK', 't');
  PERFORM post_topup_reversal('WIN-T3', 'first call', 'OPS_MANUAL', 'SYS', 't');
  UPDATE wlt_api_message
     SET processed_at = clock_timestamp() - interval '300 hours'
   WHERE object_ref_id = 'WIN-T3' AND object_subject = 'TOPUP';
  BEGIN
    SELECT was_already_reversed INTO v_already
      FROM post_topup_reversal('WIN-T3', 'retry past window', 'OPS_MANUAL', 'SYS', 't');
    INSERT INTO _t(name,ok,detail) VALUES
      ('TC3 idempotent retry past window still returns was_already_reversed=true',
       v_already = true, format('was_already=%s', v_already));
  EXCEPTION WHEN others THEN
    INSERT INTO _t(name,ok,detail) VALUES
      ('TC3 idempotent retry past window still returns was_already_reversed=true',
       false, 'unexpected exception: '||SQLERRM);
  END;

  -- ───── TC4: NULL window = no restriction (fail-open) ─────
  -- Clear the window for TOPUP, post a "very old" topup, expect reversal to succeed.
  UPDATE wlt_tran_def SET reversal_window_hours = NULL WHERE tran_type = 'TOPUP';
  PERFORM post_topup(a1, 80000, 'WIN-T4', '{}'::jsonb, 'BANK', 't');
  UPDATE wlt_api_message
     SET processed_at = clock_timestamp() - interval '720 hours'  -- 30 days
   WHERE object_ref_id = 'WIN-T4' AND object_subject = 'TOPUP';
  BEGIN
    SELECT reversal_tran_key, was_already_reversed
      INTO v_rev, v_already
      FROM post_topup_reversal('WIN-T4', 'no window', 'OPS_MANUAL', 'SYS', 't');
    INSERT INTO _t(name,ok,detail) VALUES
      ('TC4 NULL window = fail-open (reversal succeeds regardless of age)',
       v_already = false AND v_rev IS NOT NULL,
       format('rev_tran=%s was_already=%s', v_rev, v_already));
  EXCEPTION WHEN others THEN
    INSERT INTO _t(name,ok,detail) VALUES
      ('TC4 NULL window = fail-open (reversal succeeds regardless of age)',
       false, 'unexpected exception: '||SQLERRM);
  END;
  -- Restore the seeded window before the ROLLBACK so the assertion message is
  -- accurate even if a future test reads this state mid-TX.
  UPDATE wlt_tran_def SET reversal_window_hours = 168 WHERE tran_type = 'TOPUP';

  -- ───── TC5: TRANSFER reversal honours the same window ─────
  PERFORM post_transfer(a1, a2, 50000, 'WIN-X1', 'TRFOUT', '{}'::jsonb, 'MOBILE', 't');
  UPDATE wlt_api_message
     SET processed_at = clock_timestamp() - interval '169 hours'
   WHERE object_ref_id = 'WIN-X1' AND object_subject = 'TRANSFER';
  BEGIN
    PERFORM post_transfer_reversal('WIN-X1', 'too late', 'OPS_MANUAL', 'SYS', 't');
    INSERT INTO _t(name,ok,detail) VALUES
      ('TC5 transfer reversal outside window rejected with P0060',
       false, 'no exception raised');
  EXCEPTION WHEN sqlstate 'P0060' THEN
    INSERT INTO _t(name,ok,detail) VALUES
      ('TC5 transfer reversal outside window rejected with P0060',
       SQLERRM LIKE 'REVERSAL_WINDOW_EXPIRED:%', SQLERRM);
  WHEN others THEN
    INSERT INTO _t(name,ok,detail) VALUES
      ('TC5 transfer reversal outside window rejected with P0060',
       false, 'wrong sqlstate: '||SQLERRM);
  END;
END $$;

SELECT lpad(id::text,2) AS "#", CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, name, detail FROM _t ORDER BY id;
SELECT count(*) AS total, count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed FROM _t;
ROLLBACK;
