-- =============================================================================
-- wallet_restraint_test.sql — Restraint (hold/lien) lifecycle + enforcement tests
-- =============================================================================
-- Self-contained: creates its own clients/wallets, exercises add_restraint /
-- release_restraint and the posting-path enforcement that rests on them, then
-- ROLLS BACK (zero data pollution). Mirrors wallet_accounting_test.sql harness.
--
-- Run:  docker compose exec -T postgres psql -U postgres -d wallet \
--          -v ON_ERROR_STOP=1 -f /dev/stdin < db/tests/wallet_restraint_test.sql
--
-- Covered (wallet_sp_restraint.sql + enforcement in wallet_sp.sql):
--   add_restraint   · rollup of all 4 types (DEBIT/CREDIT/ALL/INFO) onto WLT_ACCT
--                     (TOTAL_RESTRAINED_AMT, CR_BLOCKED, RESTRAINT_PRESENT, VERSION)
--                   · validation errors P0060–P0064, P0001, P0004
--   enforcement     · DEBIT/PLEDGE>0 shrinks CALC_BAL → withdraw P0026 / still posts within
--                     · DEBIT full block (PLEDGED=0) → withdraw P0025
--                     · CREDIT block → topup P0029
--   release_restraint · restores aggregates · frees funds · errors P0065–P0067
--                     · multi-restraint recompute from remaining ACTIVE rows
-- =============================================================================

BEGIN;

CREATE TEMP TABLE _t (id serial, name text, ok boolean, detail text) ON COMMIT DROP;

DO $$
DECLARE
  v_c   text;
  -- one wallet per scenario (restraints accumulate within the TX, so isolate)
  w_deb text; w_cre text; w_inf text; w_all text; w_clo text;
  w_cal text; w_blk text; w_crb text; w_rel text; w_crt text; w_mul text;
  -- add_restraint return + account snapshot
  v_rid bigint; v_rid1 bigint; v_rid2 bigint;
  v_st  text;   v_pl numeric; v_avail numeric; v_ver int; v_ver0 int;
  v_actual numeric; v_calc numeric; v_tra numeric;
  v_present varchar(4); v_crblk varchar(1);
  -- posting probes
  v_wd_st text; v_wd_bal numeric;
