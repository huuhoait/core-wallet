-- =============================================================================
-- wallet_accounting_test.sql — Accounting invariant tests for the posting SPs
-- =============================================================================
-- Self-contained: creates its own clients/wallets, runs each posting op, asserts
-- the GL/accounting invariants, then ROLLS BACK (zero data pollution).
--
-- Run:  docker exec -e PGPASSWORD=$PW wallet-postgres \
--          psql -U postgres -d wallet -f /tmp/wallet_accounting_test.sql
--
-- Invariants covered:
--   double-entry (ΣDR=ΣCR) · fee split (gross=net+VAT, VAT=gross·r/(1+r)) ·
--   correct fee/VAT GL codes · principal nets to 0 on wallet GL · balance
--   conservation · fee leg → origin SEQ_NO (TFR_SEQ_NO) · inline fund guard ·
--   fee-free tran_type (TRFOUTF) · withdraw nostro leg = principal.
-- =============================================================================

BEGIN;

CREATE TEMP TABLE _t (id serial, name text, ok boolean, detail text) ON COMMIT DROP;

DO $$
DECLARE
  v_ca text; v_cb text;
  v_a  text; v_b  text;          -- acct_no
  v_ka bigint; v_kb bigint;      -- internal_key
  v_tfr bigint; v_fee numeric; v_vat numeric;
  v_dr numeric; v_cr numeric;
  v_a0 numeric; v_a1 numeric; v_b0 numeric; v_b1 numeric;
  v_seq_base bigint; v_ref_seq bigint;
  v_net401 numeric; v_vat203 numeric; v_net_wallet numeric;
  v_legs int; v_nostro numeric;
  -- reversal + idempotency
  v_pre numeric; v_postwd numeric; v_postrev numeric;
  v_rev bigint; v_already boolean; v_already2 boolean;
  v_rev_dr numeric; v_rev_cr numeric; v_rvwd numeric; v_rvfee_wallet numeric;
  v_dr401 numeric; v_dr203 numeric;
  v_st1 text; v_st2 text; v_idem1 numeric; v_idem2 numeric;
