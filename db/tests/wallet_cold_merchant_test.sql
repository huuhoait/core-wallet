-- =============================================================================
-- wallet_cold_merchant_test.sql — a COLD merchant (0 shards) must not affect
-- accounting integrity or normal STANDALONE wallets
-- =============================================================================
-- Self-contained, ends with ROLLBACK (zero pollution).
--
-- A merchant group created cold (SHARD_COUNT = 0, settlement only) is just
-- config + one SETTLEMENT account. It must be fully isolated from:
--   • normal STANDALONE wallet posting (topup / transfer)
--   • the GL double-entry invariant (every WLT_GL_BATCH tran_key: ΣDR = ΣCR)
-- and the shard-routing path must correctly refuse (no shards to route to),
-- so nothing can post into a non-existent shard.
-- =============================================================================

BEGIN;

CREATE TEMP TABLE _t (id serial, name text, ok boolean, detail text) ON COMMIT DROP;

DO $$
DECLARE
  v_cc     text;    -- consumer client
  v_mc     text;    -- merchant client
  v_a      text;    -- consumer wallet A acct_no
  v_akey   bigint;
  v_b      text;    -- consumer wallet B acct_no
  v_bkey   bigint;
  v_bal    numeric;
  v_balB   numeric;
  v_gl_ok  boolean;
  v_sh_tot numeric; v_active int; v_tot numeric;
  v_ok     boolean;
BEGIN
  PERFORM set_config('audit.actor','test',true);
  PERFORM set_config('audit.channel','TEST',true);

  -- ════════ setup: a COLD merchant group (settlement 5,000,000, 0 shards) ════════
  v_mc := fn_create_client('Cold Merchant','888300000001','0883000001',NULL,'MER','3');
  INSERT INTO WLT_ACCT_GROUP(group_id,client_no,group_type,shard_count,
                             settlement_acct_no,shard_threshold,shard_buffer,
                             sweep_interval_sec,group_status)
    VALUES ('CMG01', v_mc, 'MERCHANT', 0, 'CMG01SET', 50000000, 10000000, 60, 'A');
  INSERT INTO WLT_ACCT(acct_no,client_no,acct_type,ccy,acct_status,
                       actual_bal,prev_day_actual_bal,acct_role,group_id)
    VALUES ('CMG01SET', v_mc, 'MERCHANT','VND','A', 5000000, 5000000, 'SETTLEMENT','CMG01');

  -- ════════ setup: two normal STANDALONE consumer wallets ════════
  v_cc := fn_create_client('Consumer One','888300000002','0883000002','c1@test','IND','3');
  SELECT internal_key, acct_no INTO v_akey, v_a FROM fn_open_wallet(v_cc, 'CONSUMER', 1000000);
  SELECT internal_key, acct_no INTO v_bkey, v_b FROM fn_open_wallet(v_cc, 'CONSUMER', 0);

  -- ════════ TC1: consumer topup works normally while the cold merchant exists ════════
  SELECT actual_bal INTO v_bal FROM WLT_ACCT WHERE acct_no = v_a;
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC1 STANDALONE wallet funded normally (cold merchant present)',
     v_bal = 1000000, format('A balance=%s (expect 1000000)', v_bal));

  -- ════════ TC2: consumer→consumer transfer credits receiver in full ════════
  PERFORM post_transfer(v_a, v_b, 300000, 'CMT-TRAN-1', 'TRFOUT', '{}'::jsonb, 'MOBILE', 'test');
  SELECT actual_bal INTO v_balB FROM WLT_ACCT WHERE acct_no = v_b;
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC2 consumer→consumer transfer credits receiver',
     v_balB = 300000, format('B balance=%s (expect 300000)', v_balB));

  -- ════════ TC3: GL double-entry stays balanced (ΣDR = ΣCR per tran_key) ════════
  SELECT bool_and(dr = cr) INTO v_gl_ok FROM (
    SELECT tran_key,
           COALESCE(sum(amount) FILTER (WHERE tran_nature='DR'),0) AS dr,
           COALESCE(sum(amount) FILTER (WHERE tran_nature='CR'),0) AS cr
      FROM WLT_GL_BATCH GROUP BY tran_key) x;
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC3 GL double-entry balanced (ΣDR=ΣCR per tran)', v_gl_ok,
     'every WLT_GL_BATCH tran_key balances despite cold merchant');

  -- ════════ TC4: cold merchant shard routing refuses (no active shards) ════════
  BEGIN
    PERFORM fn_resolve_shard_acct_no('CMG01', 'X-REF');
    v_ok := false;
  EXCEPTION WHEN SQLSTATE 'P0050' THEN v_ok := true;
  END;
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC4 cold merchant shard routing unavailable (GROUP_NOT_FOUND)', v_ok,
     'P0050 expected — callers route to settlement until activated');

  -- ════════ TC5: group-balance view degrades cleanly for a 0-shard group ════════
  SELECT shards_total, active_shards, total_balance INTO v_sh_tot, v_active, v_tot
    FROM v_wlt_group_balance WHERE group_id='CMG01';
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC5 cold group aggregate: shards_total=0, active_shards=0, total=settlement',
     v_sh_tot = 0 AND v_active = 0 AND v_tot = 5000000,
     format('shards_total=%s active=%s total=%s', v_sh_tot, v_active, v_tot));

  -- ════════ TC6: settlement is NOT a normal wallet — consumer topup rejected ════════
  BEGIN
    PERFORM post_topup('CMG01SET', 100000, 'CMT-BADTOPUP', '{}'::jsonb, 'TREASURY', 'test');
    v_ok := false;
  EXCEPTION WHEN SQLSTATE 'P0028' THEN v_ok := true;
  END;
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC6 settlement rejects consumer topup (ACCT_ROLE_INVALID)', v_ok, 'P0028 expected');

  -- ════════ TC7: cold merchant settlement balance is untouched by consumer flow ════════
  SELECT actual_bal INTO v_bal FROM WLT_ACCT WHERE acct_no = 'CMG01SET';
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC7 merchant settlement isolated from consumer postings',
     v_bal = 5000000, format('settlement balance=%s (expect 5000000 unchanged)', v_bal));
END $$;

SELECT lpad(id::text,2) AS "#", CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, name, detail
FROM _t ORDER BY id;
SELECT count(*) AS total, count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed FROM _t;

ROLLBACK;
