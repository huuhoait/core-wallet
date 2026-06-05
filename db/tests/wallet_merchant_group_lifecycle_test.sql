-- =============================================================================
-- wallet_merchant_group_lifecycle_test.sql — provision / deposit-routing /
-- rescale functional tests (US-1.10, US-1.11, US-1.12)
-- =============================================================================
-- Self-contained, ends with ROLLBACK (zero pollution). Covers the full merchant
-- group lifecycle that sits around activate_hot_wallet (US-1.9):
--   • provision_acct_group   (US-1.10): group row + SETTLEMENT account in one TX
--   • post_merchant_deposit  (US-1.11): route deposit → settlement (cold) | shard (hot)
--   • rescale_hot_wallet      (US-1.12): grow 4→8 + rebalance shards to settlement
-- Error paths: P0056 dup group, P0055 bad type, P0073 bad client, P0050 unknown
-- group on deposit, P0052 non-increasing rescale, P0057 rescale of a cold group.
-- =============================================================================

BEGIN;

-- fn_create_client encrypts PII, so a DEK must be present (normally set via
-- ALTER DATABASE … SET app.pii_dek=…). Session-scope it here for a self-contained
-- run; the TX rolls back so nothing persists.
SET app.pii_dek = 'dev-test-pii-dek-do-not-use-in-prod';

CREATE TEMP TABLE _t (id serial, name text, ok boolean, detail text) ON COMMIT DROP;

DO $$
DECLARE
  v_c            text;
  v_rec          record;
  v_dep          record;
  v_dep2         record;
  v_set          text;
  v_ok           boolean;
  v_cnt          int;
  v_idx          int[];
  v_bal          numeric;
  v_gl_dr        numeric;
  v_gl_cr        numeric;
  v_total_before numeric;
  v_total_after  numeric;
