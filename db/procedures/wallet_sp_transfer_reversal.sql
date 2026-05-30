-- =============================================================================
-- wallet_sp_transfer_reversal.sql — post_transfer_reversal (RVTRF + RVFEE)
-- =============================================================================
-- Reverses an in-book transfer posted by post_transfer:
--   • refund sender (A): + amount + fee
--   • claw back receiver (B): − amount   (inline fund guard — B may have spent it)
--   • flip GL: CR A / DR B (principal); refund fee CR A / DR 401.01 + DR 203.01
-- Idempotent on RVTRF-<orig_reference>. Locks both wallets in INTERNAL_KEY order.
--
-- If the receiver can no longer cover the claw-back → INSUFFICIENT_FUNDS (P0026):
-- the reversal is blocked and must be handled by ops (the money already moved on).
-- =============================================================================

\set ON_ERROR_STOP on
BEGIN;

CREATE OR REPLACE FUNCTION post_transfer_reversal(
  p_orig_reference VARCHAR(64),
  p_reason         VARCHAR(500),
  p_initiator      VARCHAR(32) DEFAULT 'OPS_MANUAL',
  p_channel        VARCHAR(20) DEFAULT 'SYS',
  p_actor          VARCHAR(64) DEFAULT NULL
)
RETURNS TABLE (
  reversal_tfr_key      BIGINT,
  was_already_reversed  BOOLEAN,
  new_balance_from      NUMERIC(18,2),   -- sender (A) after refund
  new_balance_to        NUMERIC(18,2),   -- receiver (B) after claw-back
  event_uuid            UUID
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog AS $$
#variable_conflict use_column
DECLARE
  v_actor VARCHAR(64) := COALESCE(p_actor, session_user);
  v_orig  WLT_API_MESSAGE%ROWTYPE;
  v_rev   WLT_API_MESSAGE%ROWTYPE;
  v_rref  VARCHAR(64) := left('RVTRF-'||p_orig_reference, 64);
  v_from  VARCHAR(20); v_to VARCHAR(20);
  v_amt NUMERIC(18,2); v_fee NUMERIC(18,2); v_vat NUMERIC(18,2); v_net NUMERIC(18,2);
  v_orig_tfr BIGINT; v_orig_seq BIGINT;
  v_a WLT_ACCT%ROWTYPE; v_b WLT_ACCT%ROWTYPE;
  v_a_gl VARCHAR(32); v_b_gl VARCHAR(32);
  v_rev_tfr BIGINT; v_event UUID; v_ci_a JSONB; v_ci_b JSONB; v_seq_base BIGINT;
  v_lock BIGINT;
BEGIN
  PERFORM set_config('audit.actor', v_actor, TRUE);
  PERFORM set_config('audit.channel', p_channel, TRUE);

  -- Idempotent on reversal key
  SELECT * INTO v_rev FROM WLT_API_MESSAGE WHERE OBJECT_REF_ID = v_rref FOR UPDATE;
  IF FOUND AND v_rev.PROCESS_STATUS = 'SUCCESS' THEN
    RETURN QUERY SELECT (v_rev.OBJECT_RESPONE_DATA::jsonb->>'reversal_tfr_key')::bigint, TRUE,
                        (v_rev.OBJECT_RESPONE_DATA::jsonb->>'new_balance_from')::numeric,
                        (v_rev.OBJECT_RESPONE_DATA::jsonb->>'new_balance_to')::numeric,
                        (v_rev.OBJECT_RESPONE_DATA::jsonb->>'event_uuid')::uuid;
    RETURN;
  END IF;

  -- Load original transfer
  SELECT * INTO v_orig FROM WLT_API_MESSAGE
   WHERE OBJECT_REF_ID = p_orig_reference AND OBJECT_SUBJECT = 'TRANSFER' FOR UPDATE;
  IF NOT FOUND OR v_orig.PROCESS_STATUS <> 'SUCCESS' THEN
    RAISE EXCEPTION 'TRAN_NOT_FOUND: transfer % not posted', p_orig_reference USING ERRCODE = 'P0040';
  END IF;

  v_from := v_orig.OBJECT_REQUEST_DATA::jsonb->>'from';
  v_to   := v_orig.OBJECT_REQUEST_DATA::jsonb->>'to';
  v_amt  := (v_orig.OBJECT_REQUEST_DATA::jsonb->>'amount')::numeric;
  v_orig_tfr := (v_orig.OBJECT_RESPONE_DATA::jsonb->>'tfr_internal_key')::bigint;
  v_fee  := COALESCE((v_orig.OBJECT_RESPONE_DATA::jsonb->>'fee_gross')::numeric, 0);
  v_vat  := COALESCE((v_orig.OBJECT_RESPONE_DATA::jsonb->>'vat_amount')::numeric, 0);
  v_net  := v_fee - v_vat;

  -- Resolve + lock both wallets in INTERNAL_KEY order (deadlock-safe)
  SELECT * INTO v_a FROM WLT_ACCT WHERE ACCT_NO = v_from;
  SELECT * INTO v_b FROM WLT_ACCT WHERE ACCT_NO = v_to;
  FOR v_lock IN SELECT INTERNAL_KEY FROM WLT_ACCT
                 WHERE INTERNAL_KEY IN (v_a.INTERNAL_KEY, v_b.INTERNAL_KEY)
                 ORDER BY INTERNAL_KEY FOR UPDATE LOOP NULL; END LOOP;
  SELECT * INTO v_a FROM WLT_ACCT WHERE INTERNAL_KEY = v_a.INTERNAL_KEY;
  SELECT * INTO v_b FROM WLT_ACCT WHERE INTERNAL_KEY = v_b.INTERNAL_KEY;

  SELECT GL_CODE_LIAB INTO v_a_gl FROM WLT_ACCT_TYPE WHERE ACCT_TYPE = v_a.ACCT_TYPE;
  SELECT GL_CODE_LIAB INTO v_b_gl FROM WLT_ACCT_TYPE WHERE ACCT_TYPE = v_b.ACCT_TYPE;
  SELECT SEQ_NO INTO v_orig_seq FROM WLT_TRAN_HIST WHERE TFR_INTERNAL_KEY = v_orig_tfr AND TRAN_TYPE IN ('TRFOUT','TRFOUTF') LIMIT 1;
  v_ci_a := fn_build_client_info(v_a.CLIENT_NO);
  v_ci_b := fn_build_client_info(v_b.CLIENT_NO);

  INSERT INTO WLT_API_MESSAGE (OBJECT_REF_ID, OBJECT_CHANNEL, OBJECT_SUBJECT, OBJECT_REQUEST_DATA, PROCESS_STATUS)
  VALUES (v_rref, p_channel, 'TRANSFER_REVERSAL',
          jsonb_build_object('orig_reference', p_orig_reference, 'reason', p_reason, 'initiator', p_initiator)::text, 'PENDING')
  ON CONFLICT (OBJECT_REF_ID) DO NOTHING;

  v_rev_tfr := nextval('seq_tfr');

  -- Claw back receiver B (− amount) with inline fund guard
  UPDATE WLT_ACCT SET ACTUAL_BAL = ACTUAL_BAL - v_amt, VERSION = VERSION + 1, LAST_TRAN_DATE = clock_timestamp()
   WHERE INTERNAL_KEY = v_b.INTERNAL_KEY
     AND ACTUAL_BAL - TOTAL_RESTRAINED_AMT >= v_amt
  RETURNING ACTUAL_BAL INTO v_b.ACTUAL_BAL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'INSUFFICIENT_FUNDS: receiver % cannot cover claw-back of %', v_to, v_amt USING ERRCODE = 'P0026';
  END IF;

  -- Refund sender A (+ amount + fee)
  UPDATE WLT_ACCT SET ACTUAL_BAL = ACTUAL_BAL + v_amt + v_fee, VERSION = VERSION + 1, LAST_TRAN_DATE = clock_timestamp()
   WHERE INTERNAL_KEY = v_a.INTERNAL_KEY
  RETURNING ACTUAL_BAL INTO v_a.ACTUAL_BAL;

  -- TRAN_HIST: RVTRF on B (DR claw-back) + RVTRF on A (CR refund) + RVFEE on A (CR fee refund)
  INSERT INTO WLT_TRAN_HIST (INTERNAL_KEY, TRAN_TYPE, TRAN_DATE, EFFECT_DATE, POST_DATE, VALUE_DATE,
     TRAN_AMT, CR_DR_MAINT_IND, PREVIOUS_BAL_AMT, ACTUAL_BAL_AMT,
     TFR_INTERNAL_KEY, REFERENCE, ORIG_SEQ_NO, CCY, SOURCE_TYPE, SOURCE_MODULE, TRAN_DESC, GROUP_ID, CLIENT_INFO)
  VALUES (v_b.INTERNAL_KEY, 'RVTRF', CURRENT_DATE, CURRENT_DATE, CURRENT_DATE, CURRENT_DATE,
     v_amt, 'DR', v_b.ACTUAL_BAL + v_amt, v_b.ACTUAL_BAL,
     v_rev_tfr, v_rref, v_orig_seq, v_b.CCY, p_channel, 'WLT',
     'Reverse transfer (claw-back): '||COALESCE(p_reason,'?'), v_b.GROUP_ID, v_ci_b)
  RETURNING SEQ_NO INTO v_seq_base;

  INSERT INTO WLT_TRAN_HIST (INTERNAL_KEY, TRAN_TYPE, TRAN_DATE, EFFECT_DATE, POST_DATE, VALUE_DATE,
     TRAN_AMT, CR_DR_MAINT_IND, PREVIOUS_BAL_AMT, ACTUAL_BAL_AMT,
     TFR_INTERNAL_KEY, TFR_SEQ_NO, REFERENCE, ORIG_SEQ_NO, CCY, SOURCE_TYPE, SOURCE_MODULE, TRAN_DESC, GROUP_ID, CLIENT_INFO)
  VALUES (v_a.INTERNAL_KEY, 'RVTRF', CURRENT_DATE, CURRENT_DATE, CURRENT_DATE, CURRENT_DATE,
     v_amt, 'CR', v_a.ACTUAL_BAL - v_amt - v_fee, v_a.ACTUAL_BAL - v_fee,
     v_rev_tfr, v_seq_base, v_rref, v_orig_seq, v_a.CCY, p_channel, 'WLT',
     'Reverse transfer (refund)', v_a.GROUP_ID, v_ci_a);

  IF v_fee > 0 THEN
    INSERT INTO WLT_TRAN_HIST (INTERNAL_KEY, TRAN_TYPE, TRAN_DATE, EFFECT_DATE, POST_DATE, VALUE_DATE,
       TRAN_AMT, CR_DR_MAINT_IND, PREVIOUS_BAL_AMT, ACTUAL_BAL_AMT,
       TFR_INTERNAL_KEY, TFR_SEQ_NO, REFERENCE, ORIG_SEQ_NO, CCY, SOURCE_MODULE, TRAN_DESC, GROUP_ID, CLIENT_INFO)
    VALUES (v_a.INTERNAL_KEY, 'RVFEE', CURRENT_DATE, CURRENT_DATE, CURRENT_DATE, CURRENT_DATE,
       v_fee, 'CR', v_a.ACTUAL_BAL - v_fee, v_a.ACTUAL_BAL,
       v_rev_tfr, v_seq_base, v_rref, v_orig_seq, v_a.CCY, 'WLT',
       'Refund transfer fee + VAT', v_a.GROUP_ID, v_ci_a);
  END IF;

  -- GL flip: CR A / DR B (principal); fee refund: DR 401.01 + DR 203.01 / CR A
  INSERT INTO WLT_BATCH (TRAN_KEY, SEQ_NO, GL_CODE, CLIENT_NO, ACCT_INTERNAL_KEY, AMOUNT, TRAN_NATURE, CCY, REFERENCE, POST_DATE, VALUE_DATE)
  VALUES
    (v_rev_tfr, 1, v_a_gl, v_a.CLIENT_NO, v_a.INTERNAL_KEY, v_amt, 'CR', v_a.CCY, v_rref, CURRENT_DATE, CURRENT_DATE),
    (v_rev_tfr, 2, v_b_gl, v_b.CLIENT_NO, v_b.INTERNAL_KEY, v_amt, 'DR', v_b.CCY, v_rref, CURRENT_DATE, CURRENT_DATE);
  IF v_fee > 0 THEN
    INSERT INTO WLT_BATCH (TRAN_KEY, SEQ_NO, GL_CODE, CLIENT_NO, ACCT_INTERNAL_KEY, AMOUNT, TRAN_NATURE, CCY, REFERENCE, POST_DATE, VALUE_DATE)
    VALUES
      (v_rev_tfr, 3, '401.01', v_a.CLIENT_NO, v_a.INTERNAL_KEY, v_net, 'DR', v_a.CCY, v_rref, CURRENT_DATE, CURRENT_DATE),
      (v_rev_tfr, 4, '203.01', v_a.CLIENT_NO, v_a.INTERNAL_KEY, v_vat, 'DR', v_a.CCY, v_rref, CURRENT_DATE, CURRENT_DATE),
      (v_rev_tfr, 5, v_a_gl,   v_a.CLIENT_NO, v_a.INTERNAL_KEY, v_fee, 'CR', v_a.CCY, v_rref, CURRENT_DATE, CURRENT_DATE);
  END IF;

  INSERT INTO WLT_OUTBOX (AGGREGATE_TYPE, AGGREGATE_ID, EVENT_TYPE, PARTITION_KEY, TOPIC, PAYLOAD, HEADERS)
  VALUES ('TRANSFER', v_rev_tfr::text, 'wallet.transfer.reversed.v1', v_from, 'wallet.transfers',
          jsonb_build_object('reversal_tfr_key', v_rev_tfr, 'orig_reference', p_orig_reference,
                             'from', v_from, 'to', v_to, 'amount', v_amt, 'fee_gross', v_fee,
                             'reason', p_reason, 'initiator', p_initiator),
          jsonb_build_object('traceparent', current_setting('app.trace_id', TRUE)))
  RETURNING EVENT_UUID INTO v_event;

  UPDATE WLT_API_MESSAGE SET PROCESS_STATUS='SUCCESS', HTTP_STATUS=200,
     OBJECT_RESPONE_DATA = jsonb_build_object('reversal_tfr_key', v_rev_tfr,
        'new_balance_from', v_a.ACTUAL_BAL, 'new_balance_to', v_b.ACTUAL_BAL, 'event_uuid', v_event)::text,
     PROCESSED_AT = clock_timestamp()
   WHERE OBJECT_REF_ID = v_rref;

  RETURN QUERY SELECT v_rev_tfr, FALSE, v_a.ACTUAL_BAL, v_b.ACTUAL_BAL, v_event;
END $$;

COMMIT;
