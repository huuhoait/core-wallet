-- =============================================================================
-- wallet_sp_topup_reversal.sql — post_topup_reversal (RVTPUP)
-- =============================================================================
-- Reverses a topup posted by post_topup (DR nostro / CR wallet).
--   Reversal: DR wallet (claw back credited amount) / CR nostro.
--   Inline fund guard — the credited amount may already be spent.
--   Idempotent on RVTPUP-<orig_reference>.
-- =============================================================================
\set ON_ERROR_STOP on
BEGIN;

CREATE OR REPLACE FUNCTION post_topup_reversal(
  p_orig_reference VARCHAR(64),
  p_reason         VARCHAR(500),
  p_initiator      VARCHAR(32) DEFAULT 'OPS_MANUAL',
  p_channel        VARCHAR(20) DEFAULT 'SYS',
  p_actor          VARCHAR(64) DEFAULT NULL
)
RETURNS TABLE (
  reversal_tfr_key     BIGINT,
  was_already_reversed BOOLEAN,
  new_balance          NUMERIC(18,2),
  event_uuid           UUID
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog AS $$
#variable_conflict use_column
DECLARE
  v_actor VARCHAR(64) := COALESCE(p_actor, session_user);
  v_orig  WLT_API_MESSAGE%ROWTYPE;
  v_rev   WLT_API_MESSAGE%ROWTYPE;
  v_rref  VARCHAR(64) := left('RVTPUP-'||p_orig_reference, 64);
  v_acct_no VARCHAR(20); v_amt NUMERIC(18,2);
  v_orig_tfr BIGINT; v_orig_seq BIGINT;
  v_acct WLT_ACCT%ROWTYPE; v_def WLT_TRAN_DEF%ROWTYPE;
  v_liab_gl VARCHAR(32); v_rev_tfr BIGINT; v_event UUID; v_cinfo JSONB;
BEGIN
  PERFORM set_config('audit.actor', v_actor, TRUE);
  PERFORM set_config('audit.channel', p_channel, TRUE);

  SELECT * INTO v_rev FROM WLT_API_MESSAGE WHERE OBJECT_REF_ID = v_rref FOR UPDATE;
  IF FOUND AND v_rev.PROCESS_STATUS = 'SUCCESS' THEN
    RETURN QUERY SELECT (v_rev.OBJECT_RESPONE_DATA::jsonb->>'reversal_tfr_key')::bigint, TRUE,
                        (v_rev.OBJECT_RESPONE_DATA::jsonb->>'new_balance')::numeric,
                        (v_rev.OBJECT_RESPONE_DATA::jsonb->>'event_uuid')::uuid;
    RETURN;
  END IF;

  SELECT * INTO v_orig FROM WLT_API_MESSAGE
   WHERE OBJECT_REF_ID = p_orig_reference AND OBJECT_SUBJECT = 'TOPUP' FOR UPDATE;
  IF NOT FOUND OR v_orig.PROCESS_STATUS <> 'SUCCESS' THEN
    RAISE EXCEPTION 'TRAN_NOT_FOUND: topup % not posted', p_orig_reference USING ERRCODE = 'P0040';
  END IF;

  v_acct_no  := v_orig.OBJECT_REQUEST_DATA::jsonb->>'acct_no';
  v_amt      := (v_orig.OBJECT_REQUEST_DATA::jsonb->>'amount')::numeric;
  v_orig_tfr := (v_orig.OBJECT_RESPONE_DATA::jsonb->>'tfr_internal_key')::bigint;

  SELECT * INTO v_acct FROM WLT_ACCT WHERE ACCT_NO = v_acct_no FOR UPDATE;
  SELECT * INTO v_def  FROM WLT_TRAN_DEF WHERE TRAN_TYPE = 'RVTPUP';
  SELECT GL_CODE_LIAB INTO v_liab_gl FROM WLT_ACCT_TYPE WHERE ACCT_TYPE = v_acct.ACCT_TYPE;
  SELECT SEQ_NO INTO v_orig_seq FROM WLT_TRAN_HIST WHERE TFR_INTERNAL_KEY = v_orig_tfr AND TRAN_TYPE = 'TOPUP' LIMIT 1;
  v_cinfo := fn_build_client_info(v_acct.CLIENT_NO);

  INSERT INTO WLT_API_MESSAGE (OBJECT_REF_ID, OBJECT_CHANNEL, OBJECT_SUBJECT, OBJECT_REQUEST_DATA, PROCESS_STATUS)
  VALUES (v_rref, p_channel, 'TOPUP_REVERSAL',
          jsonb_build_object('orig_reference', p_orig_reference, 'reason', p_reason, 'initiator', p_initiator)::text, 'PENDING')
  ON CONFLICT (OBJECT_REF_ID) DO NOTHING;

  v_rev_tfr := nextval('seq_tfr');

  -- Claw back the credited amount (inline fund guard)
  UPDATE WLT_ACCT SET ACTUAL_BAL = ACTUAL_BAL - v_amt, VERSION = VERSION + 1, LAST_TRAN_DATE = clock_timestamp()
   WHERE INTERNAL_KEY = v_acct.INTERNAL_KEY
     AND ACTUAL_BAL - TOTAL_RESTRAINED_AMT >= v_amt
  RETURNING ACTUAL_BAL INTO v_acct.ACTUAL_BAL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'INSUFFICIENT_FUNDS: wallet % cannot cover topup claw-back of %', v_acct_no, v_amt USING ERRCODE = 'P0026';
  END IF;

  -- RVTPUP leg (DR wallet)
  INSERT INTO WLT_TRAN_HIST (INTERNAL_KEY, TRAN_TYPE, TRAN_DATE, EFFECT_DATE, POST_DATE, VALUE_DATE,
     TRAN_AMT, CR_DR_MAINT_IND, PREVIOUS_BAL_AMT, ACTUAL_BAL_AMT,
     TFR_INTERNAL_KEY, REFERENCE, ORIG_SEQ_NO, CCY, SOURCE_TYPE, SOURCE_MODULE, TRAN_DESC, GROUP_ID, CLIENT_INFO)
  VALUES (v_acct.INTERNAL_KEY, 'RVTPUP', CURRENT_DATE, CURRENT_DATE, CURRENT_DATE, CURRENT_DATE,
     v_amt, 'DR', v_acct.ACTUAL_BAL + v_amt, v_acct.ACTUAL_BAL,
     v_rev_tfr, v_rref, v_orig_seq, v_acct.CCY, p_channel, 'WLT',
     'Reverse topup: '||COALESCE(p_reason,'?'), v_acct.GROUP_ID, v_cinfo);

  -- GL flip: DR wallet liability / CR nostro
  INSERT INTO WLT_BATCH (TRAN_KEY, SEQ_NO, GL_CODE, CLIENT_NO, ACCT_INTERNAL_KEY, AMOUNT, TRAN_NATURE, CCY, REFERENCE, POST_DATE, VALUE_DATE)
  VALUES
    (v_rev_tfr, 1, v_liab_gl,            v_acct.CLIENT_NO, v_acct.INTERNAL_KEY, v_amt, 'DR', v_acct.CCY, v_rref, CURRENT_DATE, CURRENT_DATE),
    (v_rev_tfr, 2, v_def.CONTRA_GL_CODE, v_acct.CLIENT_NO, v_acct.INTERNAL_KEY, v_amt, 'CR', v_acct.CCY, v_rref, CURRENT_DATE, CURRENT_DATE);

  INSERT INTO WLT_OUTBOX (AGGREGATE_TYPE, AGGREGATE_ID, EVENT_TYPE, PARTITION_KEY, TOPIC, PAYLOAD, HEADERS)
  VALUES ('TOPUP', v_rev_tfr::text, 'wallet.topup.reversed.v1', v_acct_no, 'wallet.transactions',
          jsonb_build_object('reversal_tfr_key', v_rev_tfr, 'orig_reference', p_orig_reference,
                             'acct_no', v_acct_no, 'amount', v_amt, 'reason', p_reason, 'initiator', p_initiator),
          jsonb_build_object('traceparent', current_setting('app.trace_id', TRUE)))
  RETURNING EVENT_UUID INTO v_event;

  UPDATE WLT_API_MESSAGE SET PROCESS_STATUS='SUCCESS', HTTP_STATUS=200,
     OBJECT_RESPONE_DATA = jsonb_build_object('reversal_tfr_key', v_rev_tfr,
        'new_balance', v_acct.ACTUAL_BAL, 'event_uuid', v_event)::text,
     PROCESSED_AT = clock_timestamp()
   WHERE OBJECT_REF_ID = v_rref;

  RETURN QUERY SELECT v_rev_tfr, FALSE, v_acct.ACTUAL_BAL, v_event;
END $$;

COMMIT;
