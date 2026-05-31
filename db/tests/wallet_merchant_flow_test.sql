-- =============================================================================
-- wallet_merchant_flow_test.sql — Functional tests for merchant hot-wallet SPs
-- =============================================================================
-- Covers: fn_resolve_shard_acct_no · post_sweep_shard · post_merchant_withdraw
-- (settlement-sufficient, auto-sweep, sweep-required, insufficient, idempotency).
-- Self-contained, ends with ROLLBACK (zero pollution).
-- =============================================================================

BEGIN;

CREATE TEMP TABLE _t (id serial, name text, ok boolean, detail text) ON COMMIT DROP;

-- helper: build a merchant group (settlement + N shards). Returns group_id.
CREATE FUNCTION pg_temp._mk(p_sfx text, p_settle numeric, p_shard numeric, p_n int, p_buf numeric)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE v_c text; v_g text := 'GF'||p_sfx; i int;
BEGIN
  PERFORM set_config('audit.actor','test',true); PERFORM set_config('audit.channel','TEST',true);
  v_c := fn_create_client('Merchant '||p_sfx, '8881'||lpad(p_sfx,8,'0'), '0881'||lpad(p_sfx,6,'0'), NULL, 'ORG','3');
  INSERT INTO WLT_ACCT_GROUP(group_id,client_no,group_type,shard_count,settlement_acct_no,shard_threshold,shard_buffer,sweep_interval_sec,group_status)
    VALUES (v_g, v_c, 'MERCHANT', 8, 'MCH'||p_sfx||'S', 50000000, p_buf, 60, 'A');
  INSERT INTO WLT_ACCT(acct_no,client_no,acct_type,ccy,acct_status,actual_bal,prev_day_actual_bal,acct_role,group_id)
    VALUES ('MCH'||p_sfx||'S', v_c, 'MERCHANT','VND','A',p_settle,p_settle,'SETTLEMENT',v_g);
  FOR i IN 0..p_n-1 LOOP
    INSERT INTO WLT_ACCT(acct_no,client_no,acct_type,ccy,acct_status,actual_bal,prev_day_actual_bal,acct_role,group_id,shard_index)
      VALUES ('MCH'||p_sfx||'H'||i, v_c, 'MERCHANT','VND','A',p_shard,p_shard,'SHARD',v_g,i);
  END LOOP;
  RETURN v_g;
END $$;

DO $$
DECLARE
  GA text; GB text; GC text; GD text;
  v_s1 text; v_s2 text; v_swept numeric; v_setbal numeric; v_tot numeric;
  v_tfr bigint; v_st text; v_fee numeric; v_vat numeric; v_dr numeric; v_cr numeric;
  v_nostro numeric; v_net numeric; v_setafter numeric; v_logcnt int;
  v_st2 text; v_idem_tfr bigint; v_setbal_dup numeric;
  v_setpre numeric; v_revtfr bigint; v_already boolean; v_already2 boolean;
  v_revdr numeric; v_revcr numeric; v_setpost numeric;
