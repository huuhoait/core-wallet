-- =============================================================================
-- wallet_outbox_envelope_test.sql — tests for the canonical outbox event
-- envelope (US-7.4). The BEFORE INSERT trigger trg_outbox_envelope (fn
-- fn_outbox_envelope) stamps every WLT_OUTBOX row with a uniform payload.meta
-- block (schema_version, event_type, aggregate, reference, tran_type, channel,
-- actor, occurred_at, trace_id) and enriches headers — without the emitting SP
-- needing to know the contract. Business payload fields stay top-level.
-- =============================================================================
SET app.pii_dek = 'dev-test-pii-dek-do-not-use-in-prod';

BEGIN;
CREATE TEMP TABLE _t (id serial, name text, ok boolean, detail text) ON COMMIT DROP;

DO $$
DECLARE
  c1 text; k1 bigint; a1 text;
  v_meta jsonb; v_headers jsonb;
BEGIN
  -- Per-TX audit GUCs (what repo.withTx sets); the BEFORE trg_audit_cols copies
  -- channel→CHANNEL and actor→CREATED_BY, which the envelope then surfaces.
  PERFORM set_config('audit.actor',   'ops.bob', true);
  PERFORM set_config('audit.channel', 'MOBILE',  true);
  PERFORM set_config('app.trace_id',  '00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01', true);

  c1 := fn_create_client('Envelope A','888700000001','0887700001','a@env.test','IND','2');
  SELECT internal_key, acct_no INTO k1, a1 FROM fn_open_wallet(c1,'CONSUMER',0);

  -- ───── TC1: a posted topup carries the full meta envelope ─────
  PERFORM post_topup(a1, 50000, 'ENV-TOPUP-1', '{}'::jsonb, 'MOBILE', 'ops.bob');
  SELECT payload->'meta', headers INTO v_meta, v_headers
    FROM wlt_outbox
   WHERE event_type = 'wallet.topup.posted.v1' AND payload->>'reference' = 'ENV-TOPUP-1'
   ORDER BY event_id DESC LIMIT 1;

  INSERT INTO _t(name,ok,detail) VALUES
    ('TC1 meta block present with schema_version + event_type + aggregate',
     v_meta IS NOT NULL
       AND v_meta->>'schema_version' = 'v1'
       AND v_meta->>'event_type' = 'wallet.topup.posted.v1'
       AND v_meta->>'aggregate_type' = 'TRANSACTION',
     format('meta=%s', v_meta));
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC1b meta carries reference + tran_type (mapped from event_type)',
     v_meta->>'reference' = 'ENV-TOPUP-1' AND v_meta->>'tran_type' = 'TOPUP',
     format('reference=%s tran_type=%s', v_meta->>'reference', v_meta->>'tran_type'));
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC1c meta attributed to audit GUCs (channel + actor) + has occurred_at + trace_id',
     v_meta->>'channel' = 'MOBILE' AND v_meta->>'actor' = 'ops.bob'
       AND v_meta->>'occurred_at' IS NOT NULL
       AND v_meta->>'trace_id' = '00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01',
     format('channel=%s actor=%s occurred_at=%s', v_meta->>'channel', v_meta->>'actor', v_meta->>'occurred_at'));
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC1d headers enriched (schema_version + event_type + content_type) keeping traceparent',
     v_headers->>'schema_version' = 'v1'
       AND v_headers->>'event_type' = 'wallet.topup.posted.v1'
       AND v_headers->>'content_type' = 'application/json'
       AND v_headers->>'traceparent' IS NOT NULL,
     format('headers=%s', v_headers));
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC1e business fields remain top-level (backward compatible)',
     (SELECT payload->>'amount' = '50000' AND payload ? 'tran_internal_id'
        FROM wlt_outbox WHERE event_type='wallet.topup.posted.v1' AND payload->>'reference'='ENV-TOPUP-1'
        ORDER BY event_id DESC LIMIT 1),
     'amount + tran_internal_id still at payload root');

  -- ───── TC2: reference is lifted from orig_reference / ext_payout_ref, and the
  --            event_type→tran_type map covers reversals — verified by a direct
  --            synthetic insert (the trigger is emitter-agnostic) ─────
  INSERT INTO wlt_outbox (aggregate_type, aggregate_id, event_type, partition_key, topic, payload, headers)
  VALUES ('TRANSFER', '999001', 'wallet.transfer.reversed.v1', 'A1', 'wallet.transfers',
          jsonb_build_object('reversal_tran_key', 999001, 'orig_reference', 'ENV-REV-9', 'amount', 1000),
          NULL);   -- no headers passed → trigger must still build them
  SELECT payload->'meta', headers INTO v_meta, v_headers
    FROM wlt_outbox WHERE event_type='wallet.transfer.reversed.v1' AND aggregate_id='999001'
    ORDER BY event_id DESC LIMIT 1;
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC2 reference lifted from orig_reference + tran_type mapped to RVTRF',
     v_meta->>'reference' = 'ENV-REV-9' AND v_meta->>'tran_type' = 'RVTRF',
     format('reference=%s tran_type=%s', v_meta->>'reference', v_meta->>'tran_type'));
  INSERT INTO _t(name,ok,detail) VALUES
    ('TC2b headers built even when the emitter passed none',
     v_headers->>'schema_version' = 'v1' AND v_headers->>'event_type' = 'wallet.transfer.reversed.v1',
     format('headers=%s', v_headers));
END $$;

-- ───── results ─────
SELECT id, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, name, detail
  FROM _t ORDER BY id;

DO $$
DECLARE n_fail int;
BEGIN
  SELECT count(*) INTO n_fail FROM _t WHERE NOT ok;
  IF n_fail > 0 THEN
    RAISE EXCEPTION 'wallet_outbox_envelope_test: % case(s) FAILED', n_fail;
  END IF;
  RAISE NOTICE 'wallet_outbox_envelope_test: ALL PASS';
END $$;

ROLLBACK;
