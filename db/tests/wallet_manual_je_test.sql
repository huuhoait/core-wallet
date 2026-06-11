-- =============================================================================
-- wallet_manual_je_test.sql — maker-checker manual journal entry (US-6.5)
-- =============================================================================
-- Deterministic, fully transactional (BEGIN .. ROLLBACK). Asserts the manual
-- journal entry workflow:
--   * create_manual_je: balanced ΣDR=ΣCR, valid GL codes, ≥2 lines, reason
--     required → status PENDING.
--   * approve_manual_je: checker ≠ maker, must be PENDING → posts balanced rows
--     into WLT_GL_BATCH (source_module 'MJE') under one tran_key, status POSTED.
--   * reject_manual_je: PENDING → REJECTED, no GL rows.
--
-- GL codes 109 (clearing/suspense) and 201 (customer liabilities) are seeded
-- parents (status A). Period-open enforcement is covered by
-- wallet_eod_period_lock_test.sql (the WLT_GL_BATCH freeze trigger).
-- =============================================================================
BEGIN;
CREATE TEMP TABLE _t (id serial, name text, ok boolean, detail text) ON COMMIT DROP;

DO $$
DECLARE
  v_lines  jsonb := '[{"gl_code":"109","tran_nature":"DR","amount":"100.00"},
                      {"gl_code":"201","tran_nature":"CR","amount":"100.00"}]'::jsonb;
  v_je     bigint;
  v_st     varchar;
  v_dr     numeric;
  v_cr     numeric;
  v_lc     integer;
  v_gltk   bigint;
  v_pl     integer;
  v_cnt    integer;
  v_src    varchar;
  v_ok     boolean;
  v_det    text;
