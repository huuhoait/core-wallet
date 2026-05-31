-- =============================================================================
-- wallet_activate_hotwallet_test.sql — activate_hot_wallet() functional tests
-- =============================================================================
-- Self-contained, ends with ROLLBACK (zero pollution).
--
-- Covers promotion of a COLD merchant group (shard_count = 0, settlement only)
-- to a HOT wallet (N empty SHARD sub-accounts):
--   • happy path: N shards created (index 0..N-1, balance 0), shard_count flipped,
--     settlement balance untouched (no funds move), shard_acct_nos returned
--   • INVALID_SHARD_COUNT (P0052) — count not in {4,8,16}
--   • GROUP_ALREADY_ACTIVATED (P0053) — re-activating a hot group
--   • GROUP_NOT_FOUND (P0050) — unknown group
--   • SETTLEMENT_NOT_FOUND (P0054) — group has no settlement account
-- =============================================================================

BEGIN;

CREATE TEMP TABLE _t (id serial, name text, ok boolean, detail text) ON COMMIT DROP;

-- Helper: create a COLD merchant group (shard_count 0) + its SETTLEMENT account.
-- settlement_acct_no FK is DEFERRABLE → group can be inserted before the acct.
CREATE FUNCTION pg_temp._mk_cold(p_grp text, p_set_acct text, p_settle numeric)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE v_c text;
BEGIN
  v_c := fn_create_client('Merchant '||p_grp, '8882'||lpad((random()*1e8)::int::text,8,'0'),
                          '0882'||lpad((random()*1e6)::int::text,6,'0'), NULL, 'MER','3');
  INSERT INTO WLT_ACCT_GROUP(group_id, client_no, group_type, shard_count,
                             settlement_acct_no, shard_threshold, shard_buffer,
                             sweep_interval_sec, group_status)
    VALUES (p_grp, v_c, 'MERCHANT', 0, p_set_acct, 50000000, 10000000, 60, 'A');
  INSERT INTO WLT_ACCT(acct_no, client_no, acct_type, ccy, acct_status,
                       actual_bal, prev_day_actual_bal, acct_role, group_id)
    VALUES (p_set_acct, v_c, 'MERCHANT','VND','A', p_settle, p_settle, 'SETTLEMENT', p_grp);
  RETURN v_c;
END $$;

DO $$
DECLARE
  v_rec      record;
  v_cnt      int;
  v_idx      int[];
  v_zero     boolean;
  v_sc       smallint;
  v_set_bal  numeric;
  v_tot      numeric;
  v_ok       boolean;
  v_acct     text;
  v_acct2    text;
  v_distinct int;
  v_inherit  boolean;
