-- =============================================================================
-- wallet_fee_charge_test.sql — standalone fee charge + reversal (US-2.8)
-- =============================================================================
-- Self-contained, ends with ROLLBACK (zero pollution). Covers:
--   • post_fee_charge: DR wallet liability (gross) / CR fee revenue (net) /
--     CR VAT payable (vat), VAT-inclusive; 1 FEECHG TRAN_HIST leg
--   • idempotency (DUPLICATE), insufficient funds (P0026), invalid amount (P0010),
--     unknown account (P0021)
--   • revenue GL resolved per acct_type via WLT_GL_MAP (consumer 401.01 / merchant 401.02)
--   • post_fee_charge_reversal: refund gross, idempotent, unknown orig → P0040
-- =============================================================================

BEGIN;

SET app.pii_dek = 'dev-test-pii-dek-do-not-use-in-prod';

CREATE TEMP TABLE _t (id serial, name text, ok boolean, detail text) ON COMMIT DROP;

DO $$
DECLARE
  v_c      text;
  v_cm     text;
  v_acct   text;
  v_macct  text;
  v_key    bigint;
  v_rec    record;
  v_rev    record;
  v_ok     boolean;
  v_bal    numeric;
  v_dr     numeric;
  v_cr     numeric;
  v_liab   numeric;
  v_revnet numeric;
  v_vat    numeric;
  v_mgl    text;
