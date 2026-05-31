-- =============================================================================
-- wallet_merchant_hotwallet_test.sql — Merchant hot-wallet (sub-account shard) tests
-- =============================================================================
-- Self-contained, ends with ROLLBACK (zero pollution).
--
-- SCOPE NOTE: the merchant posting SPs (post_merchant_withdraw, sweep SWEEPO/
-- SWEEPI, fn_resolve_shard_acct_no) are NOT YET IMPLEMENTED in wallet_sp.sql —
-- only the schema is in place. These tests therefore cover what IS implemented:
--   • v_wlt_group_balance aggregation (settlement + Σ shards)
--   • group-level available balance under restraint
--   • structural constraints: one SETTLEMENT per group, unique shard_index,
--     ACCT_ROLE/group_id/shard_index consistency
--   • MERCHWD/FEEMW/SWEEPO/SWEEPI tran-type GL wiring
--   • sweep money-conservation invariant (simulated shard→settlement move)
-- Functional MERCHWD/sweep flows are pending SP implementation (see TODO at end).
-- =============================================================================

BEGIN;

CREATE TEMP TABLE _t (id serial, name text, ok boolean, detail text) ON COMMIT DROP;

DO $$
DECLARE
  v_mc   text;
  v_grp  text := 'GRPHOTTEST';
  v_set_k bigint;
  i int;
  v_set_bal numeric; v_sh_tot numeric; v_tot numeric; v_shards int;
  v_avail numeric; v_set_avail numeric;
  v_merch record;