BEGIN
  PERFORM set_config('audit.actor','test',true);
  PERFORM set_config('audit.channel','TEST',true);

  -- ════════ setup: cold group A (settlement 5,000,000, 0 shards) ════════
  PERFORM pg_temp._mk_cold('HWACTV01', 'HWACTV01SET', 5000000);

  -- ════════ TC1: activate(4) returns 4 shard accounts + shard_count 4 ════════
  SELECT * INTO v_rec FROM activate_hot_wallet('HWACTV01', 4::smallint, 'OPS', 'tester');
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC1 activate(4) returns shard_count=4 + 4 acct_nos',
     v_rec.shard_count = 4 AND array_length(v_rec.shard_acct_nos,1) = 4
       AND v_rec.settlement_acct_no = 'HWACTV01SET',
     format('shard_count=%s n_accts=%s settle=%s', v_rec.shard_count,
            array_length(v_rec.shard_acct_nos,1), v_rec.settlement_acct_no));

  -- ════════ TC2: 4 SHARD rows, index 0..3, all balance 0, status A ════════
  SELECT count(*), array_agg(shard_index ORDER BY shard_index), bool_and(actual_bal = 0 AND acct_status='A')
    INTO v_cnt, v_idx, v_zero
    FROM WLT_ACCT WHERE group_id='HWACTV01' AND acct_role='SHARD';
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC2 4 SHARD accts, shard_index 0..3, balance 0',
     v_cnt = 4 AND v_idx = ARRAY[0,1,2,3] AND v_zero,
     format('count=%s idx=%s all_zero_active=%s', v_cnt, v_idx, v_zero));

  -- ════════ TC3: group.shard_count flipped 0 → 4 ════════
  SELECT shard_count INTO v_sc FROM WLT_ACCT_GROUP WHERE group_id='HWACTV01';
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC3 WLT_ACCT_GROUP.shard_count flipped to 4', v_sc = 4, format('shard_count=%s', v_sc));

  -- ════════ TC4: no funds moved — settlement balance + group total unchanged ════════
  SELECT settlement_bal, total_balance INTO v_set_bal, v_tot
    FROM v_wlt_group_balance WHERE group_id='HWACTV01';
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC4 settlement balance untouched, total = settlement (shards empty)',
     v_set_bal = 5000000 AND v_tot = 5000000,
     format('settlement=%s total=%s (expect 5000000/5000000)', v_set_bal, v_tot));

  -- ════════ TC5: re-activating a HOT group → GROUP_ALREADY_ACTIVATED (P0053) ════════
  BEGIN
    PERFORM activate_hot_wallet('HWACTV01', 8::smallint);
    v_ok := false;
  EXCEPTION WHEN SQLSTATE 'P0053' THEN v_ok := true;
  END;
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC5 re-activate hot group raises GROUP_ALREADY_ACTIVATED', v_ok, 'P0053 expected');

  -- ════════ TC6: invalid shard count (5) → INVALID_SHARD_COUNT (P0052), group stays cold ════════
  PERFORM pg_temp._mk_cold('HWACTV02', 'HWACTV02SET', 1000000);
  BEGIN
    PERFORM activate_hot_wallet('HWACTV02', 5::smallint);
    v_ok := false;
  EXCEPTION WHEN SQLSTATE 'P0052' THEN v_ok := true;
  END;
  SELECT count(*) INTO v_cnt FROM WLT_ACCT WHERE group_id='HWACTV02' AND acct_role='SHARD';
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC6 shard_count=5 raises INVALID_SHARD_COUNT, no shards created',
     v_ok AND v_cnt = 0, format('raised=%s shards=%s', v_ok, v_cnt));

  -- ════════ TC7: unknown group → GROUP_NOT_FOUND (P0050) ════════
  BEGIN
    PERFORM activate_hot_wallet('HWNOPE', 4::smallint);
    v_ok := false;
  EXCEPTION WHEN SQLSTATE 'P0050' THEN v_ok := true;
  END;
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC7 unknown group raises GROUP_NOT_FOUND', v_ok, 'P0050 expected');

  -- ════════ TC8: group without a SETTLEMENT account → SETTLEMENT_NOT_FOUND (P0054) ════════
  -- Insert a cold group pointing at a ghost settlement acct that is never created;
  -- the DEFERRABLE FK is only checked at COMMIT, and this test ROLLBACKs.
  INSERT INTO WLT_ACCT_GROUP(group_id, client_no, group_type, shard_count,
                             settlement_acct_no, shard_threshold, shard_buffer,
                             sweep_interval_sec, group_status)
    VALUES ('HWNOSET', (SELECT client_no FROM WLT_ACCT_GROUP WHERE group_id='HWACTV01'),
            'MERCHANT', 0, 'HWNOSET_GHOST', 50000000, 10000000, 60, 'A');
  BEGIN
    PERFORM activate_hot_wallet('HWNOSET', 4::smallint);
    v_ok := false;
  EXCEPTION WHEN SQLSTATE 'P0054' THEN v_ok := true;
  END;
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC8 group without settlement raises SETTLEMENT_NOT_FOUND', v_ok, 'P0054 expected');

  -- ════════ TC9: activate(8) → 8 shards, index 0..7 ════════
  PERFORM pg_temp._mk_cold('HWACTV03', 'HWACTV03SET', 2000000);
  SELECT * INTO v_rec FROM activate_hot_wallet('HWACTV03', 8::smallint);
  SELECT count(*), array_agg(shard_index ORDER BY shard_index) INTO v_cnt, v_idx
    FROM WLT_ACCT WHERE group_id='HWACTV03' AND acct_role='SHARD';
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC9 activate(8) creates 8 shards, index 0..7',
     v_rec.shard_count = 8 AND v_cnt = 8 AND v_idx = ARRAY[0,1,2,3,4,5,6,7],
     format('shard_count=%s count=%s idx=%s', v_rec.shard_count, v_cnt, v_idx));

  -- ════════ TC10: activate(16) → 16 shards ════════
  PERFORM pg_temp._mk_cold('HWACTV04', 'HWACTV04SET', 3000000);
  SELECT * INTO v_rec FROM activate_hot_wallet('HWACTV04', 16::smallint);
  SELECT count(*) INTO v_cnt FROM WLT_ACCT WHERE group_id='HWACTV04' AND acct_role='SHARD';
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC10 activate(16) creates 16 shards',
     v_rec.shard_count = 16 AND v_cnt = 16 AND array_length(v_rec.shard_acct_nos,1) = 16,
     format('shard_count=%s count=%s', v_rec.shard_count, v_cnt));

  -- ════════ TC11: fn_resolve_shard_acct_no routes onto the new shards (HWACTV01, 4 shards) ════════
  v_acct  := fn_resolve_shard_acct_no('HWACTV01', 'PAY-REF-001');
  v_acct2 := fn_resolve_shard_acct_no('HWACTV01', 'PAY-REF-001'); -- deterministic: same ref → same shard
  SELECT count(DISTINCT fn_resolve_shard_acct_no('HWACTV01', 'R'||g))
    INTO v_distinct FROM generate_series(1,200) g;               -- spread across shards
  SELECT bool_and(EXISTS (SELECT 1 FROM WLT_ACCT a
                           WHERE a.acct_no = fn_resolve_shard_acct_no('HWACTV01','Q'||g)
                             AND a.group_id='HWACTV01' AND a.acct_role='SHARD'))
    INTO v_ok FROM generate_series(1,50) g;                       -- every hit is an in-group SHARD
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC11 fn_resolve_shard_acct_no: deterministic, in-group, distributed',
     v_acct = v_acct2 AND v_ok AND v_distinct > 1,
     format('same_ref_stable=%s all_in_group=%s distinct_shards=%s/4', v_acct = v_acct2, v_ok, v_distinct));

  -- ════════ TC12: shards inherit settlement client_no + ccy + acct_type ════════
  SELECT bool_and(s.client_no = g.client_no AND s.ccy = 'VND' AND s.acct_type = 'MERCHANT')
    INTO v_inherit
    FROM WLT_ACCT s
    JOIN WLT_ACCT_GROUP g ON g.group_id = s.group_id
   WHERE s.group_id = 'HWACTV01' AND s.acct_role = 'SHARD';
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC12 shards inherit settlement client_no/ccy/acct_type', v_inherit,
     'all 4 shards match settlement client_no + VND + MERCHANT');
END $$;

SELECT lpad(id::text,2) AS "#", CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, name, detail
FROM _t ORDER BY id;
SELECT count(*) AS total, count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed FROM _t;

ROLLBACK;
