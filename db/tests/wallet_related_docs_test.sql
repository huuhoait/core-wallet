-- =============================================================================
-- wallet_related_docs_test.sql — tests for attach_client_document (US-1.13,
-- onboarding step 3). Appends/updates {doc_type, link, status, uploaded_at}
-- entries in FM_CLIENT_KYC.related_docs (a JSONB array). UPSERT is by doc_type:
-- re-attaching the same doc_type REPLACES the prior entry. The file bytes live
-- in object storage; only the link + metadata are stored.
-- =============================================================================
SET app.pii_dek = 'dev-test-pii-dek-do-not-use-in-prod';

BEGIN;
CREATE TEMP TABLE _t (id serial, name text, ok boolean, detail text) ON COMMIT DROP;

DO $$
DECLARE
  c1 text;
  v_cnt int; v_docs jsonb; v_n int;
  v_status text; v_link text;
BEGIN
  PERFORM set_config('audit.actor', 'ops.carol', true);
  c1 := fn_create_client('Docs A','888800000001','0888800001','a@doc.test','IND','2');

  -- ───── TC1: a fresh client's KYC starts with an empty related_docs array ─────
  SELECT related_docs INTO v_docs FROM fm_client_kyc WHERE client_no = c1;
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC1 new client KYC starts with empty related_docs []',
     v_docs = '[]'::jsonb, format('related_docs=%s', v_docs));

  -- ───── TC2: attach a first document (status defaults to PENDING) ─────
  SELECT doc_count, related_docs INTO v_cnt, v_docs
    FROM attach_client_document(c1, 'CCCD_FRONT', 's3://kyc/'||c1||'/front.jpg');
  v_status := v_docs->0->>'status';
  v_link   := v_docs->0->>'link';
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC2 attach first doc → count 1, status defaults PENDING, link + uploaded_at set',
     v_cnt = 1 AND v_status = 'PENDING' AND v_link = 's3://kyc/'||c1||'/front.jpg'
       AND (v_docs->0->>'uploaded_at') IS NOT NULL
       AND (v_docs->0->>'doc_type') = 'CCCD_FRONT',
     format('count=%s doc=%s', v_cnt, v_docs->0));

  -- ───── TC3: attach a different doc_type → appended (count 2) ─────
  SELECT doc_count INTO v_cnt
    FROM attach_client_document(c1, 'CCCD_BACK', 's3://kyc/'||c1||'/back.jpg', 'PENDING');
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC3 attach a different doc_type appends (count 2)',
     v_cnt = 2, format('count=%s', v_cnt));

  -- ───── TC4: re-attach the SAME doc_type → UPSERT (count stays 2, entry updated) ─
  SELECT doc_count, related_docs INTO v_cnt, v_docs
    FROM attach_client_document(c1, 'CCCD_FRONT', 's3://kyc/'||c1||'/front_v2.jpg', 'VERIFIED');
  SELECT count(*) INTO v_n FROM jsonb_array_elements(v_docs) e WHERE e->>'doc_type' = 'CCCD_FRONT';
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC4 re-attach same doc_type upserts (count stays 2, single CCCD_FRONT entry)',
     v_cnt = 2 AND v_n = 1,
     format('count=%s cccd_front_entries=%s', v_cnt, v_n));
  SELECT e->>'status', e->>'link' INTO v_status, v_link
    FROM jsonb_array_elements(v_docs) e WHERE e->>'doc_type' = 'CCCD_FRONT';
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC4b the upserted CCCD_FRONT now reflects the new status + link',
     v_status = 'VERIFIED' AND v_link = 's3://kyc/'||c1||'/front_v2.jpg',
     format('status=%s link=%s', v_status, v_link));

  -- ───── TC5: validation — bad status rejected (P0071) ─────
  BEGIN
    PERFORM attach_client_document(c1, 'X', 's3://x', 'BOGUS');
    INSERT INTO _t(name,ok,detail) VALUES ('TC5 bad status rejected', false, 'no error raised');
  EXCEPTION WHEN sqlstate 'P0071' THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC5 bad status rejected with INVALID_REQUEST (P0071)', true, SQLERRM);
  END;

  -- ───── TC6: validation — unknown client rejected (P0073) ─────
  BEGIN
    PERFORM attach_client_document('C9999999999', 'CCCD_FRONT', 's3://x');
    INSERT INTO _t(name,ok,detail) VALUES ('TC6 unknown client rejected', false, 'no error raised');
  EXCEPTION WHEN sqlstate 'P0073' THEN
    INSERT INTO _t(name,ok,detail) VALUES ('TC6 unknown client rejected with CLIENT_NOT_FOUND (P0073)', true, SQLERRM);
  END;

  -- ───── TC7: the change is audited (US-8.1: trg_audit_fm_kyc diff row) ─────
  PERFORM 1;
  INSERT INTO _t(name,ok,detail)
  SELECT 'TC7 attach writes a related_docs diff to FM_CLIENT_AUDIT_LOG',
         count(*) >= 1, format('audit_rows=%s', count(*))
    FROM fm_client_audit_log
   WHERE client_no = c1 AND table_name = 'fm_client_kyc'
     AND changed_fields @> ARRAY['related_docs'];
END $$;

SELECT id, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, name, detail
  FROM _t ORDER BY id;

DO $$
DECLARE n_fail int;
BEGIN
  SELECT count(*) INTO n_fail FROM _t WHERE NOT ok;
  IF n_fail > 0 THEN
    RAISE EXCEPTION 'wallet_related_docs_test: % case(s) FAILED', n_fail;
  END IF;
  RAISE NOTICE 'wallet_related_docs_test: ALL PASS';
END $$;

ROLLBACK;