BEGIN
  -- ── setup: 2 consumer wallets, tier 2 (withdraw needs ≥2), funded 1,000,000
  v_ca := fn_create_client('Acct Test A','888000000001','0888000001','a@acct.test','IND','2');
  v_cb := fn_create_client('Acct Test B','888000000002','0888000002','b@acct.test','IND','2');
  SELECT internal_key, acct_no INTO v_ka, v_a FROM fn_open_wallet(v_ca,'CONSUMER',1000000);
  SELECT internal_key, acct_no INTO v_kb, v_b FROM fn_open_wallet(v_cb,'CONSUMER',1000000);

  -- ════════════════════ TRANSFER WITH FEE (TRFOUT) ════════════════════
  SELECT actual_bal INTO v_a0 FROM wlt_acct WHERE internal_key=v_ka;
  SELECT actual_bal INTO v_b0 FROM wlt_acct WHERE internal_key=v_kb;

  SELECT tran_internal_id, fee_gross, vat_amount INTO v_tfr, v_fee, v_vat
    FROM post_transfer(v_a, v_b, 100000, 'ACCTT-TRF-1', 'TRFOUT', '{}'::jsonb, 'MOBILE', 'test');

  -- TC1: double-entry balanced
  SELECT sum(amount) FILTER (WHERE tran_nature='DR'),
         sum(amount) FILTER (WHERE tran_nature='CR')
    INTO v_dr, v_cr FROM wlt_gl_batch WHERE tran_key=v_tfr;
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC1 transfer: ΣDR = ΣCR', v_dr = v_cr, format('DR=%s CR=%s', v_dr, v_cr));

  -- TC2: fee split + VAT formula (gross 5500 = net 5000 + VAT 500; VAT=round(5500*0.1/1.1))
  SELECT amount INTO v_net401 FROM wlt_gl_batch WHERE tran_key=v_tfr AND gl_code='401.01';
  SELECT amount INTO v_vat203 FROM wlt_gl_batch WHERE tran_key=v_tfr AND gl_code='203.01';
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC2 fee split + VAT GL codes',
     v_fee=5500 AND v_vat=500 AND v_net401=5000 AND v_vat203=500
       AND round(v_fee*0.10/1.10,2)=v_vat,
     format('fee=%s net(401.01)=%s vat(203.01)=%s', v_fee, v_net401, v_vat203));

  -- TC3: principal nets to 0 on wallet GL 201.01.001 → net DR = fee only (5500)
  SELECT sum(CASE tran_nature WHEN 'DR' THEN amount ELSE -amount END)
    INTO v_net_wallet FROM wlt_gl_batch WHERE tran_key=v_tfr AND gl_code='201.01.001';
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC3 principal nets to 0 on 201.01.001 (only fee remains)',
     v_net_wallet = 5500, format('net DR on wallet GL = %s (expect 5500)', v_net_wallet));

  -- TC4: balance conservation (sender -amount-fee, receiver +amount)
  SELECT actual_bal INTO v_a1 FROM wlt_acct WHERE internal_key=v_ka;
  SELECT actual_bal INTO v_b1 FROM wlt_acct WHERE internal_key=v_kb;
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC4 balance conservation',
     (v_a0 - v_a1)=105500 AND (v_b1 - v_b0)=100000,
     format('A:-%s (expect 105500)  B:+%s (expect 100000)', v_a0-v_a1, v_b1-v_b0));

  -- TC5: fee leg references origin (TRFOUT) SEQ_NO via TFR_SEQ_NO
  SELECT seq_no INTO v_seq_base FROM wlt_tran_hist WHERE tran_internal_id=v_tfr AND tran_type='TRFOUT';
  SELECT tfr_seq_no INTO v_ref_seq FROM wlt_tran_hist WHERE tran_internal_id=v_tfr AND tran_type='FEETRF';
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC5 FEE leg TFR_SEQ_NO = origin TRFOUT SEQ_NO',
     v_ref_seq = v_seq_base, format('fee.tfr_seq_no=%s origin.seq_no=%s', v_ref_seq, v_seq_base));

  -- ════════════════════ FEE-FREE TRANSFER (TRFOUTF) ════════════════════
  SELECT tran_internal_id, fee_gross INTO v_tfr, v_fee
    FROM post_transfer(v_a, v_b, 10000, 'ACCTT-FREE-1', 'TRFOUTF', '{}'::jsonb, 'MOBILE', 'test');
  SELECT count(*) INTO v_legs FROM wlt_gl_batch WHERE tran_key=v_tfr;
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC6 TRFOUTF: no fee, only 2 GL legs, no 401/203',
     v_fee=0 AND v_legs=2
       AND NOT EXISTS(SELECT 1 FROM wlt_gl_batch WHERE tran_key=v_tfr AND gl_code IN ('401.01','203.01')),
     format('fee=%s legs=%s', v_fee, v_legs));

  -- ════════════════════ TRANSFER FUND GUARD ════════════════════
  BEGIN
    PERFORM post_transfer(v_a, v_b, 50000000, 'ACCTT-OVER-1', 'TRFOUT', '{}'::jsonb, 'MOBILE', 'test');
    INSERT INTO _t(name,ok,detail) VALUES ('TC7 transfer fund guard (amount+fee>balance)', false, 'NO exception raised');
  EXCEPTION
    WHEN sqlstate 'P0026' THEN
      INSERT INTO _t(name,ok,detail) VALUES ('TC7 transfer fund guard (amount+fee>balance)', true, SQLERRM);
    WHEN others THEN
      INSERT INTO _t(name,ok,detail) VALUES ('TC7 transfer fund guard (amount+fee>balance)', false, 'wrong error: '||SQLERRM);
  END;

  -- ════════════════════ WITHDRAW WITH FEE ════════════════════
  SELECT tran_internal_id, fee_gross, vat_amount INTO v_tfr, v_fee, v_vat
    FROM post_withdraw(v_a, 200000, 'ACCTT-WD-1', 'EXTWD-T1', 'BIDV', '12345678901234', '{}'::jsonb, 'MOBILE', 'test');

  -- TC8: withdraw double-entry
  SELECT sum(amount) FILTER (WHERE tran_nature='DR'),
         sum(amount) FILTER (WHERE tran_nature='CR')
    INTO v_dr, v_cr FROM wlt_gl_batch WHERE tran_key=v_tfr;
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC8 withdraw: ΣDR = ΣCR', v_dr=v_cr, format('DR=%s CR=%s', v_dr, v_cr));

  -- TC9: nostro CR leg = principal (escrow reduced by exactly the principal)
  SELECT amount INTO v_nostro FROM wlt_gl_batch
    WHERE tran_key=v_tfr AND gl_code='101.02.001' AND tran_nature='CR';
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC9 withdraw nostro CR = principal (200000)',
     v_nostro=200000, format('nostro CR=%s (expect 200000)', v_nostro));

  -- TC10: withdraw fee split (PERCENT 0.1% clamp min 11000 → 11000; net 10000 + VAT 1000)
  SELECT amount INTO v_net401 FROM wlt_gl_batch WHERE tran_key=v_tfr AND gl_code='401.01';
  SELECT amount INTO v_vat203 FROM wlt_gl_batch WHERE tran_key=v_tfr AND gl_code='203.01';
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC10 withdraw fee clamp + split',
     v_fee=11000 AND v_net401=10000 AND v_vat203=1000,
     format('fee=%s net=%s vat=%s', v_fee, v_net401, v_vat203));

  -- TC11: FEEWD leg references origin WDRAW SEQ_NO
  SELECT seq_no INTO v_seq_base FROM wlt_tran_hist WHERE tran_internal_id=v_tfr AND tran_type='WDRAW';
  SELECT tfr_seq_no INTO v_ref_seq FROM wlt_tran_hist WHERE tran_internal_id=v_tfr AND tran_type='FEEWD';
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC11 FEEWD leg TFR_SEQ_NO = origin WDRAW SEQ_NO',
     v_ref_seq = v_seq_base, format('fee.tfr_seq_no=%s origin.seq_no=%s', v_ref_seq, v_seq_base));

  -- ════════════════════ WITHDRAW FUND GUARD ════════════════════
  BEGIN
    PERFORM post_withdraw(v_a, 100000000, 'ACCTT-WDOVER-1', 'EXTWD-OV', 'BIDV', '12345678901234', '{}'::jsonb, 'MOBILE', 'test');
    INSERT INTO _t(name,ok,detail) VALUES ('TC12 withdraw fund guard', false, 'NO exception raised');
  EXCEPTION
    WHEN sqlstate 'P0026' THEN
      INSERT INTO _t(name,ok,detail) VALUES ('TC12 withdraw fund guard', true, SQLERRM);
    WHEN others THEN
      INSERT INTO _t(name,ok,detail) VALUES ('TC12 withdraw fund guard', false, 'wrong error: '||SQLERRM);
  END;

  -- ════════════════════ WITHDRAW REVERSAL (RVWD + RVFEE refund) ════════════════════
  SELECT actual_bal INTO v_pre FROM wlt_acct WHERE internal_key=v_ka;          -- balance before this withdraw
  SELECT tran_internal_id, fee_gross INTO v_tfr, v_fee
    FROM post_withdraw(v_a, 200000, 'ACCTT-WDR-1', 'EXTWD-REV1', 'BIDV', '12345678901234', '{}'::jsonb, 'MOBILE', 'test');
  SELECT actual_bal INTO v_postwd FROM wlt_acct WHERE internal_key=v_ka;        -- pre - (200000 + 11000)

  SELECT reversal_tfr_key, was_already_reversed INTO v_rev, v_already
    FROM post_withdraw_reversal('EXTWD-REV1', 'NAPAS_TIMEOUT', 'beneficiary bank timeout', 'TREASURY_FAILED', 'SYS', 'test');
  SELECT actual_bal INTO v_postrev FROM wlt_acct WHERE internal_key=v_ka;

  -- TC13: reversal restores balance fully (principal + fee returned) and is not a replay
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC13 reversal restores balance (principal+fee)',
     v_already=false AND v_postwd=(v_pre-211000) AND v_postrev=v_pre,
     format('pre=%s afterWD=%s afterREV=%s already=%s', v_pre, v_postwd, v_postrev, v_already));

  -- TC14: reversal GL balanced (ΣDR=ΣCR) and wallet GL net-credited the full 211000
  SELECT sum(amount) FILTER (WHERE tran_nature='DR'),
         sum(amount) FILTER (WHERE tran_nature='CR')
    INTO v_rev_dr, v_rev_cr FROM wlt_gl_batch WHERE tran_key=v_rev;
  SELECT sum(CASE tran_nature WHEN 'CR' THEN amount ELSE -amount END)
    INTO v_net_wallet FROM wlt_gl_batch WHERE tran_key=v_rev AND gl_code='201.01.001';
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC14 reversal GL balanced + wallet credited 211000',
     v_rev_dr=v_rev_cr AND v_net_wallet=211000,
     format('DR=%s CR=%s net_wallet_CR=%s', v_rev_dr, v_rev_cr, v_net_wallet));

  -- TC15: RVFEE refunds the fee — RVWD leg=200000, RVFEE credits wallet 11000,
  --       and revenue(401.01)/VAT(203.01) are reversed via DR legs (10000 / 1000)
  SELECT tran_amt INTO v_rvwd FROM wlt_tran_hist WHERE tran_internal_id=v_rev AND tran_type='RVWD';
  SELECT tran_amt INTO v_rvfee_wallet FROM wlt_tran_hist WHERE tran_internal_id=v_rev AND tran_type='RVFEE';
  SELECT amount INTO v_dr401 FROM wlt_gl_batch WHERE tran_key=v_rev AND gl_code='401.01' AND tran_nature='DR';
  SELECT amount INTO v_dr203 FROM wlt_gl_batch WHERE tran_key=v_rev AND gl_code='203.01' AND tran_nature='DR';
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC15 RVWD/RVFEE refund fee + reverse revenue/VAT',
     v_rvwd=200000 AND v_rvfee_wallet=11000 AND v_dr401=10000 AND v_dr203=1000,
     format('RVWD=%s RVFEE=%s DR401=%s DR203=%s', v_rvwd, v_rvfee_wallet, v_dr401, v_dr203));

  -- TC16: reversal is idempotent — 2nd call flags already_reversed, no double credit
  SELECT was_already_reversed INTO v_already2
    FROM post_withdraw_reversal('EXTWD-REV1', 'NAPAS_TIMEOUT', 'retry', 'TREASURY_FAILED', 'SYS', 'test');
  SELECT actual_bal INTO v_postrev FROM wlt_acct WHERE internal_key=v_ka;
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC16 reversal idempotent (no double credit)',
     v_already2=true AND v_postrev=v_pre,
     format('already2=%s balance=%s (expect %s)', v_already2, v_postrev, v_pre));

  -- ════════════════════ POSTING IDEMPOTENCY (same reference) ════════════════════
  SELECT status, new_balance_from INTO v_st1, v_idem1
    FROM post_transfer(v_a, v_b, 20000, 'ACCTT-IDEM-1', 'TRFOUT', '{}'::jsonb, 'MOBILE', 'test');
  SELECT status INTO v_st2
    FROM post_transfer(v_a, v_b, 20000, 'ACCTT-IDEM-1', 'TRFOUT', '{}'::jsonb, 'MOBILE', 'test');
  SELECT actual_bal INTO v_idem2 FROM wlt_acct WHERE internal_key=v_ka;
  -- TC17: 1st POSTED, 2nd DUPLICATE, balance deducted exactly once (20000+5500)
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC17 idempotency: 2nd same-ref → DUPLICATE, single deduction',
     v_st1='SUCCESS' AND v_st2='DUPLICATE' AND v_idem1=v_idem2,
     format('st1=%s st2=%s bal_after1=%s bal_now=%s', v_st1, v_st2, v_idem1, v_idem2));
END $$;

-- Results
SELECT lpad(id::text,2) AS "#", CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, name, detail
FROM _t ORDER BY id;

SELECT count(*) AS total, count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed
FROM _t;

ROLLBACK;
