-- =============================================================================
-- wallet_client_audit_test.sql — tests for the client-master UPDATE diff
-- auditing (US-8.5). The AFTER UPDATE triggers trg_audit_fm_client (FM_CLIENT)
-- and trg_audit_fm_client_ct (FM_CLIENT_CONTACT) call fn_audit_client_change,
-- which writes an OLD→NEW diff row into FM_CLIENT_AUDIT_LOG. Policy: UPDATE only
-- (INSERT writes nothing), the diff lists exactly the changed columns, and the
-- row is attributed to the audit.actor GUC that withTx sets per-TX.
-- =============================================================================
SET app.pii_dek = 'dev-test-pii-dek-do-not-use-in-prod';

BEGIN;
CREATE TEMP TABLE _t (id serial, name text, ok boolean, detail text) ON COMMIT DROP;

DO $$
DECLARE
  c1 text;
  n_before bigint; n_after bigint;
  v_op text; v_by text; v_tbl text; v_fields text[]; v_old jsonb; v_new jsonb;
  v_oldtxt text; v_newtxt text;
BEGIN
  -- Simulate the per-TX audit GUCs that repo.withTx sets (step 3).
  PERFORM set_config('audit.actor',  'ops.alice', true);
  PERFORM set_config('audit.source', 'API',       true);

  -- ───── TC1: creating a client writes NO audit row (INSERT is not audited) ─────
  SELECT count(*) INTO n_before FROM fm_client_audit_log WHERE table_name = 'fm_client';
  c1 := fn_create_client('Audit A','888600000001','0886600001','a@aud.test','IND','2');
  SELECT count(*) INTO n_after FROM fm_client_audit_log
    WHERE table_name = 'fm_client' AND client_no = c1;
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC1 INSERT of a new client writes no audit diff row',
     n_after = 0,
     format('rows_for_new_client=%s', n_after));

  -- ───── TC2: an UPDATE to FM_CLIENT writes one diff row, correctly attributed ──
  UPDATE fm_client SET client_name = 'Audit A (renamed)', status = 'B' WHERE client_no = c1;
  SELECT count(*) INTO n_after FROM fm_client_audit_log
    WHERE table_name = 'fm_client' AND client_no = c1 AND operation = 'UPDATE';
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC2 UPDATE to FM_CLIENT writes exactly one diff row',
     n_after = 1, format('rows=%s', n_after));

  SELECT operation, changed_by, table_name, changed_fields, old_values, new_values
    INTO v_op, v_by, v_tbl, v_fields, v_old, v_new
    FROM fm_client_audit_log
   WHERE table_name = 'fm_client' AND client_no = c1 AND operation = 'UPDATE'
   ORDER BY audit_id DESC LIMIT 1;
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC2b diff row attributed to audit.actor + captures changed fields & OLD/NEW',
     v_by = 'ops.alice'
       AND v_fields @> ARRAY['client_name','status']
       AND v_old->>'status' = 'A' AND v_new->>'status' = 'B'
       AND v_old->>'client_name' = 'Audit A' AND v_new->>'client_name' = 'Audit A (renamed)',
     format('by=%s fields=%s old.status=%s new.status=%s', v_by, v_fields, v_old->>'status', v_new->>'status'));

  -- ───── TC3: the diff is PRECISE — only the field that actually changed (plus
  --            the updated_at housekeeping stamp from the BEFORE trg_audit_cols)
  --            appears in changed_fields; untouched business columns do not ─────
  UPDATE fm_client SET status = 'A' WHERE client_no = c1;  -- flip status back; name untouched
  SELECT changed_fields INTO v_fields
    FROM fm_client_audit_log
   WHERE table_name = 'fm_client' AND client_no = c1 AND operation = 'UPDATE'
   ORDER BY audit_id DESC LIMIT 1;
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC3 diff captures only the changed field, not untouched columns',
     v_fields @> ARRAY['status'] AND NOT (v_fields @> ARRAY['client_name']) AND NOT (v_fields @> ARRAY['global_id']),
     format('changed_fields=%s', v_fields));

  -- ───── TC4: FM_CLIENT_CONTACT UPDATE is audited too ─────
  INSERT INTO fm_client_contact (client_no, contact_type, addr_line1, city, country)
  VALUES (c1, 'HOME', 'Old Address 1', 'Hanoi', 'VN');   -- INSERT → no audit row
  SELECT count(*) INTO n_before FROM fm_client_audit_log WHERE table_name = 'fm_client_contact' AND client_no = c1;
  UPDATE fm_client_contact SET addr_line1 = 'New Address 2', city = 'HCMC'
   WHERE client_no = c1 AND contact_type = 'HOME';
  SELECT count(*) INTO n_after FROM fm_client_audit_log WHERE table_name = 'fm_client_contact' AND client_no = c1;
  SELECT changed_fields, old_values->>'addr_line1', new_values->>'addr_line1'
    INTO v_fields, v_oldtxt, v_newtxt
    FROM fm_client_audit_log
   WHERE table_name = 'fm_client_contact' AND client_no = c1 AND operation = 'UPDATE'
   ORDER BY audit_id DESC LIMIT 1;
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC4 FM_CLIENT_CONTACT: INSERT silent, UPDATE writes one attributed diff row',
     n_before = 0 AND n_after = 1 AND v_fields @> ARRAY['addr_line1','city']
       AND v_oldtxt = 'Old Address 1' AND v_newtxt = 'New Address 2',
     format('before=%s after=%s fields=%s', n_before, n_after, v_fields));
END $$;

-- ───── results ─────
SELECT id, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, name, detail
  FROM _t ORDER BY id;

DO $$
DECLARE n_fail int;
BEGIN
  SELECT count(*) INTO n_fail FROM _t WHERE NOT ok;
  IF n_fail > 0 THEN
    RAISE EXCEPTION 'wallet_client_audit_test: % case(s) FAILED', n_fail;
  END IF;
  RAISE NOTICE 'wallet_client_audit_test: ALL PASS';
END $$;

ROLLBACK;
