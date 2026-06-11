-- =============================================================================
-- wallet_pii_access_log_test.sql — tests for the PII access trail (US-8.4).
-- log_pii_access() appends one row to WLT_PII_ACCESS_LOG; the Go repo calls it
-- (best-effort) after each privileged unmasked read (/v1/ops/clients*, /ops/
-- search). Here we exercise the SP directly: attribution, access-type CHECK,
-- nullable client_no (list/search), jsonb detail, and inet coercion.
-- =============================================================================
BEGIN;
CREATE TEMP TABLE _t (id serial, name text, ok boolean, detail text) ON COMMIT DROP;

DO $$
DECLARE
  v_id bigint; v_by text; v_type text; v_cli text; v_ip inet; v_detail jsonb;
BEGIN
  -- ───── TC1: a profile read logs WHO/WHAT/WHEN + correlation ids ─────
  v_id := log_pii_access('ops.dave', 'CLIENT_PROFILE', 'C0000000123',
            '{}'::jsonb, 'OPS', 'req-1', '0af7651916cd43dd8448eb211c80319c', '10.1.2.3');
  SELECT accessed_by, access_type, client_no, ip_address
    INTO v_by, v_type, v_cli, v_ip
    FROM wlt_pii_access_log WHERE access_id = v_id;
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC1 profile access logged with actor + type + client_no + ip',
     v_by='ops.dave' AND v_type='CLIENT_PROFILE' AND v_cli='C0000000123' AND v_ip='10.1.2.3'::inet,
     format('by=%s type=%s client=%s ip=%s', v_by, v_type, v_cli, v_ip));

  -- ───── TC2: a list read logs with NULL client_no + a jsonb detail ─────
  v_id := log_pii_access('ops.dave', 'CLIENT_LIST', NULL,
            jsonb_build_object('count', 25, 'status', 'A'), 'OPS', 'req-2', NULL, NULL);
  SELECT client_no, detail INTO v_cli, v_detail FROM wlt_pii_access_log WHERE access_id = v_id;
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC2 list access logs NULL client_no + detail jsonb',
     v_cli IS NULL AND v_detail->>'count' = '25' AND v_detail->>'status' = 'A',
     format('client=%s detail=%s', COALESCE(v_cli,'<null>'), v_detail));

  -- ───── TC3: empty actor falls back to SYSTEM; empty ip → NULL (not '') ─────
  v_id := log_pii_access('', 'ACCOUNT_SEARCH', NULL,
            jsonb_build_object('query', '970100'), NULL, NULL, NULL, '');
  SELECT accessed_by, ip_address INTO v_by, v_ip FROM wlt_pii_access_log WHERE access_id = v_id;
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC3 empty actor → SYSTEM, empty ip → NULL',
     v_by = 'SYSTEM' AND v_ip IS NULL,
     format('by=%s ip=%s', v_by, COALESCE(v_ip::text,'<null>')));

  -- ───── TC4: an invalid access_type is rejected by the CHECK constraint ─────
  BEGIN
    PERFORM log_pii_access('ops.dave', 'BOGUS_TYPE', 'C1', '{}'::jsonb);
    INSERT INTO _t(name,ok,detail) VALUES ('TC4 invalid access_type rejected', false, 'no error raised');
  EXCEPTION WHEN check_violation THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC4 invalid access_type rejected by CHECK', true, SQLERRM);
  END;
END $$;

SELECT id, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, name, detail
  FROM _t ORDER BY id;

DO $$
DECLARE n_fail int;
BEGIN
  SELECT count(*) INTO n_fail FROM _t WHERE NOT ok;
  IF n_fail > 0 THEN
    RAISE EXCEPTION 'wallet_pii_access_log_test: % case(s) FAILED', n_fail;
  END IF;
  RAISE NOTICE 'wallet_pii_access_log_test: ALL PASS';
END $$;

ROLLBACK;