BEGIN
  GA := pg_temp._mk('01', 2000000, 500000, 4, 0);     -- settlement 2M + 4×500k = 4M
  GB := pg_temp._mk('02',  100000,1000000, 4, 0);     -- settlement 100k + 4×1M = 4.1M (needs sweep)
  GC := pg_temp._mk('03',   50000,  50000, 2, 0);     -- group total 150k (insufficient)
  GD := pg_temp._mk('04',  100000,1000000, 4, 0);     -- for sweep-required (auto_sweep=false)

  -- ───── TC1: fn_resolve_shard_acct_no deterministic ─────
  v_s1 := fn_resolve_shard_acct_no(GA, 'REF-XYZ');
  v_s2 := fn_resolve_shard_acct_no(GA, 'REF-XYZ');
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC1 resolve_shard deterministic (same ref → same shard)',
     v_s1=v_s2 AND v_s1 LIKE 'MCH01H%', format('s1=%s s2=%s', v_s1, v_s2));

  -- ───── TC2: post_sweep_shard URGENT conserves group total ─────
  SELECT total_balance INTO v_tot FROM v_wlt_group_balance WHERE group_id=GA;   -- 4,000,000
  SELECT swept_amount, settlement_bal_after INTO v_swept, v_setbal
    FROM post_sweep_shard('MCH01H0','URGENT','test');
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC2 sweep URGENT: swept=500k, settlement+500k, group total conserved',
     v_swept=500000 AND v_setbal=2500000
       AND (SELECT total_balance FROM v_wlt_group_balance WHERE group_id=GA)=v_tot
       AND (SELECT status FROM wlt_sweep_log WHERE group_id=GA AND shard_acct_no='MCH01H0')='SUCCESS',
     format('swept=%s settlement=%s group_total=%s', v_swept, v_setbal, v_tot));

  -- ───── TC3: merchant_withdraw settlement-sufficient → POSTED ─────
  SELECT tran_internal_id, status, fee_gross, vat_amount, settlement_balance_after
    INTO v_tfr, v_st, v_fee, v_vat, v_setafter
    FROM post_merchant_withdraw(GA, 1000000, 'MWD-GA-1', 'PAYOUT-GA-1', true, 'MOBILE', 'test');
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC3 merchant_withdraw POSTED (settlement sufficient)',
     v_st='SUCCESS' AND v_fee=22000 AND v_setafter=(2500000-1022000),
     format('status=%s fee=%s settle_after=%s', v_st, v_fee, v_setafter));

  -- ───── TC4: MERCHWD GL balanced + fee split (401.02/203.01) ─────
  SELECT sum(amount) FILTER (WHERE tran_nature='DR'), sum(amount) FILTER (WHERE tran_nature='CR')
    INTO v_dr, v_cr FROM wlt_gl_batch WHERE tran_key=v_tfr;
  SELECT amount INTO v_nostro FROM wlt_gl_batch WHERE tran_key=v_tfr AND gl_code='101.02.001' AND tran_nature='CR';
  SELECT amount INTO v_net FROM wlt_gl_batch WHERE tran_key=v_tfr AND gl_code='401.02' AND tran_nature='CR';
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC4 MERCHWD GL balanced + nostro=principal + fee→401.02/203.01',
     v_dr=v_cr AND v_nostro=1000000 AND v_net=20000 AND v_vat=2000,
     format('DR=%s CR=%s nostro=%s feeNet401=%s vat=%s', v_dr, v_cr, v_nostro, v_net, v_vat));

  -- ───── TC5: auto-sweep path (settlement short, group sufficient) → POSTED ─────
  SELECT status, settlement_balance_after INTO v_st, v_setafter
    FROM post_merchant_withdraw(GB, 3000000, 'MWD-GB-1', NULL, true, 'MOBILE', 'test');
  SELECT count(*) INTO v_logcnt FROM wlt_sweep_log WHERE group_id=GB AND trigger_type='URGENT' AND triggered_by='WITHDRAW_TRIGGERED' AND status='SUCCESS';
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC5 auto-sweep then POSTED (settlement was short)',
     v_st='SUCCESS' AND v_logcnt>=1 AND v_setafter=(4100000-3022000),
     format('status=%s urgent_sweeps=%s settle_after=%s', v_st, v_logcnt, v_setafter));

  -- ───── TC6: auto_sweep=false → SETTLEMENT_SWEEP_REQUIRED, no debit ─────
  SELECT actual_bal INTO v_setbal FROM wlt_acct WHERE acct_no='MCH04S';
  SELECT status INTO v_st FROM post_merchant_withdraw(GD, 3000000, 'MWD-GD-1', NULL, false, 'MOBILE', 'test');
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC6 SETTLEMENT_SWEEP_REQUIRED (no auto-sweep, settlement untouched)',
     v_st='SETTLEMENT_SWEEP_REQUIRED' AND (SELECT actual_bal FROM wlt_acct WHERE acct_no='MCH04S')=v_setbal,
     format('status=%s settlement unchanged=%s', v_st, v_setbal));

  -- ───── TC7: group insufficient → INSUFFICIENT_FUNDS ─────
  BEGIN
    PERFORM post_merchant_withdraw(GC, 1000000, 'MWD-GC-1', NULL, true, 'MOBILE', 'test');
    INSERT INTO _t(name,ok,detail) VALUES ('TC7 group insufficient → INSUFFICIENT_FUNDS', false, 'no exception');
  EXCEPTION WHEN sqlstate 'P0026' THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC7 group insufficient → INSUFFICIENT_FUNDS', true, SQLERRM);
  WHEN others THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC7 group insufficient → INSUFFICIENT_FUNDS', false, 'wrong error: '||SQLERRM);
  END;

  -- ───── TC8: idempotency (same reference → DUPLICATE, single debit) ─────
  SELECT tran_internal_id, settlement_balance_after INTO v_idem_tfr, v_setbal
    FROM post_merchant_withdraw(GA, 100000, 'MWD-IDEM-1', NULL, true, 'MOBILE', 'test');
  SELECT status, settlement_balance_after INTO v_st2, v_setbal_dup
    FROM post_merchant_withdraw(GA, 100000, 'MWD-IDEM-1', NULL, true, 'MOBILE', 'test');
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC8 merchant_withdraw idempotent (2nd → DUPLICATE, single debit)',
     v_st2='DUPLICATE' AND v_setbal=v_setbal_dup,
     format('st2=%s bal1=%s bal2=%s', v_st2, v_setbal, v_setbal_dup));

  -- ───── TC9: revert merchant withdraw MWD-GA-1 (restore principal + fee) ─────
  SELECT actual_bal INTO v_setpre FROM wlt_acct WHERE acct_no='MCH01S';
  SELECT reversal_tfr_key, was_already_reversed INTO v_revtfr, v_already
    FROM post_merchant_withdraw_reversal('MWD-GA-1', 'NAPAS_TIMEOUT', 'payout failed', 'TREASURY_FAILED', 'SYS', 'test');
  SELECT actual_bal INTO v_setpost FROM wlt_acct WHERE acct_no='MCH01S';
  SELECT sum(amount) FILTER (WHERE tran_nature='DR'), sum(amount) FILTER (WHERE tran_nature='CR')
    INTO v_revdr, v_revcr FROM wlt_gl_batch WHERE tran_key=v_revtfr;
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC9 revert merchant withdraw: restore principal+fee, GL balanced',
     v_already=false AND v_setpost=(v_setpre+1022000) AND v_revdr=v_revcr AND v_revdr=1022000,
     format('pre=%s post=%s revDR=%s revCR=%s', v_setpre, v_setpost, v_revdr, v_revcr));

  -- ───── TC10: revert idempotent (2nd call → already_reversed, no double credit) ─────
  SELECT was_already_reversed INTO v_already2
    FROM post_merchant_withdraw_reversal('MWD-GA-1', 'NAPAS_TIMEOUT', 'retry', 'TREASURY_FAILED', 'SYS', 'test');
  SELECT actual_bal INTO v_setbal FROM wlt_acct WHERE acct_no='MCH01S';
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC10 revert idempotent (no double credit)',
     v_already2=true AND v_setbal=v_setpost,
     format('already2=%s balance=%s (expect %s)', v_already2, v_setbal, v_setpost));
END $$;

SELECT lpad(id::text,2) AS "#", CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, name, detail
FROM _t ORDER BY id;
SELECT count(*) AS total, count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed FROM _t;

ROLLBACK;