BEGIN
  -- ── setup: a funded (1,000,000) tier-2 consumer wallet per scenario ──
  v_c := fn_create_client('Rstr Deb','889500000001','0889500001','deb@rstr.test','IND','2');
  SELECT acct_no INTO w_deb FROM fn_open_wallet(v_c,'CONSUMER',1000000);
  v_c := fn_create_client('Rstr Cre','889500000002','0889500002','cre@rstr.test','IND','2');
  SELECT acct_no INTO w_cre FROM fn_open_wallet(v_c,'CONSUMER',1000000);
  v_c := fn_create_client('Rstr Inf','889500000003','0889500003','inf@rstr.test','IND','2');
  SELECT acct_no INTO w_inf FROM fn_open_wallet(v_c,'CONSUMER',1000000);
  v_c := fn_create_client('Rstr All','889500000004','0889500004','all@rstr.test','IND','2');
  SELECT acct_no INTO w_all FROM fn_open_wallet(v_c,'CONSUMER',1000000);
  v_c := fn_create_client('Rstr Clo','889500000005','0889500005','clo@rstr.test','IND','2');
  SELECT acct_no INTO w_clo FROM fn_open_wallet(v_c,'CONSUMER',1000000);
  v_c := fn_create_client('Rstr Cal','889500000006','0889500006','cal@rstr.test','IND','2');
  SELECT acct_no INTO w_cal FROM fn_open_wallet(v_c,'CONSUMER',1000000);
  v_c := fn_create_client('Rstr Blk','889500000007','0889500007','blk@rstr.test','IND','2');
  SELECT acct_no INTO w_blk FROM fn_open_wallet(v_c,'CONSUMER',1000000);
  v_c := fn_create_client('Rstr Crb','889500000008','0889500008','crb@rstr.test','IND','2');
  SELECT acct_no INTO w_crb FROM fn_open_wallet(v_c,'CONSUMER',1000000);
  v_c := fn_create_client('Rstr Rel','889500000009','0889500009','rel@rstr.test','IND','2');
  SELECT acct_no INTO w_rel FROM fn_open_wallet(v_c,'CONSUMER',1000000);
  v_c := fn_create_client('Rstr Crt','889500000010','0889500010','crt@rstr.test','IND','2');
  SELECT acct_no INTO w_crt FROM fn_open_wallet(v_c,'CONSUMER',1000000);
  v_c := fn_create_client('Rstr Mul','889500000011','0889500011','mul@rstr.test','IND','2');
  SELECT acct_no INTO w_mul FROM fn_open_wallet(v_c,'CONSUMER',1000000);

  -- ════════════════════ ADD: rollup per restraint type ════════════════════

  -- TC1: DEBIT/PLEDGE reserves funds → available = actual − pledged, version bumps
  SELECT version INTO v_ver0 FROM wlt_acct WHERE acct_no=w_deb;
  SELECT restraint_id, status, pledged_amt, available_bal_after, version
    INTO v_rid, v_st, v_pl, v_avail, v_ver
    FROM add_restraint(w_deb,'DEBIT','PLEDGE',300000,CURRENT_DATE,NULL,'pledge 300k',NULL,'TEST');
  SELECT total_restrained_amt, calc_bal, restraint_present, cr_blocked
    INTO v_tra, v_calc, v_present, v_crblk FROM wlt_acct WHERE acct_no=w_deb;
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC1 DEBIT/PLEDGE reserves funds (available=actual−pledged, version++)',
     v_st='A' AND v_pl=300000 AND v_avail=700000
       AND v_tra=300000 AND v_calc=700000 AND v_present='Y' AND v_crblk='N'
       AND v_ver=v_ver0+1,
     format('avail=%s restrained=%s calc=%s present=%s crblk=%s ver=%s→%s',
            v_avail, v_tra, v_calc, v_present, v_crblk, v_ver0, v_ver));

  -- TC2: CREDIT sets CR_BLOCKED only — reserves nothing, available unchanged
  SELECT status, pledged_amt, available_bal_after
    INTO v_st, v_pl, v_avail
    FROM add_restraint(w_cre,'CREDIT','AML_HOLD',0,CURRENT_DATE,NULL,'aml',NULL,'TEST');
  SELECT total_restrained_amt, restraint_present, cr_blocked
    INTO v_tra, v_present, v_crblk FROM wlt_acct WHERE acct_no=w_cre;
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC2 CREDIT blocks credit only (CR_BLOCKED=Y, no funds reserved)',
     v_st='A' AND v_avail=1000000 AND v_tra=0 AND v_crblk='Y' AND v_present='Y',
     format('avail=%s restrained=%s crblk=%s present=%s', v_avail, v_tra, v_crblk, v_present));

  -- TC3: INFO never reserves — pledged forced to 0 even when a value is passed
  SELECT pledged_amt, available_bal_after
    INTO v_pl, v_avail
    FROM add_restraint(w_inf,'INFO','KYC_REVIEW',999999,CURRENT_DATE,NULL,'info',NULL,'TEST');
  SELECT total_restrained_amt, restraint_present, cr_blocked
    INTO v_tra, v_present, v_crblk FROM wlt_acct WHERE acct_no=w_inf;
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC3 INFO never reserves (pledged forced 0, available unchanged)',
     v_pl=0 AND v_avail=1000000 AND v_tra=0 AND v_crblk='N' AND v_present='Y',
     format('pledged=%s avail=%s restrained=%s crblk=%s', v_pl, v_avail, v_tra, v_crblk));

  -- TC4: ALL/COURT_ORDER both reserves funds AND blocks credit
  SELECT pledged_amt, available_bal_after
    INTO v_pl, v_avail
    FROM add_restraint(w_all,'ALL','COURT_ORDER',200000,CURRENT_DATE,NULL,'court',NULL,'TEST');
  SELECT total_restrained_amt, restraint_present, cr_blocked
    INTO v_tra, v_present, v_crblk FROM wlt_acct WHERE acct_no=w_all;
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC4 ALL/COURT_ORDER reserves + blocks (restrained+pledged, CR_BLOCKED=Y)',
     v_pl=200000 AND v_avail=800000 AND v_tra=200000 AND v_crblk='Y' AND v_present='Y',
     format('avail=%s restrained=%s crblk=%s', v_avail, v_tra, v_crblk));

  -- ════════════════════ ADD: validation errors ════════════════════

  -- TC5: invalid type → P0060
  BEGIN
    PERFORM add_restraint(w_deb,'FOO','PLEDGE',0,CURRENT_DATE,NULL,NULL,NULL,'TEST');
    INSERT INTO _t(name,ok,detail) VALUES ('TC5 invalid type → P0060', false, 'NO exception');
  EXCEPTION WHEN sqlstate 'P0060' THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC5 invalid type → P0060', true, SQLERRM);
  WHEN others THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC5 invalid type → P0060', false, 'wrong: '||SQLERRM);
  END;

  -- TC6: invalid purpose → P0061
  BEGIN
    PERFORM add_restraint(w_deb,'DEBIT','BADPURPOSE',0,CURRENT_DATE,NULL,NULL,NULL,'TEST');
    INSERT INTO _t(name,ok,detail) VALUES ('TC6 invalid purpose → P0061', false, 'NO exception');
  EXCEPTION WHEN sqlstate 'P0061' THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC6 invalid purpose → P0061', true, SQLERRM);
  WHEN others THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC6 invalid purpose → P0061', false, 'wrong: '||SQLERRM);
  END;

  -- TC7: type↔purpose conflict (COURT_ORDER must be ALL) → P0062
  BEGIN
    PERFORM add_restraint(w_deb,'DEBIT','COURT_ORDER',0,CURRENT_DATE,NULL,NULL,NULL,'TEST');
    INSERT INTO _t(name,ok,detail) VALUES ('TC7 COURT_ORDER≠ALL conflict → P0062', false, 'NO exception');
  EXCEPTION WHEN sqlstate 'P0062' THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC7 COURT_ORDER≠ALL conflict → P0062', true, SQLERRM);
  WHEN others THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC7 COURT_ORDER≠ALL conflict → P0062', false, 'wrong: '||SQLERRM);
  END;

  -- TC8: end_date < start_date → P0063
  BEGIN
    PERFORM add_restraint(w_deb,'DEBIT','PLEDGE',100,CURRENT_DATE,CURRENT_DATE-1,NULL,NULL,'TEST');
    INSERT INTO _t(name,ok,detail) VALUES ('TC8 end_date < start_date → P0063', false, 'NO exception');
  EXCEPTION WHEN sqlstate 'P0063' THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC8 end_date < start_date → P0063', true, SQLERRM);
  WHEN others THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC8 end_date < start_date → P0063', false, 'wrong: '||SQLERRM);
  END;

  -- TC9: pledged > actual balance → P0064
  BEGIN
    PERFORM add_restraint(w_deb,'DEBIT','PLEDGE',2000000,CURRENT_DATE,NULL,NULL,NULL,'TEST');
    INSERT INTO _t(name,ok,detail) VALUES ('TC9 pledged > balance → P0064', false, 'NO exception');
  EXCEPTION WHEN sqlstate 'P0064' THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC9 pledged > balance → P0064', true, SQLERRM);
  WHEN others THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC9 pledged > balance → P0064', false, 'wrong: '||SQLERRM);
  END;

  -- TC10: account not found → P0001
  BEGIN
    PERFORM add_restraint('9701999999999999','DEBIT','PLEDGE',100,CURRENT_DATE,NULL,NULL,NULL,'TEST');
    INSERT INTO _t(name,ok,detail) VALUES ('TC10 acct not found → P0001', false, 'NO exception');
  EXCEPTION WHEN sqlstate 'P0001' THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC10 acct not found → P0001', true, SQLERRM);
  WHEN others THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC10 acct not found → P0001', false, 'wrong: '||SQLERRM);
  END;

  -- TC11: closed account → P0004
  UPDATE wlt_acct SET acct_status='C' WHERE acct_no=w_clo;
  BEGIN
    PERFORM add_restraint(w_clo,'INFO','KYC_REVIEW',0,CURRENT_DATE,NULL,NULL,NULL,'TEST');
    INSERT INTO _t(name,ok,detail) VALUES ('TC11 closed account → P0004', false, 'NO exception');
  EXCEPTION WHEN sqlstate 'P0004' THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC11 closed account → P0004', true, SQLERRM);
  WHEN others THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC11 closed account → P0004', false, 'wrong: '||SQLERRM);
  END;

  -- ════════════════ ENFORCEMENT on the posting path ════════════════

  -- TC12: DEBIT/PLEDGE 950k shrinks CALC_BAL to 50k → withdraw 100k blocked (P0026)
  SELECT restraint_id INTO v_rid
    FROM add_restraint(w_cal,'DEBIT','PLEDGE',950000,CURRENT_DATE,NULL,'lien',NULL,'TEST');
  BEGIN
    PERFORM post_withdraw(w_cal,100000,'RSTR-WD-OVER','EXTWD-RO','BIDV','12345678901234','{}'::jsonb,'MOBILE','test');
    INSERT INTO _t(name,ok,detail) VALUES ('TC12 pledge shrinks CALC_BAL → withdraw P0026', false, 'NO exception');
  EXCEPTION WHEN sqlstate 'P0026' THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC12 pledge shrinks CALC_BAL → withdraw P0026', true, SQLERRM);
  WHEN others THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC12 pledge shrinks CALC_BAL → withdraw P0026', false, 'wrong: '||SQLERRM);
  END;

  -- TC13: withdraw WITHIN remaining CALC_BAL still posts. Release the 950k pledge
  -- (captured in TC12, leaves CALC_BAL=1,000,000) then withdraw 100k → bal 889,000.
  PERFORM release_restraint(v_rid,'free for partial test','TEST');
  SELECT status, new_balance INTO v_wd_st, v_wd_bal
    FROM post_withdraw(w_cal,100000,'RSTR-WD-OK','EXTWD-ROK','BIDV','12345678901234','{}'::jsonb,'MOBILE','test');
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC13 withdraw within available posts (fee min 11k → bal 889,000)',
     v_wd_st='SUCCESS' AND v_wd_bal=889000,
     format('status=%s new_balance=%s (expect 889000)', v_wd_st, v_wd_bal));

  -- TC14: DEBIT full block (PLEDGED=0) → any withdraw raises P0025 (before fund check)
  PERFORM add_restraint(w_blk,'DEBIT','AML_HOLD',0,CURRENT_DATE,NULL,'full block',NULL,'TEST');
  BEGIN
    PERFORM post_withdraw(w_blk,100000,'RSTR-WD-BLK','EXTWD-BK','BIDV','12345678901234','{}'::jsonb,'MOBILE','test');
    INSERT INTO _t(name,ok,detail) VALUES ('TC14 full debit block (PLEDGED=0) → withdraw P0025', false, 'NO exception');
  EXCEPTION WHEN sqlstate 'P0025' THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC14 full debit block (PLEDGED=0) → withdraw P0025', true, SQLERRM);
  WHEN others THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC14 full debit block (PLEDGED=0) → withdraw P0025', false, 'wrong: '||SQLERRM);
  END;

  -- TC15: CREDIT block → topup into the account raises P0029
  PERFORM add_restraint(w_crb,'CREDIT','FRAUD_HOLD',0,CURRENT_DATE,NULL,'cr block',NULL,'TEST');
  BEGIN
    PERFORM post_topup(w_crb,50000,'RSTR-TU-BLK','{}'::jsonb,'TREASURY','test');
    INSERT INTO _t(name,ok,detail) VALUES ('TC15 CREDIT block → topup P0029', false, 'NO exception');
  EXCEPTION WHEN sqlstate 'P0029' THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC15 CREDIT block → topup P0029', true, SQLERRM);
  WHEN others THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC15 CREDIT block → topup P0029', false, 'wrong: '||SQLERRM);
  END;

  -- ════════════════════ RELEASE ════════════════════

  -- TC16: add DEBIT/PLEDGE 950k on w_rel → available 50,000 (sets up TC17–19)
  SELECT restraint_id, available_bal_after INTO v_rid, v_avail
    FROM add_restraint(w_rel,'DEBIT','PLEDGE',950000,CURRENT_DATE,NULL,'rel-lien',NULL,'TEST');
  SELECT calc_bal INTO v_calc FROM wlt_acct WHERE acct_no=w_rel;
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC16 add pledge 950k → available 50,000', v_avail=50000 AND v_calc=50000,
     format('available_bal_after=%s calc_bal=%s', v_avail, v_calc));

  -- TC17: withdraw 100k while pledged → blocked (P0026)
  BEGIN
    PERFORM post_withdraw(w_rel,100000,'RSTR-REL-WD1','EXTWD-RW1','BIDV','12345678901234','{}'::jsonb,'MOBILE','test');
    INSERT INTO _t(name,ok,detail) VALUES ('TC17 withdraw blocked while pledged → P0026', false, 'NO exception');
  EXCEPTION WHEN sqlstate 'P0026' THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC17 withdraw blocked while pledged → P0026', true, SQLERRM);
  WHEN others THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC17 withdraw blocked while pledged → P0026', false, 'wrong: '||SQLERRM);
  END;

  -- TC18: release the pledge → aggregates restored (restrained 0, present N, available=actual)
  SELECT status, available_bal_after INTO v_st, v_avail FROM release_restraint(v_rid,'released',  'TEST');
  SELECT total_restrained_amt, calc_bal, restraint_present INTO v_tra, v_calc, v_present
    FROM wlt_acct WHERE acct_no=w_rel;
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC18 release restores aggregates (status R, restrained 0, present N)',
     v_st='R' AND v_avail=1000000 AND v_tra=0 AND v_calc=1000000 AND v_present='N',
     format('status=%s avail=%s restrained=%s present=%s', v_st, v_avail, v_tra, v_present));

  -- TC19: funds freed — the previously-blocked withdraw now posts (bal 889,000)
  SELECT status, new_balance INTO v_wd_st, v_wd_bal
    FROM post_withdraw(w_rel,100000,'RSTR-REL-WD2','EXTWD-RW2','BIDV','12345678901234','{}'::jsonb,'MOBILE','test');
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC19 release frees funds → withdraw now SUCCESS',
     v_wd_st='SUCCESS' AND v_wd_bal=889000,
     format('status=%s new_balance=%s (expect 889000)', v_wd_st, v_wd_bal));

  -- TC20: release a non-existent restraint → P0065
  BEGIN
    PERFORM release_restraint(999999999,'x','TEST');
    INSERT INTO _t(name,ok,detail) VALUES ('TC20 release not found → P0065', false, 'NO exception');
  EXCEPTION WHEN sqlstate 'P0065' THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC20 release not found → P0065', true, SQLERRM);
  WHEN others THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC20 release not found → P0065', false, 'wrong: '||SQLERRM);
  END;

  -- TC21: double release → 2nd raises P0066 (already removed)
  SELECT restraint_id INTO v_rid
    FROM add_restraint(w_mul,'INFO','KYC_REVIEW',0,CURRENT_DATE,NULL,'dbl',NULL,'TEST');
  PERFORM release_restraint(v_rid,'first','TEST');
  BEGIN
    PERFORM release_restraint(v_rid,'second','TEST');
    INSERT INTO _t(name,ok,detail) VALUES ('TC21 double release → P0066', false, 'NO exception');
  EXCEPTION WHEN sqlstate 'P0066' THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC21 double release → P0066', true, SQLERRM);
  WHEN others THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC21 double release → P0066', false, 'wrong: '||SQLERRM);
  END;

  -- TC22: court/tax-lien release WITHOUT a documented reason → P0067
  SELECT restraint_id INTO v_rid
    FROM add_restraint(w_crt,'ALL','COURT_ORDER',100000,CURRENT_DATE,NULL,'court hold',NULL,'TEST');
  BEGIN
    PERFORM release_restraint(v_rid,NULL,'TEST');
    INSERT INTO _t(name,ok,detail) VALUES ('TC22 court release w/o reason → P0067', false, 'NO exception');
  EXCEPTION WHEN sqlstate 'P0067' THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC22 court release w/o reason → P0067', true, SQLERRM);
  WHEN others THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC22 court release w/o reason → P0067', false, 'wrong: '||SQLERRM);
  END;

  -- TC23: same court restraint releases once a reason is supplied
  SELECT status INTO v_st FROM release_restraint(v_rid,'court order ref VKS-2026/123','TEST');
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC23 court release WITH reason → status R', v_st='R', format('status=%s', v_st));

  -- TC24: two DEBIT pledges accumulate → TOTAL_RESTRAINED_AMT = sum
  SELECT restraint_id INTO v_rid1
    FROM add_restraint(w_mul,'DEBIT','PLEDGE',300000,CURRENT_DATE,NULL,'lien-1',NULL,'TEST');
  SELECT restraint_id INTO v_rid2
    FROM add_restraint(w_mul,'DEBIT','PLEDGE',200000,CURRENT_DATE,NULL,'lien-2',NULL,'TEST');
  SELECT total_restrained_amt, calc_bal INTO v_tra, v_calc FROM wlt_acct WHERE acct_no=w_mul;
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC24 two pledges accumulate (restrained=500,000, calc=500,000)',
     v_tra=500000 AND v_calc=500000, format('restrained=%s calc=%s', v_tra, v_calc));

  -- TC25: release ONE pledge → aggregate recomputed from remaining ACTIVE (still 200k, present Y)
  SELECT available_bal_after INTO v_avail FROM release_restraint(v_rid1,'partial release','TEST');
  SELECT total_restrained_amt, restraint_present INTO v_tra, v_present FROM wlt_acct WHERE acct_no=w_mul;
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC25 partial release recomputes (restrained 500k→200k, present stays Y)',
     v_tra=200000 AND v_avail=800000 AND v_present='Y',
     format('available_bal_after=%s restrained=%s present=%s', v_avail, v_tra, v_present));
END $$;

-- Results
SELECT lpad(id::text,2) AS "#", CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, name, detail
FROM _t ORDER BY id;

SELECT count(*) AS total, count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed
FROM _t;

ROLLBACK;
