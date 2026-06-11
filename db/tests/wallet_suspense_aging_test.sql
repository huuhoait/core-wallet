-- =============================================================================
-- wallet_suspense_aging_test.sql — suspense/clearing aging report (US-6.2)
-- =============================================================================
-- Deterministic, fully transactional (BEGIN .. ROLLBACK). Seeds clearing/
-- suspense (109.x) GL legs of varying age and asserts fn_suspense_aging buckets
-- the signed net (ΣCR−ΣDR) by post_date age correctly.
--
-- The companion eod_sweep_unidentified_receipts procedure COMMITs (it advances
-- WLT_EOD_RUN), so — like the other EOD procedures — it cannot run inside this
-- rollback-scoped suite; it is exercised separately (see CHANGELOG / smoke).
-- =============================================================================
BEGIN;
CREATE TEMP TABLE _t (id serial, name text, ok boolean, detail text) ON COMMIT DROP;

DO $$
DECLARE
  v_net  numeric; v_b030 numeric; v_b6190 numeric; v_b90 numeric;
  v_cnt  integer;
BEGIN
  -- Seed balanced entries (DR cash 101.01.001 / CR suspense) of varying age:
  --   109.04.002 unidentified: 5,000 aged (D-100) + 3,000 recent (D-10) → net 8,000
  --   109.01.001 cash-in clearing: 1,000 (D-75) → net 1,000 in the 61-90 bucket
  INSERT INTO wlt_gl_batch(tran_key,seq_no,gl_code,amount,tran_nature,ccy,reference,post_date,value_date,accounting_date,status,source_module) VALUES
    (-8101,1,'101.01.001',5000,'DR','VND','SUSP-T-A',CURRENT_DATE-100,CURRENT_DATE-100,CURRENT_DATE-100,'S','TEST'),
    (-8101,2,'109.04.002',5000,'CR','VND','SUSP-T-A',CURRENT_DATE-100,CURRENT_DATE-100,CURRENT_DATE-100,'S','TEST'),
    (-8102,1,'101.01.001',3000,'DR','VND','SUSP-T-B',CURRENT_DATE-10, CURRENT_DATE-10, CURRENT_DATE-10, 'S','TEST'),
    (-8102,2,'109.04.002',3000,'CR','VND','SUSP-T-B',CURRENT_DATE-10, CURRENT_DATE-10, CURRENT_DATE-10, 'S','TEST'),
    (-8103,1,'101.01.001',1000,'DR','VND','SUSP-T-C',CURRENT_DATE-75, CURRENT_DATE-75, CURRENT_DATE-75, 'S','TEST'),
    (-8103,2,'109.01.001',1000,'CR','VND','SUSP-T-C',CURRENT_DATE-75, CURRENT_DATE-75, CURRENT_DATE-75, 'S','TEST');

  -- TC1: 109.04.002 net + age split (recent 3,000 in 0-30, aged 5,000 in 90+)
  SELECT net_balance, bucket_0_30, bucket_90_plus
    INTO v_net, v_b030, v_b90
    FROM fn_suspense_aging(CURRENT_DATE) WHERE gl_code='109.04.002';
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC1 109.04.002 net=8000, 0-30=3000, 90+=5000',
     v_net=8000 AND v_b030=3000 AND v_b90=5000,
     format('net=%s b0_30=%s b90=%s', v_net, v_b030, v_b90));

  -- TC2: 109.01.001 net 1,000 lands in the 61-90 bucket (D-75)
  SELECT net_balance, bucket_61_90 INTO v_net, v_b6190
    FROM fn_suspense_aging(CURRENT_DATE) WHERE gl_code='109.01.001';
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC2 109.01.001 net=1000 in 61-90 bucket', v_net=1000 AND v_b6190=1000,
     format('net=%s b61_90=%s', v_net, v_b6190));

  -- TC3: as_of BEFORE the legs → nothing reported (post_date > as_of filtered out)
  SELECT count(*) INTO v_cnt FROM fn_suspense_aging(CURRENT_DATE-200);
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC3 as_of before any leg → 0 rows', v_cnt=0, format('rows=%s', v_cnt));

  -- TC4: a fully-cleared GL (equal DR+CR) nets to 0 → excluded (HAVING net<>0)
  INSERT INTO wlt_gl_batch(tran_key,seq_no,gl_code,amount,tran_nature,ccy,reference,post_date,value_date,accounting_date,status,source_module) VALUES
    (-8104,1,'109.02.001',2000,'CR','VND','SUSP-T-D',CURRENT_DATE-5,CURRENT_DATE-5,CURRENT_DATE-5,'S','TEST'),
    (-8104,2,'109.02.001',2000,'DR','VND','SUSP-T-D',CURRENT_DATE-5,CURRENT_DATE-5,CURRENT_DATE-5,'S','TEST');
  SELECT count(*) INTO v_cnt FROM fn_suspense_aging(CURRENT_DATE) WHERE gl_code='109.02.001';
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC4 net-zero GL excluded from report', v_cnt=0, format('rows=%s', v_cnt));
END $$;

SELECT lpad(id::text,2) AS "#", CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, name, detail
FROM _t ORDER BY id;
SELECT count(*) AS total, count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed FROM _t;

DO $$
DECLARE v_fail int;
BEGIN
  SELECT count(*) INTO v_fail FROM _t WHERE NOT ok;
  IF v_fail > 0 THEN RAISE EXCEPTION 'wallet_suspense_aging_test: % assertion(s) FAILED', v_fail; END IF;
END $$;

ROLLBACK;