BEGIN
  PERFORM set_config('audit.actor','test',true);
  PERFORM set_config('audit.channel','TEST',true);

  -- consumer wallet funded with 1,000,000
  v_c    := fn_create_client('Fee Consumer','8884'||lpad((random()*1e8)::int::text,8,'0'),
                             '0884'||lpad((random()*1e6)::int::text,6,'0'), NULL, 'IND','3');
  SELECT acct_no INTO v_acct FROM open_account(v_c, 'CONSUMER', 'VND', 'test');
  PERFORM post_topup(v_acct, 1000000, 'FEE-FUND-'||v_acct, '{}'::jsonb, 'TREASURY', 'test');

  -- ──── TC1: charge 50,000 → SUCCESS, gross/vat split, balance −50,000 ────
  SELECT * INTO v_rec FROM post_fee_charge(v_acct, 50000, 'FEE-CHG-0001', 'FEECHG', 'Annual fee', '{}'::jsonb, 'OPS', 'test');
  SELECT actual_bal INTO v_bal FROM WLT_ACCT WHERE acct_no = v_acct;
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC1 charge 50000 → SUCCESS, bal 1,000,000→950,000',
     v_rec.status = 'SUCCESS' AND v_rec.fee_gross = 50000 AND v_bal = 950000,
     format('status=%s gross=%s bal=%s', v_rec.status, v_rec.fee_gross, v_bal));

  -- ──── TC2: VAT-inclusive split vat=4545.45, net=45454.55 ────
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC2 VAT-inclusive split (10%): vat=4545.45',
     v_rec.vat_amount = 4545.45,
     format('vat=%s (net=%s)', v_rec.vat_amount, 50000 - v_rec.vat_amount));

  -- ──── TC3: GL balanced — DR liability 50000 / CR revenue 45454.55 / CR VAT 4545.45 ────
  SELECT sum(amount) FILTER (WHERE tran_nature='DR'),
         sum(amount) FILTER (WHERE tran_nature='CR'),
         sum(amount) FILTER (WHERE gl_code='201.01.001'),
         sum(amount) FILTER (WHERE gl_code='401.01'),
         sum(amount) FILTER (WHERE gl_code='203.01')
    INTO v_dr, v_cr, v_liab, v_revnet, v_vat
    FROM WLT_GL_BATCH WHERE reference = 'FEE-CHG-0001';
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC3 GL balanced: DR liab 50000 / CR rev 45454.55 / CR VAT 4545.45',
     v_dr = 50000 AND v_cr = 50000 AND v_liab = 50000 AND v_revnet = 45454.55 AND v_vat = 4545.45,
     format('DR=%s CR=%s liab=%s rev=%s vat=%s', v_dr, v_cr, v_liab, v_revnet, v_vat));

  -- ──── TC4: exactly one FEECHG TRAN_HIST leg (VAT is GL-only) ────
  SELECT count(*) = 1 AND bool_and(cr_dr_maint_ind='DR' AND tran_amt=50000)
    INTO v_ok FROM WLT_TRAN_HIST WHERE reference = 'FEE-CHG-0001' AND tran_type = 'FEECHG';
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC4 single FEECHG DR leg (no separate VAT leg)', v_ok, '1 leg, DR, 50000');

  -- ──── TC5: idempotent — same reference → DUPLICATE, no double charge ────
  SELECT * INTO v_rec FROM post_fee_charge(v_acct, 50000, 'FEE-CHG-0001', 'FEECHG', 'Annual fee', '{}'::jsonb, 'OPS', 'test');
  SELECT actual_bal INTO v_bal FROM WLT_ACCT WHERE acct_no = v_acct;
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC5 duplicate ref → DUPLICATE, bal still 950,000',
     v_rec.status = 'DUPLICATE' AND v_bal = 950000, format('status=%s bal=%s', v_rec.status, v_bal));

  -- ──── TC6: insufficient funds → P0026 ────
  BEGIN
    PERFORM post_fee_charge(v_acct, 999999999, 'FEE-CHG-BIG', 'FEECHG', NULL, '{}'::jsonb, 'OPS', 'test');
    v_ok := false;
  EXCEPTION WHEN SQLSTATE 'P0026' THEN v_ok := true; END;
  INSERT INTO _t(name,ok,detail) VALUES ('TC6 fee > balance → P0026', v_ok, 'INSUFFICIENT_FUNDS');

  -- ──── TC7: invalid amount (0) → P0010 ────
  BEGIN
    PERFORM post_fee_charge(v_acct, 0, 'FEE-CHG-ZERO', 'FEECHG', NULL, '{}'::jsonb, 'OPS', 'test');
    v_ok := false;
  EXCEPTION WHEN SQLSTATE 'P0010' THEN v_ok := true; END;
  INSERT INTO _t(name,ok,detail) VALUES ('TC7 amount 0 → P0010', v_ok, 'INVALID_AMOUNT');

  -- ──── TC8: unknown account → P0021 ────
  BEGIN
    PERFORM post_fee_charge('97019999999999', 1000, 'FEE-CHG-NOACCT', 'FEECHG', NULL, '{}'::jsonb, 'OPS', 'test');
    v_ok := false;
  EXCEPTION WHEN SQLSTATE 'P0021' THEN v_ok := true; END;
  INSERT INTO _t(name,ok,detail) VALUES ('TC8 unknown account → P0021', v_ok, 'ACCT_NOT_FOUND');

  -- ──── TC9: merchant fee books revenue to 401.02 (gl_map FEE_CR) ────
  v_cm    := fn_create_client('Fee Merchant','8885'||lpad((random()*1e8)::int::text,8,'0'),
                              '0885'||lpad((random()*1e6)::int::text,6,'0'), NULL, 'MER','3');
  SELECT acct_no INTO v_macct FROM open_account(v_cm, 'MERCHANT', 'VND', 'test');
  PERFORM post_topup(v_macct, 500000, 'FEE-MFUND-'||v_macct, '{}'::jsonb, 'TREASURY', 'test');
  PERFORM post_fee_charge(v_macct, 20000, 'FEE-MCHG-0001', 'FEECHG', NULL, '{}'::jsonb, 'OPS', 'test');
  SELECT gl_code INTO v_mgl FROM WLT_GL_BATCH WHERE reference='FEE-MCHG-0001' AND tran_nature='CR' AND gl_code LIKE '401%';
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC9 merchant fee revenue → 401.02 (per acct_type)', v_mgl = '401.02', format('revenue gl=%s', v_mgl));

  -- ──── TC10: reverse the consumer fee → refund 50,000, bal back to 1,000,000 ────
  SELECT * INTO v_rev FROM post_fee_charge_reversal('FEE-CHG-0001', 'duplicate charge', 'OPS_MANUAL', 'SYS', 'test');
  SELECT actual_bal INTO v_bal FROM WLT_ACCT WHERE acct_no = v_acct;
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC10 reverse fee → refund 50000, bal 950,000→1,000,000',
     v_rev.was_already_reversed = false AND v_bal = 1000000, format('reversed=%s bal=%s', v_rev.was_already_reversed, v_bal));

  -- ──── TC11: reversal GL balanced (CR liability 50000 / DR rev / DR VAT) ────
  SELECT sum(amount) FILTER (WHERE tran_nature='DR'), sum(amount) FILTER (WHERE tran_nature='CR')
    INTO v_dr, v_cr FROM WLT_GL_BATCH WHERE reference = 'RVFC-FEE-CHG-0001';
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC11 reversal GL balanced DR=CR=50000', v_dr = 50000 AND v_cr = 50000, format('DR=%s CR=%s', v_dr, v_cr));

  -- ──── TC12: reversal idempotent — second call → was_already_reversed, no double refund ────
  SELECT * INTO v_rev FROM post_fee_charge_reversal('FEE-CHG-0001', 'duplicate charge', 'OPS_MANUAL', 'SYS', 'test');
  SELECT actual_bal INTO v_bal FROM WLT_ACCT WHERE acct_no = v_acct;
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC12 reverse again → already_reversed, bal still 1,000,000',
     v_rev.was_already_reversed = true AND v_bal = 1000000, format('already=%s bal=%s', v_rev.was_already_reversed, v_bal));

  -- ──── TC13: reverse a non-existent fee → P0040 ────
  BEGIN
    PERFORM post_fee_charge_reversal('NO-SUCH-FEE-REF', 'x', 'OPS_MANUAL', 'SYS', 'test');
    v_ok := false;
  EXCEPTION WHEN SQLSTATE 'P0040' THEN v_ok := true; END;
  INSERT INTO _t(name,ok,detail) VALUES ('TC13 reverse unknown fee → P0040', v_ok, 'TRAN_NOT_FOUND');
END $$;

SELECT lpad(id::text,2) AS "#", CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, name, detail
FROM _t ORDER BY id;
SELECT count(*) AS total, count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed FROM _t;

ROLLBACK;