BEGIN
  -- ───── TC1: create a balanced JE → PENDING ─────
  SELECT je_id, status, total_dr, total_cr, line_count
    INTO v_je, v_st, v_dr, v_cr, v_lc
    FROM create_manual_je('MJE-T1','VND','suspense reclass', v_lines, NULL, NULL, 'MAKER_A');
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC1 create balanced → PENDING, totals=100, 2 lines',
     v_st='PENDING' AND v_dr=100 AND v_cr=100 AND v_lc=2,
     format('status=%s dr=%s cr=%s lines=%s', v_st, v_dr, v_cr, v_lc));

  -- ───── TC2: unbalanced → MJE_UNBALANCED (P00B3) ─────
  BEGIN
    PERFORM create_manual_je('MJE-T2','VND','bad',
      '[{"gl_code":"109","tran_nature":"DR","amount":"100"},
        {"gl_code":"201","tran_nature":"CR","amount":"90"}]'::jsonb, NULL, NULL, 'MAKER_A');
    v_ok := false; v_det := 'no exception raised';
  EXCEPTION WHEN SQLSTATE 'P00B3' THEN v_ok := true; v_det := SQLERRM;
  END;
  INSERT INTO _t(name,ok,detail) VALUES ('TC2 unbalanced → MJE_UNBALANCED', v_ok, v_det);

  -- ───── TC3: empty reason → MJE_REASON_REQUIRED (P00B0) ─────
  BEGIN
    PERFORM create_manual_je('MJE-T3','VND','', v_lines, NULL, NULL, 'MAKER_A');
    v_ok := false; v_det := 'no exception raised';
  EXCEPTION WHEN SQLSTATE 'P00B0' THEN v_ok := true; v_det := SQLERRM;
  END;
  INSERT INTO _t(name,ok,detail) VALUES ('TC3 empty reason → MJE_REASON_REQUIRED', v_ok, v_det);

  -- ───── TC4: unknown gl_code → MJE_GL_INVALID (P00B2) ─────
  BEGIN
    PERFORM create_manual_je('MJE-T4','VND','x',
      '[{"gl_code":"999.99","tran_nature":"DR","amount":"5"},
        {"gl_code":"201","tran_nature":"CR","amount":"5"}]'::jsonb, NULL, NULL, 'MAKER_A');
    v_ok := false; v_det := 'no exception raised';
  EXCEPTION WHEN SQLSTATE 'P00B2' THEN v_ok := true; v_det := SQLERRM;
  END;
  INSERT INTO _t(name,ok,detail) VALUES ('TC4 unknown gl_code → MJE_GL_INVALID', v_ok, v_det);

  -- ───── TC5: fewer than 2 lines → MJE_INVALID_LINES (P00B1) ─────
  BEGIN
    PERFORM create_manual_je('MJE-T5','VND','x',
      '[{"gl_code":"109","tran_nature":"DR","amount":"5"}]'::jsonb, NULL, NULL, 'MAKER_A');
    v_ok := false; v_det := 'no exception raised';
  EXCEPTION WHEN SQLSTATE 'P00B1' THEN v_ok := true; v_det := SQLERRM;
  END;
  INSERT INTO _t(name,ok,detail) VALUES ('TC5 <2 lines → MJE_INVALID_LINES', v_ok, v_det);

  -- ───── TC6: maker approves own JE → MJE_MAKER_CANNOT_CHECK (P00B6) ─────
  BEGIN
    PERFORM approve_manual_je(v_je, 'MAKER_A', 'self');
    v_ok := false; v_det := 'no exception raised';
  EXCEPTION WHEN SQLSTATE 'P00B6' THEN v_ok := true; v_det := SQLERRM;
  END;
  INSERT INTO _t(name,ok,detail) VALUES ('TC6 maker approves own → MJE_MAKER_CANNOT_CHECK', v_ok, v_det);

  -- ───── TC7: different checker approves → POSTED + balanced GL rows ─────
  SELECT je_id, status, gl_tran_key, posted_lines
    INTO v_je, v_st, v_gltk, v_pl
    FROM approve_manual_je(v_je, 'CHECKER_B', 'approved');
  SELECT count(*),
         coalesce(sum(amount) FILTER (WHERE tran_nature='DR'),0),
         coalesce(sum(amount) FILTER (WHERE tran_nature='CR'),0),
         max(source_module)
    INTO v_cnt, v_dr, v_cr, v_src
    FROM wlt_gl_batch WHERE tran_key = v_gltk;
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC7 checker approves → POSTED, 2 balanced GL rows (MJE)',
     v_st='POSTED' AND v_pl=2 AND v_cnt=2 AND v_dr=100 AND v_cr=100 AND v_src='MJE',
     format('status=%s posted_lines=%s gl_rows=%s dr=%s cr=%s src=%s', v_st, v_pl, v_cnt, v_dr, v_cr, v_src));

  -- ───── TC8: approve again (now POSTED) → MJE_INVALID_STATE (P00B5) ─────
  BEGIN
    PERFORM approve_manual_je(v_je, 'CHECKER_B', 'again');
    v_ok := false; v_det := 'no exception raised';
  EXCEPTION WHEN SQLSTATE 'P00B5' THEN v_ok := true; v_det := SQLERRM;
  END;
  INSERT INTO _t(name,ok,detail) VALUES ('TC8 re-approve POSTED → MJE_INVALID_STATE', v_ok, v_det);

  -- ───── TC9: reject a fresh PENDING JE → REJECTED (no GL rows) ─────
  SELECT je_id INTO v_je
    FROM create_manual_je('MJE-T9','VND','to reject', v_lines, NULL, NULL, 'MAKER_A');
  SELECT status INTO v_st FROM reject_manual_je(v_je, 'CHECKER_B', 'not needed');
  SELECT count(*) INTO v_cnt FROM wlt_gl_batch WHERE reference = 'MJE-T9';
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC9 reject PENDING → REJECTED, no GL rows', v_st='REJECTED' AND v_cnt=0,
     format('status=%s gl_rows=%s', v_st, v_cnt));

  -- ───── TC10: approve unknown id → MJE_NOT_FOUND (P00B4) ─────
  BEGIN
    PERFORM approve_manual_je(-99999, 'CHECKER_B', 'x');
    v_ok := false; v_det := 'no exception raised';
  EXCEPTION WHEN SQLSTATE 'P00B4' THEN v_ok := true; v_det := SQLERRM;
  END;
  INSERT INTO _t(name,ok,detail) VALUES ('TC10 approve unknown id → MJE_NOT_FOUND', v_ok, v_det);

  -- ───── TC11: duplicate reference → unique_violation (23505) ─────
  BEGIN
    PERFORM create_manual_je('MJE-T1','VND','dup', v_lines, NULL, NULL, 'MAKER_A');
    v_ok := false; v_det := 'no exception raised';
  EXCEPTION WHEN unique_violation THEN v_ok := true; v_det := SQLERRM;
  END;
  INSERT INTO _t(name,ok,detail) VALUES ('TC11 duplicate reference → unique_violation', v_ok, v_det);
END $$;

-- Results
SELECT lpad(id::text,2) AS "#", CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, name, detail
FROM _t ORDER BY id;

SELECT count(*) AS total, count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed
FROM _t;

ROLLBACK;