BEGIN
  PERFORM set_config('audit.actor','test',true);
  PERFORM set_config('audit.channel','TEST',true);

  v_c := fn_create_client('Merchant MGL','8883'||lpad((random()*1e8)::int::text,8,'0'),
                          '0883'||lpad((random()*1e6)::int::text,6,'0'), NULL, 'MER','3');

  -- ════════════════════ US-1.10: provision_acct_group ════════════════════
  -- ──── TC1: provision returns the group + its settlement account ────
  SELECT * INTO v_rec FROM provision_acct_group(
    v_c, 'MGLC01', 'MERCHANT', 'MERCHANT', 'VND', NULL, NULL, NULL::smallint, 'OPS', 'tester');
  v_set := v_rec.settlement_acct_no;
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC1 provision returns group + settlement acct',
     v_rec.group_id = 'MGLC01' AND v_rec.settlement_acct_no IS NOT NULL
       AND v_rec.settlement_internal_key IS NOT NULL AND v_rec.group_status = 'A',
     format('grp=%s set=%s key=%s status=%s', v_rec.group_id, v_rec.settlement_acct_no,
            v_rec.settlement_internal_key, v_rec.group_status));

  -- ──── TC2: group is COLD (shard_count 0) + settlement account well-formed ────
  SELECT (g.shard_count = 0) AND (a.acct_role = 'SETTLEMENT') AND (a.group_id = 'MGLC01')
         AND (a.shard_index IS NULL) AND (a.actual_bal = 0) AND (a.acct_status = 'A')
    INTO v_ok
    FROM WLT_ACCT_GROUP g JOIN WLT_ACCT a ON a.acct_no = g.settlement_acct_no
   WHERE g.group_id = 'MGLC01';
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC2 group cold (0 shards) + settlement role/bal correct', v_ok,
     'shard_count=0, settlement acct_role=SETTLEMENT, shard_index NULL, bal 0');

  -- ──── TC3: duplicate group_id → GROUP_ALREADY_EXISTS (P0056) ────
  BEGIN
    PERFORM provision_acct_group(v_c,'MGLC01','MERCHANT','MERCHANT','VND',NULL,NULL,NULL::smallint,'OPS','tester');
    v_ok := false;
  EXCEPTION WHEN SQLSTATE 'P0056' THEN v_ok := true; END;
  INSERT INTO _t(name,ok,detail) VALUES ('TC3 duplicate group_id → P0056', v_ok, 'GROUP_ALREADY_EXISTS');

  -- ──── TC4: invalid group_type → INVALID_GROUP_TYPE (P0055) ────
  BEGIN
    PERFORM provision_acct_group(v_c,'MGLBAD','WIDGET','MERCHANT','VND',NULL,NULL,NULL::smallint,'OPS','tester');
    v_ok := false;
  EXCEPTION WHEN SQLSTATE 'P0055' THEN v_ok := true; END;
  INSERT INTO _t(name,ok,detail) VALUES ('TC4 invalid group_type → P0055', v_ok, 'INVALID_GROUP_TYPE');

  -- ──── TC5: unknown client → CLIENT_NOT_FOUND (P0073) ────
  BEGIN
    PERFORM provision_acct_group('NO_SUCH_CLIENT','MGLBAD2','MERCHANT','MERCHANT','VND',NULL,NULL,NULL::smallint,'OPS','tester');
    v_ok := false;
  EXCEPTION WHEN SQLSTATE 'P0073' THEN v_ok := true; END;
  INSERT INTO _t(name,ok,detail) VALUES ('TC5 unknown client → P0073', v_ok, 'CLIENT_NOT_FOUND');

  -- ════════════════ US-1.11: post_merchant_deposit (cold) ════════════════
  -- ──── TC6: deposit into a cold group lands on SETTLEMENT (shard_index NULL) ────
  SELECT * INTO v_dep FROM post_merchant_deposit('MGLC01', 100000, 'MGL-DEP-COLD-0001', '{}'::jsonb, 'MOBILE','test');
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC6 cold deposit routes to settlement',
     v_dep.status = 'SUCCESS' AND v_dep.target_acct_no = v_set AND v_dep.shard_index IS NULL,
     format('status=%s target=%s shard_index=%s', v_dep.status, v_dep.target_acct_no, v_dep.shard_index));

  -- ──── TC7: settlement balance credited by the deposit amount ────
  SELECT actual_bal INTO v_bal FROM WLT_ACCT WHERE acct_no = v_set;
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC7 settlement credited 100000', v_bal = 100000, format('settlement bal=%s', v_bal));

  -- ──── TC8: deposit posts balanced double-entry (ΣDR = ΣCR = amount) ────
  SELECT sum(amount) FILTER (WHERE tran_nature='DR'), sum(amount) FILTER (WHERE tran_nature='CR')
    INTO v_gl_dr, v_gl_cr FROM WLT_GL_BATCH WHERE reference = 'MGL-DEP-COLD-0001';
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC8 deposit GL balanced DR=CR=100000', v_gl_dr = 100000 AND v_gl_cr = 100000,
     format('DR=%s CR=%s', v_gl_dr, v_gl_cr));

  -- ──── TC9: idempotent — same reference → DUPLICATE, no double credit ────
  SELECT * INTO v_dep2 FROM post_merchant_deposit('MGLC01', 100000, 'MGL-DEP-COLD-0001', '{}'::jsonb,'MOBILE','test');
  SELECT actual_bal INTO v_bal FROM WLT_ACCT WHERE acct_no = v_set;
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC9 duplicate ref → DUPLICATE, no double credit',
     v_dep2.status = 'DUPLICATE' AND v_bal = 100000, format('status=%s bal=%s', v_dep2.status, v_bal));

  -- ──── TC10: deposit into an unknown group → GROUP_NOT_FOUND (P0050) ────
  BEGIN
    PERFORM post_merchant_deposit('NO_SUCH_GROUP', 100000, 'MGL-DEP-X-0001', '{}'::jsonb,'MOBILE','test');
    v_ok := false;
  EXCEPTION WHEN SQLSTATE 'P0050' THEN v_ok := true; END;
  INSERT INTO _t(name,ok,detail) VALUES ('TC10 deposit unknown group → P0050', v_ok, 'GROUP_NOT_FOUND');

  -- ════════════ US-1.11: deposit routing once HOT (post-activate) ════════════
  PERFORM activate_hot_wallet('MGLC01', 4::smallint, 'OPS', 'tester');

  -- ──── TC11: deposit into a hot group lands on a SHARD (index set, in-group) ────
  SELECT * INTO v_dep FROM post_merchant_deposit('MGLC01', 50000, 'MGL-DEP-HOT-0001', '{}'::jsonb,'MOBILE','test');
  SELECT (a.acct_role = 'SHARD' AND a.group_id = 'MGLC01') INTO v_ok
    FROM WLT_ACCT a WHERE a.acct_no = v_dep.target_acct_no;
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC11 hot deposit routes to a shard',
     v_dep.status = 'SUCCESS' AND v_dep.shard_index IS NOT NULL AND v_ok,
     format('target=%s shard_index=%s', v_dep.target_acct_no, v_dep.shard_index));

  -- ════════════════════ US-1.12: rescale_hot_wallet ════════════════════
  -- seed a couple more shard deposits so there is something to rebalance
  PERFORM post_merchant_deposit('MGLC01', 70000, 'MGL-DEP-HOT-0002', '{}'::jsonb,'MOBILE','test');
  PERFORM post_merchant_deposit('MGLC01', 30000, 'MGL-DEP-HOT-0003', '{}'::jsonb,'MOBILE','test');
  SELECT total_balance INTO v_total_before FROM v_wlt_group_balance WHERE group_id = 'MGLC01';

  -- ──── TC12: rescale 4→8 returns old=4, new=8, 4 added shard accts ────
  SELECT * INTO v_rec FROM rescale_hot_wallet('MGLC01', 8::smallint, 'OPS', 'tester');
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC12 rescale 4→8 returns 4 new shards',
     v_rec.old_shard_count = 4 AND v_rec.new_shard_count = 8
       AND array_length(v_rec.added_acct_nos,1) = 4,
     format('old=%s new=%s added=%s rebalanced=%s', v_rec.old_shard_count, v_rec.new_shard_count,
            array_length(v_rec.added_acct_nos,1), v_rec.rebalanced_amount));

  -- ──── TC13: group now has 8 active shards, contiguous index 0..7 ────
  SELECT count(*), array_agg(shard_index ORDER BY shard_index) INTO v_cnt, v_idx
    FROM WLT_ACCT WHERE group_id = 'MGLC01' AND acct_role = 'SHARD' AND acct_status = 'A';
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC13 8 shards, index 0..7', v_cnt = 8 AND v_idx = ARRAY[0,1,2,3,4,5,6,7],
     format('count=%s idx=%s', v_cnt, v_idx));

  -- ──── TC14: rebalance drained shards to 0; group total conserved ────
  SELECT total_balance INTO v_total_after FROM v_wlt_group_balance WHERE group_id = 'MGLC01';
  SELECT bool_and(actual_bal = 0) INTO v_ok
    FROM WLT_ACCT WHERE group_id = 'MGLC01' AND acct_role = 'SHARD' AND acct_status = 'A';
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC14 rescale drains shards to 0, total conserved',
     v_ok AND v_total_after = v_total_before,
     format('all_shards_zero=%s total %s→%s', v_ok, v_total_before, v_total_after));

  -- ──── TC15: configured shard_count flipped to 8 ────
  SELECT shard_count INTO v_cnt FROM WLT_ACCT_GROUP WHERE group_id = 'MGLC01';
  INSERT INTO _t(name,ok,detail) VALUES ('TC15 group shard_count=8', v_cnt = 8, format('shard_count=%s', v_cnt));

  -- ──── TC16: non-increasing rescale (8→8) → INVALID_SHARD_COUNT (P0052) ────
  BEGIN
    PERFORM rescale_hot_wallet('MGLC01', 8::smallint, 'OPS', 'tester');
    v_ok := false;
  EXCEPTION WHEN SQLSTATE 'P0052' THEN v_ok := true; END;
  INSERT INTO _t(name,ok,detail) VALUES ('TC16 rescale 8→8 (not larger) → P0052', v_ok, 'INVALID_SHARD_COUNT');

  -- ──── TC17: rescaling a COLD group → GROUP_NOT_ACTIVATED (P0057) ────
  PERFORM provision_acct_group(v_c,'MGLC02','MERCHANT','MERCHANT','VND',NULL,NULL,NULL::smallint,'OPS','tester');
  BEGIN
    PERFORM rescale_hot_wallet('MGLC02', 8::smallint, 'OPS', 'tester');
    v_ok := false;
  EXCEPTION WHEN SQLSTATE 'P0057' THEN v_ok := true; END;
  INSERT INTO _t(name,ok,detail) VALUES ('TC17 rescale cold group → P0057', v_ok, 'GROUP_NOT_ACTIVATED');
END $$;

SELECT lpad(id::text,2) AS "#", CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, name, detail
FROM _t ORDER BY id;
SELECT count(*) AS total, count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed FROM _t;

ROLLBACK;