BEGIN
  PERFORM set_config('audit.actor','test',true);
  PERFORM set_config('audit.channel','TEST',true);

  -- ── setup: 1 merchant group = 1 SETTLEMENT (1,000,000) + 4 SHARD (500,000 each)
  v_mc := fn_create_client('Merchant Hot','888000009001','0888009001','m@hot.test','ORG','3');

  -- group first (settlement_acct_no FK is DEFERRABLE → fine before the acct exists)
  INSERT INTO WLT_ACCT_GROUP
    (group_id, client_no, group_type, shard_count, settlement_acct_no,
     shard_threshold, shard_buffer, sweep_interval_sec, group_status)
  VALUES
    (v_grp, v_mc, 'MERCHANT', 8, '97019000000001', 50000000, 10000000, 60, 'A');
  -- shard_count is the CONFIGURED count (must be 0/4/8/16); we materialise 4
  -- physical shards for the test → active_shards = 4.

  INSERT INTO WLT_ACCT
    (acct_no, client_no, acct_type, ccy, acct_status, actual_bal, prev_day_actual_bal, acct_role, group_id)
  VALUES
    ('97019000000001', v_mc, 'MERCHANT','VND','A', 1000000, 1000000, 'SETTLEMENT', v_grp)
  RETURNING internal_key INTO v_set_k;

  FOR i IN 0..3 LOOP
    INSERT INTO WLT_ACCT
      (acct_no, client_no, acct_type, ccy, acct_status, actual_bal, prev_day_actual_bal, acct_role, group_id, shard_index)
    VALUES
      ('9701900001000'||i, v_mc, 'MERCHANT','VND','A', 500000, 500000, 'SHARD', v_grp, i);
  END LOOP;

  -- ════════════════ TC1: aggregation view ════════════════
  SELECT settlement_bal, shards_total, total_balance, active_shards
    INTO v_set_bal, v_sh_tot, v_tot, v_shards
    FROM v_wlt_group_balance WHERE group_id = v_grp;
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC1 group aggregate: settlement + Σshards = total',
     v_set_bal=1000000 AND v_sh_tot=2000000 AND v_tot=3000000 AND v_shards=4,
     format('settlement=%s shards=%s total=%s active_shards=%s', v_set_bal, v_sh_tot, v_tot, v_shards));

  -- ════════════════ TC2: group available reflects restraint ════════════════
  UPDATE WLT_ACCT SET total_restrained_amt = 200000, restraint_present = 'Y'
   WHERE internal_key = v_set_k;
  SELECT total_available, settlement_available
    INTO v_avail, v_set_avail
    FROM v_wlt_group_balance WHERE group_id = v_grp;
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC2 group available = total − restraint',
     v_avail=2800000 AND v_set_avail=800000,
     format('total_available=%s (expect 2800000) settlement_available=%s (expect 800000)', v_avail, v_set_avail));

  -- ════════════════ TC3: only ONE settlement per group (uk_acct_settlement) ════════════════
  BEGIN
    INSERT INTO WLT_ACCT (acct_no, client_no, acct_type, ccy, acct_status, actual_bal, prev_day_actual_bal, acct_role, group_id)
    VALUES ('97019000000099', v_mc, 'MERCHANT','VND','A', 0, 0, 'SETTLEMENT', v_grp);
    INSERT INTO _t(name,ok,detail) VALUES ('TC3 reject 2nd SETTLEMENT per group', false, 'NO violation raised');
  EXCEPTION WHEN unique_violation THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC3 reject 2nd SETTLEMENT per group', true, 'uk_acct_settlement enforced');
  WHEN others THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC3 reject 2nd SETTLEMENT per group', false, 'wrong error: '||SQLERRM);
  END;

  -- ════════════════ TC4: unique shard_index per group (uk_acct_shard) ════════════════
  BEGIN
    INSERT INTO WLT_ACCT (acct_no, client_no, acct_type, ccy, acct_status, actual_bal, prev_day_actual_bal, acct_role, group_id, shard_index)
    VALUES ('97019000000098', v_mc, 'MERCHANT','VND','A', 0, 0, 'SHARD', v_grp, 0);
    INSERT INTO _t(name,ok,detail) VALUES ('TC4 reject duplicate shard_index', false, 'NO violation raised');
  EXCEPTION WHEN unique_violation THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC4 reject duplicate shard_index', true, 'uk_acct_shard enforced');
  WHEN others THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC4 reject duplicate shard_index', false, 'wrong error: '||SQLERRM);
  END;

  -- ════════════════ TC5: ACCT_ROLE consistency check (SHARD must have shard_index) ════════════════
  BEGIN
    INSERT INTO WLT_ACCT (acct_no, client_no, acct_type, ccy, acct_status, actual_bal, prev_day_actual_bal, acct_role, group_id, shard_index)
    VALUES ('97019000000097', v_mc, 'MERCHANT','VND','A', 0, 0, 'SHARD', v_grp, NULL);
    INSERT INTO _t(name,ok,detail) VALUES ('TC5 reject SHARD with NULL shard_index', false, 'NO violation raised');
  EXCEPTION WHEN check_violation THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC5 reject SHARD with NULL shard_index', true, 'role/group/shard_index check enforced');
  WHEN others THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC5 reject SHARD with NULL shard_index', false, 'wrong error: '||SQLERRM);
  END;

  -- ════════════════ TC6: merchant tran-type GL wiring ════════════════
  SELECT * INTO v_merch FROM WLT_TRAN_DEF WHERE TRAN_TYPE='MERCHWD';
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC6 MERCHWD wiring (PERCENT, contra nostro, fee→401.02, FEEMW)',
     v_merch.FEE_TYPE='PERCENT' AND v_merch.CONTRA_GL_CODE='101.02.001'
       AND v_merch.FEE_GL_CODE='401.02' AND v_merch.FEE_TRAN_TYPE='FEEMW'
       AND v_merch.CR_DR_MAINT_IND='DR',
     format('fee=%s contra=%s fee_gl=%s fee_tt=%s', v_merch.FEE_TYPE, v_merch.CONTRA_GL_CODE, v_merch.FEE_GL_CODE, v_merch.FEE_TRAN_TYPE));

  INSERT INTO _t(name,ok,detail)
  SELECT 'TC7 SWEEPO/SWEEPI are GL-neutral internal moves (no fee/contra)',
         bool_and(FEE_TYPE='NONE' AND CONTRA_GL_CODE IS NULL),
         string_agg(TRAN_TYPE||':'||CR_DR_MAINT_IND, ', ')
  FROM WLT_TRAN_DEF WHERE TRAN_TYPE IN ('SWEEPO','SWEEPI');

  -- ════════════════ TC8: sweep conserves group total (simulated shard→settlement) ════════════════
  -- Simulates SWEEPO(shard) + SWEEPI(settlement): move 300,000 from shard#0 to settlement.
  UPDATE WLT_ACCT SET actual_bal = actual_bal - 300000 WHERE group_id=v_grp AND acct_role='SHARD' AND shard_index=0;
  UPDATE WLT_ACCT SET actual_bal = actual_bal + 300000 WHERE internal_key=v_set_k;
  SELECT total_balance INTO v_tot FROM v_wlt_group_balance WHERE group_id=v_grp;
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC8 sweep conserves group total (shard→settlement)',
     v_tot=3000000, format('total after sweep=%s (expect 3000000 unchanged)', v_tot));
END $$;

SELECT lpad(id::text,2) AS "#", CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, name, detail
FROM _t ORDER BY id;
SELECT count(*) AS total, count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed FROM _t;

ROLLBACK;

-- =============================================================================
-- TODO (pending SP implementation — cannot be functionally tested yet):
--   • post_merchant_withdraw(group_id, amount, ...) — withdraw from settlement,
--     MERCHWD + FEEMW legs, urgent sweep on shortfall (finance_transaction.md §4.8)
--   • sweep SPs (SWEEPO/SWEEPI) — rebalance shard ↔ settlement
--   • fn_resolve_shard_acct_no(group_id) — deposit shard routing (DEP-08/09/10)
-- Add functional test cases here once those SPs land.
-- =============================================================================
