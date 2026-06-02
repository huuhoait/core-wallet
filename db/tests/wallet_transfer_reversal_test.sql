-- =============================================================================
-- wallet_transfer_reversal_test.sql — tests for post_transfer_reversal
-- =============================================================================
BEGIN;
CREATE TEMP TABLE _t (id serial, name text, ok boolean, detail text) ON COMMIT DROP;

DO $$
DECLARE
  ca text; cb text; cc text; a text; b text; c text; ka bigint; kb bigint; kc bigint;
  v_rev bigint; v_already boolean; v_already2 boolean; v_nbf numeric; v_nbt numeric;
  v_dr numeric; v_cr numeric; a0 numeric; b0 numeric; a1 numeric; b1 numeric;
BEGIN
  ca := fn_create_client('Rev A','888100000001','0881100001','a@rev.test','IND','2');
  cb := fn_create_client('Rev B','888100000002','0881100002','b@rev.test','IND','2');
  cc := fn_create_client('Rev C','888100000003','0881100003','c@rev.test','IND','2');
  SELECT internal_key, acct_no INTO ka, a FROM fn_open_wallet(ca,'CONSUMER',1000000);
  SELECT internal_key, acct_no INTO kb, b FROM fn_open_wallet(cb,'CONSUMER',1000000);
  SELECT internal_key, acct_no INTO kc, c FROM fn_open_wallet(cc,'CONSUMER',1000000);

  -- ───── TC1: revert a fee transfer restores both wallets, GL balanced ─────
  SELECT actual_bal INTO a0 FROM wlt_acct WHERE internal_key=ka;
  SELECT actual_bal INTO b0 FROM wlt_acct WHERE internal_key=kb;
  PERFORM post_transfer(a, b, 100000, 'RVT-1', 'TRFOUT', '{}'::jsonb, 'MOBILE', 't');  -- A:-105500 B:+100000
  SELECT reversal_tran_key, was_already_reversed, new_balance_from, new_balance_to
    INTO v_rev, v_already, v_nbf, v_nbt
    FROM post_transfer_reversal('RVT-1', 'duplicate charge', 'OPS_MANUAL', 'SYS', 't');
  SELECT actual_bal INTO a1 FROM wlt_acct WHERE internal_key=ka;
  SELECT actual_bal INTO b1 FROM wlt_acct WHERE internal_key=kb;
  SELECT sum(amount) FILTER (WHERE tran_nature='DR'), sum(amount) FILTER (WHERE tran_nature='CR')
    INTO v_dr, v_cr FROM wlt_gl_batch WHERE tran_key=v_rev;
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC1 transfer revert restores A(+amt+fee) & B(−amt), GL balanced',
     v_already=false AND a1=a0 AND b1=b0 AND v_dr=v_cr AND v_dr=105500,
     format('A %s→%s  B %s→%s  revDR=%s revCR=%s', a0, a1, b0, b1, v_dr, v_cr));

  -- ───── TC2: revert idempotent ─────
  SELECT was_already_reversed INTO v_already2
    FROM post_transfer_reversal('RVT-1', 'retry', 'OPS_MANUAL', 'SYS', 't');
  SELECT actual_bal INTO a1 FROM wlt_acct WHERE internal_key=ka;
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC2 transfer revert idempotent (no double effect)',
     v_already2=true AND a1=a0, format('already2=%s A=%s', v_already2, a1));

  -- ───── TC3: claw-back blocked when receiver spent the funds ─────
  PERFORM post_transfer(a, b, 200000, 'RVT-3', 'TRFOUT', '{}'::jsonb, 'MOBILE', 't');  -- B:+200000
  PERFORM post_transfer(b, c, 1150000, 'RVT-3B', 'TRFOUT', '{}'::jsonb, 'MOBILE', 't'); -- B drains below 200000
  BEGIN
    PERFORM post_transfer_reversal('RVT-3', 'fraud', 'OPS_MANUAL', 'SYS', 't');
    INSERT INTO _t(name,ok,detail) VALUES ('TC3 claw-back blocked when receiver insufficient', false, 'no exception');
  EXCEPTION WHEN sqlstate 'P0026' THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC3 claw-back blocked when receiver insufficient', true, SQLERRM);
  WHEN others THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC3 claw-back blocked when receiver insufficient', false, 'wrong error: '||SQLERRM);
  END;
END $$;

SELECT lpad(id::text,2) AS "#", CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, name, detail FROM _t ORDER BY id;
SELECT count(*) AS total, count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed FROM _t;
ROLLBACK;
