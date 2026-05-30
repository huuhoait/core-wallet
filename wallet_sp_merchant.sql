-- =============================================================================
-- wallet_sp_merchant.sql — Merchant hot-wallet SPs (sub-account sharding)
-- =============================================================================
-- Implements the pieces referenced by finance_transaction.md §3.6.6 / §4.8:
--   fn_resolve_shard_acct_no(group, reference)  — deterministic deposit routing
--   post_sweep_shard(shard, trigger, by)        — rebalance shard → settlement
--   post_merchant_withdraw(group, amount, ...)   — settlement withdraw + urgent sweep
--
-- Accounting: shard & settlement are both MERCHANT wallets (GL 201.02.001).
--   sweep   : DR shard 201.02.001 / CR settlement 201.02.001 (net 0 on GL)
--   MERCHWD : DR settlement 201.02.001 / CR nostro 101.02.001  (principal)
--             DR settlement 201.02.001 / CR 401.02 + CR 203.01 (fee + VAT)
-- =============================================================================

\set ON_ERROR_STOP on
BEGIN;

-- -----------------------------------------------------------------------------
-- fn_resolve_shard_acct_no — pick a shard deterministically by hash(reference)
--   DEP-08: replay of the same REFERENCE lands on the same shard.
--   Routes among the MATERIALISED shards (ordered by shard_index).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_resolve_shard_acct_no(p_group_id VARCHAR, p_reference VARCHAR)
RETURNS VARCHAR
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_n      int;
  v_acct   VARCHAR(20);
BEGIN
  SELECT count(*) INTO v_n FROM WLT_ACCT
   WHERE GROUP_ID = p_group_id AND ACCT_ROLE = 'SHARD' AND ACCT_STATUS = 'A';
  IF v_n = 0 THEN
    RAISE EXCEPTION 'GROUP_NOT_FOUND: no active shards for %', p_group_id USING ERRCODE = 'P0050';
  END IF;

  SELECT ACCT_NO INTO v_acct FROM WLT_ACCT
   WHERE GROUP_ID = p_group_id AND ACCT_ROLE = 'SHARD' AND ACCT_STATUS = 'A'
   ORDER BY SHARD_INDEX
   OFFSET (abs(hashtextextended(p_reference, 0)) % v_n) LIMIT 1;
  RETURN v_acct;
END $$;


-- -----------------------------------------------------------------------------
-- post_sweep_shard — move a shard's excess balance into its settlement wallet.
--   p_trigger: 'SCHEDULED' (leave shard_buffer) | 'URGENT' (sweep to 0, force).
--   Posts SWEEPO (DR shard) + SWEEPI (CR settlement), logs WLT_SWEEP_LOG.
--   Returns the swept amount + settlement balance after.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION post_sweep_shard(
  p_shard_acct_no VARCHAR,
  p_trigger       VARCHAR DEFAULT 'PERIODIC',   -- PERIODIC|THRESHOLD|URGENT|EOD
  p_triggered_by  VARCHAR DEFAULT 'SWEEP_WORKER'
)
RETURNS TABLE (swept_amount NUMERIC, settlement_bal_after NUMERIC, tfr_internal_key BIGINT)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog AS $$
#variable_conflict use_column
DECLARE
  v_shard   WLT_ACCT%ROWTYPE;
  v_settle  WLT_ACCT%ROWTYPE;
  v_grp     WLT_ACCT_GROUP%ROWTYPE;
  v_keep    NUMERIC(18,2);
  v_swept   NUMERIC(18,2);
  v_tfr     BIGINT;
  v_shard_before NUMERIC(18,2);
  v_seq_out BIGINT;
BEGIN
  PERFORM set_config('audit.actor', COALESCE(p_triggered_by,'sweep'), TRUE);
  PERFORM set_config('audit.channel', 'SWEEP', TRUE);

  SELECT * INTO v_shard FROM WLT_ACCT
   WHERE ACCT_NO = p_shard_acct_no AND ACCT_ROLE = 'SHARD' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'SHARD_NOT_FOUND: %', p_shard_acct_no USING ERRCODE = 'P0051'; END IF;

  SELECT * INTO v_grp    FROM WLT_ACCT_GROUP WHERE GROUP_ID = v_shard.GROUP_ID;
  SELECT * INTO v_settle FROM WLT_ACCT
   WHERE GROUP_ID = v_shard.GROUP_ID AND ACCT_ROLE = 'SETTLEMENT' FOR UPDATE;

  v_keep  := CASE WHEN p_trigger = 'URGENT' THEN 0 ELSE v_grp.SHARD_BUFFER END;
  v_swept := GREATEST(v_shard.ACTUAL_BAL - v_keep, 0);
  v_shard_before := v_shard.ACTUAL_BAL;

  IF v_swept <= 0 THEN
    -- nothing to sweep; log a no-op for auditability
    INSERT INTO WLT_SWEEP_LOG (GROUP_ID, SHARD_ACCT_NO, SETTLEMENT_ACCT_NO, SWEPT_AMOUNT,
                               SHARD_BAL_BEFORE, SHARD_BAL_AFTER, SETTLEMENT_BAL_AFTER,
                               TRIGGER_TYPE, TRIGGERED_BY, STATUS)
    VALUES (v_shard.GROUP_ID, p_shard_acct_no, v_settle.ACCT_NO, 0,
            v_shard_before, v_shard_before, v_settle.ACTUAL_BAL, p_trigger, p_triggered_by, 'SKIPPED');
    RETURN QUERY SELECT 0::numeric, v_settle.ACTUAL_BAL, NULL::bigint;
    RETURN;
  END IF;

  v_tfr := nextval('seq_tfr');

  -- move balance: shard ↓, settlement ↑
  UPDATE WLT_ACCT SET ACTUAL_BAL = ACTUAL_BAL - v_swept, VERSION = VERSION + 1,
                      LAST_TRAN_DATE = clock_timestamp()
   WHERE INTERNAL_KEY = v_shard.INTERNAL_KEY RETURNING ACTUAL_BAL INTO v_shard.ACTUAL_BAL;
  UPDATE WLT_ACCT SET ACTUAL_BAL = ACTUAL_BAL + v_swept, VERSION = VERSION + 1,
                      LAST_TRAN_DATE = clock_timestamp()
   WHERE INTERNAL_KEY = v_settle.INTERNAL_KEY RETURNING ACTUAL_BAL INTO v_settle.ACTUAL_BAL;

  -- TRAN_HIST: SWEEPO (shard) + SWEEPI (settlement), linked by tfr key
  INSERT INTO WLT_TRAN_HIST (INTERNAL_KEY, TRAN_TYPE, TRAN_DATE, EFFECT_DATE, POST_DATE, VALUE_DATE,
     TRAN_AMT, CR_DR_MAINT_IND, PREVIOUS_BAL_AMT, ACTUAL_BAL_AMT,
     TFR_INTERNAL_KEY, REFERENCE, CCY, SOURCE_TYPE, SOURCE_MODULE, TRAN_DESC, GROUP_ID, SHARD_INDEX)
  VALUES (v_shard.INTERNAL_KEY, 'SWEEPO', CURRENT_DATE, CURRENT_DATE, CURRENT_DATE, CURRENT_DATE,
     v_swept, 'DR', v_shard_before, v_shard.ACTUAL_BAL,
     v_tfr, 'SWEEP-'||v_tfr, v_shard.CCY, 'SWEEP', 'WLT', 'Sweep out to settlement',
     v_shard.GROUP_ID, v_shard.SHARD_INDEX)
  RETURNING SEQ_NO INTO v_seq_out;

  INSERT INTO WLT_TRAN_HIST (INTERNAL_KEY, TRAN_TYPE, TRAN_DATE, EFFECT_DATE, POST_DATE, VALUE_DATE,
     TRAN_AMT, CR_DR_MAINT_IND, PREVIOUS_BAL_AMT, ACTUAL_BAL_AMT,
     TFR_INTERNAL_KEY, TFR_SEQ_NO, REFERENCE, CCY, SOURCE_TYPE, SOURCE_MODULE, TRAN_DESC, GROUP_ID)
  VALUES (v_settle.INTERNAL_KEY, 'SWEEPI', CURRENT_DATE, CURRENT_DATE, CURRENT_DATE, CURRENT_DATE,
     v_swept, 'CR', v_settle.ACTUAL_BAL - v_swept, v_settle.ACTUAL_BAL,
     v_tfr, v_seq_out, 'SWEEP-'||v_tfr, v_settle.CCY, 'SWEEP', 'WLT', 'Sweep in from shard',
     v_settle.GROUP_ID);

  -- GL: both MERCHANT wallets → 201.02.001; DR shard / CR settlement (net 0)
  INSERT INTO WLT_BATCH (TRAN_KEY, SEQ_NO, GL_CODE, CLIENT_NO, ACCT_INTERNAL_KEY,
                         AMOUNT, TRAN_NATURE, CCY, REFERENCE, POST_DATE, VALUE_DATE)
  VALUES
    (v_tfr, 1, '201.02.001', v_shard.CLIENT_NO,  v_shard.INTERNAL_KEY,  v_swept, 'DR', v_shard.CCY,  'SWEEP-'||v_tfr, CURRENT_DATE, CURRENT_DATE),
    (v_tfr, 2, '201.02.001', v_settle.CLIENT_NO, v_settle.INTERNAL_KEY, v_swept, 'CR', v_settle.CCY, 'SWEEP-'||v_tfr, CURRENT_DATE, CURRENT_DATE);

  INSERT INTO WLT_SWEEP_LOG (GROUP_ID, SHARD_ACCT_NO, SETTLEMENT_ACCT_NO, SWEPT_AMOUNT,
                             SHARD_BAL_BEFORE, SHARD_BAL_AFTER, SETTLEMENT_BAL_AFTER,
                             TFR_INTERNAL_KEY, TRIGGER_TYPE, TRIGGERED_BY, STATUS)
  VALUES (v_shard.GROUP_ID, p_shard_acct_no, v_settle.ACCT_NO, v_swept,
          v_shard_before, v_shard.ACTUAL_BAL, v_settle.ACTUAL_BAL, v_tfr, p_trigger, p_triggered_by, 'SUCCESS');

  RETURN QUERY SELECT v_swept, v_settle.ACTUAL_BAL, v_tfr;
END $$;


-- -----------------------------------------------------------------------------
-- post_merchant_withdraw — withdraw from the settlement wallet (§4.8).
--   p_auto_sweep=TRUE (default): on settlement shortfall but group sufficient,
--     sweep all shards (URGENT) into settlement IN-SP, then post → POSTED.
--   p_auto_sweep=FALSE: return 'SETTLEMENT_SWEEP_REQUIRED' for Go to orchestrate
--     SweepGroupParallel + retry (the doc's parallel path, MWD-05).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION post_merchant_withdraw(
  p_group_id      VARCHAR,
  p_amount        NUMERIC(18,2),
  p_reference     VARCHAR(64),
  p_ext_payout_ref VARCHAR(64) DEFAULT NULL,
  p_auto_sweep    BOOLEAN DEFAULT TRUE,
  p_channel       VARCHAR(20) DEFAULT 'MOBILE',
  p_actor         VARCHAR(64) DEFAULT NULL
)
RETURNS TABLE (
  tfr_internal_key  BIGINT,
  status            VARCHAR,
  amount            NUMERIC(18,2),
  fee_gross         NUMERIC(18,2),
  vat_amount        NUMERIC(18,2),
  total_deducted    NUMERIC(18,2),
  settlement_balance_after NUMERIC(18,2),
  event_uuid        UUID
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog AS $$
#variable_conflict use_column
DECLARE
  v_actor    VARCHAR(64) := COALESCE(p_actor, session_user);
  v_grp      WLT_ACCT_GROUP%ROWTYPE;
  v_settle   WLT_ACCT%ROWTYPE;
  v_def      WLT_TRAN_DEF%ROWTYPE;
  v_fee      NUMERIC(18,2) := 0;
  v_vat      NUMERIC(18,2) := 0;
  v_net      NUMERIC(18,2) := 0;
  v_total    NUMERIC(18,2);
  v_grp_avail NUMERIC(18,2);
  v_set_avail NUMERIC(18,2);
  v_tfr      BIGINT;
  v_seq_base BIGINT;
  v_event    UUID;
  v_cinfo    JSONB;
  v_liab_gl  VARCHAR(32);
  v_existing WLT_API_MESSAGE%ROWTYPE;
  v_shard    RECORD;
BEGIN
  PERFORM set_config('audit.actor', v_actor, TRUE);
  PERFORM set_config('audit.channel', p_channel, TRUE);

  -- Phase 0: validate
  SELECT * INTO v_def FROM WLT_TRAN_DEF WHERE TRAN_TYPE = 'MERCHWD';
  IF NOT FOUND OR v_def.STATUS <> 'A' THEN RAISE EXCEPTION 'TRAN_TYPE_INACTIVE: MERCHWD' USING ERRCODE='P0020'; END IF;
  IF p_amount IS NULL OR p_amount < v_def.MIN_TRAN_AMT OR p_amount > v_def.MAX_TRAN_AMT THEN
    RAISE EXCEPTION 'AMOUNT_OUT_OF_RANGE: %', p_amount USING ERRCODE='P0024';
  END IF;

  SELECT * INTO v_grp FROM WLT_ACCT_GROUP WHERE GROUP_ID = p_group_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'GROUP_NOT_FOUND: %', p_group_id USING ERRCODE='P0050'; END IF;
  IF v_grp.GROUP_STATUS <> 'A' THEN RAISE EXCEPTION 'GROUP_NOT_ACTIVE: %', v_grp.GROUP_STATUS USING ERRCODE='P0022'; END IF;

  -- Phase 1: idempotency
  SELECT * INTO v_existing FROM WLT_API_MESSAGE WHERE OBJECT_REF_ID = p_reference FOR UPDATE;
  IF FOUND AND v_existing.PROCESS_STATUS = 'SUCCESS' THEN
    RETURN QUERY SELECT (v_existing.OBJECT_RESPONE_DATA::jsonb->>'tfr_internal_key')::bigint,
      'DUPLICATE'::varchar,
      (v_existing.OBJECT_RESPONE_DATA::jsonb->>'amount')::numeric,
      (v_existing.OBJECT_RESPONE_DATA::jsonb->>'fee_gross')::numeric,
      (v_existing.OBJECT_RESPONE_DATA::jsonb->>'vat_amount')::numeric,
      (v_existing.OBJECT_RESPONE_DATA::jsonb->>'total_deducted')::numeric,
      (v_existing.OBJECT_RESPONE_DATA::jsonb->>'settlement_balance_after')::numeric,
      (v_existing.OBJECT_RESPONE_DATA::jsonb->>'event_uuid')::uuid;
    RETURN;
  END IF;
  INSERT INTO WLT_API_MESSAGE (OBJECT_REF_ID, OBJECT_CHANNEL, OBJECT_SUBJECT, OBJECT_REQUEST_DATA, PROCESS_STATUS)
  VALUES (p_reference, p_channel, 'MERCHANT_WITHDRAW',
          jsonb_build_object('group_id', p_group_id, 'amount', p_amount)::text, 'PENDING')
  ON CONFLICT (OBJECT_REF_ID) DO NOTHING;

  -- Lock settlement wallet
  SELECT * INTO v_settle FROM WLT_ACCT
   WHERE GROUP_ID = p_group_id AND ACCT_ROLE = 'SETTLEMENT' FOR UPDATE;

  -- MWD-03: group-level DR restraint
  IF EXISTS (SELECT 1 FROM WLT_RESTRAINTS r
              WHERE (r.GROUP_ID = p_group_id OR r.INTERNAL_KEY = v_settle.INTERNAL_KEY)
                AND r.STATUS = 'A' AND r.RESTRAINT_TYPE IN ('DEBIT','ALL')) THEN
    RAISE EXCEPTION 'GROUP_RESTRAINED: %', p_group_id USING ERRCODE='P0025';
  END IF;

  -- Fee + VAT (MERCHWD: PERCENT 0.05%, clamp 22k..110k, VAT inclusive)
  v_fee   := LEAST(GREATEST(p_amount * v_def.FEE_RATE, v_def.FEE_MIN), v_def.FEE_MAX);
  v_vat   := ROUND(v_fee * v_def.VAT_RATE / (1 + v_def.VAT_RATE), 2);
  v_net   := v_fee - v_vat;
  v_total := p_amount + v_fee;

  -- Availability: settlement vs whole group
  v_set_avail := v_settle.ACTUAL_BAL - v_settle.TOTAL_RESTRAINED_AMT;
  SELECT total_available INTO v_grp_avail FROM v_wlt_group_balance WHERE group_id = p_group_id;

  IF v_grp_avail < v_total THEN
    RAISE EXCEPTION 'INSUFFICIENT_FUNDS: group_available=%, required=%', v_grp_avail, v_total USING ERRCODE='P0026';
  END IF;

  IF v_set_avail < v_total THEN
    IF NOT p_auto_sweep THEN
      -- MWD-05: let Go orchestrate parallel sweep then retry
      RETURN QUERY SELECT NULL::bigint, 'SETTLEMENT_SWEEP_REQUIRED'::varchar,
                          p_amount, v_fee, v_vat, v_total, v_set_avail, NULL::uuid;
      RETURN;
    END IF;
    -- MWD-07 (DB-side fallback): URGENT sweep every shard into settlement, then re-read
    FOR v_shard IN SELECT ACCT_NO FROM WLT_ACCT
                    WHERE GROUP_ID = p_group_id AND ACCT_ROLE='SHARD' AND ACCT_STATUS='A'
                    ORDER BY SHARD_INDEX LOOP
      PERFORM post_sweep_shard(v_shard.ACCT_NO, 'URGENT', 'WITHDRAW_TRIGGERED');
    END LOOP;
    SELECT * INTO v_settle FROM WLT_ACCT WHERE INTERNAL_KEY = v_settle.INTERNAL_KEY FOR UPDATE;
    v_set_avail := v_settle.ACTUAL_BAL - v_settle.TOTAL_RESTRAINED_AMT;
    IF v_set_avail < v_total THEN
      RAISE EXCEPTION 'INSUFFICIENT_FUNDS: settlement still short after sweep (avail=%, need=%)', v_set_avail, v_total USING ERRCODE='P0026';
    END IF;
  END IF;

  -- Phase 4: atomic debit of settlement (inline fund guard + version CAS)
  v_tfr  := nextval('seq_tfr');
  v_cinfo := fn_build_client_info(v_settle.CLIENT_NO);

  UPDATE WLT_ACCT SET ACTUAL_BAL = ACTUAL_BAL - v_total, VERSION = VERSION + 1, LAST_TRAN_DATE = clock_timestamp()
   WHERE INTERNAL_KEY = v_settle.INTERNAL_KEY AND VERSION = v_settle.VERSION
     AND ACTUAL_BAL - TOTAL_RESTRAINED_AMT >= v_total
  RETURNING ACTUAL_BAL INTO v_settle.ACTUAL_BAL;
  IF NOT FOUND THEN RAISE EXCEPTION 'VERSION_CONFLICT' USING ERRCODE='40001'; END IF;

  -- TRAN_HIST: MERCHWD (principal) + FEEMW (fee), fee leg → origin via TFR_SEQ_NO
  INSERT INTO WLT_TRAN_HIST (INTERNAL_KEY, TRAN_TYPE, TRAN_DATE, EFFECT_DATE, POST_DATE, VALUE_DATE,
     TRAN_AMT, CR_DR_MAINT_IND, PREVIOUS_BAL_AMT, ACTUAL_BAL_AMT,
     TFR_INTERNAL_KEY, REFERENCE, CCY, SOURCE_TYPE, SOURCE_MODULE, TRAN_DESC, GROUP_ID, CLIENT_INFO)
  VALUES (v_settle.INTERNAL_KEY, 'MERCHWD', CURRENT_DATE, CURRENT_DATE, CURRENT_DATE, CURRENT_DATE,
     p_amount, 'DR', v_settle.ACTUAL_BAL + v_total, v_settle.ACTUAL_BAL + v_fee,
     v_tfr, p_reference, v_settle.CCY, p_channel, 'WLT', 'Merchant withdraw', p_group_id, v_cinfo)
  RETURNING SEQ_NO INTO v_seq_base;

  IF v_fee > 0 THEN
    INSERT INTO WLT_TRAN_HIST (INTERNAL_KEY, TRAN_TYPE, TRAN_DATE, EFFECT_DATE, POST_DATE, VALUE_DATE,
       TRAN_AMT, CR_DR_MAINT_IND, PREVIOUS_BAL_AMT, ACTUAL_BAL_AMT,
       TFR_INTERNAL_KEY, TFR_SEQ_NO, REFERENCE, CCY, SOURCE_MODULE, TRAN_DESC, GROUP_ID, CLIENT_INFO)
    VALUES (v_settle.INTERNAL_KEY, 'FEEMW', CURRENT_DATE, CURRENT_DATE, CURRENT_DATE, CURRENT_DATE,
       v_fee, 'DR', v_settle.ACTUAL_BAL + v_fee, v_settle.ACTUAL_BAL,
       v_tfr, v_seq_base, p_reference, v_settle.CCY, 'WLT', 'Fee + VAT for merchant withdraw', p_group_id, v_cinfo);
  END IF;

  -- GL: DR settlement liability / CR nostro + fee legs. Resolve the liability GL
  -- into a variable first (the FK is checked at INSERT, so it must be a real code).
  SELECT GL_CODE_LIAB INTO v_liab_gl FROM WLT_ACCT_TYPE WHERE ACCT_TYPE = v_settle.ACCT_TYPE;
  INSERT INTO WLT_BATCH (TRAN_KEY, SEQ_NO, GL_CODE, CLIENT_NO, ACCT_INTERNAL_KEY, AMOUNT, TRAN_NATURE, CCY, REFERENCE, POST_DATE, VALUE_DATE)
  VALUES
    (v_tfr, 1, v_liab_gl,            v_settle.CLIENT_NO, v_settle.INTERNAL_KEY, p_amount, 'DR', v_settle.CCY, p_reference, CURRENT_DATE, CURRENT_DATE),
    (v_tfr, 2, v_def.CONTRA_GL_CODE, v_settle.CLIENT_NO, v_settle.INTERNAL_KEY, p_amount, 'CR', v_settle.CCY, p_reference, CURRENT_DATE, CURRENT_DATE);
  IF v_fee > 0 THEN
    INSERT INTO WLT_BATCH (TRAN_KEY, SEQ_NO, GL_CODE, CLIENT_NO, ACCT_INTERNAL_KEY, AMOUNT, TRAN_NATURE, CCY, REFERENCE, POST_DATE, VALUE_DATE)
    VALUES
      (v_tfr, 3, v_liab_gl,         v_settle.CLIENT_NO, v_settle.INTERNAL_KEY, v_fee, 'DR', v_settle.CCY, p_reference, CURRENT_DATE, CURRENT_DATE),
      (v_tfr, 4, v_def.FEE_GL_CODE, v_settle.CLIENT_NO, v_settle.INTERNAL_KEY, v_net, 'CR', v_settle.CCY, p_reference, CURRENT_DATE, CURRENT_DATE),
      (v_tfr, 5, v_def.VAT_GL_CODE, v_settle.CLIENT_NO, v_settle.INTERNAL_KEY, v_vat, 'CR', v_settle.CCY, p_reference, CURRENT_DATE, CURRENT_DATE);
  END IF;

  -- Outbox: Treasury consumes for batch disbursement (MWD-09)
  INSERT INTO WLT_OUTBOX (AGGREGATE_TYPE, AGGREGATE_ID, EVENT_TYPE, PARTITION_KEY, TOPIC, PAYLOAD, HEADERS)
  VALUES ('MERCHANT_WITHDRAW', v_tfr::text, 'wallet.merchant_withdraw.posted.v1', p_group_id, 'wallet.withdrawals',
          jsonb_build_object('tfr_internal_key', v_tfr, 'group_id', p_group_id, 'settlement_acct', v_settle.ACCT_NO,
                             'amount', p_amount, 'fee_gross', v_fee, 'vat_amount', v_vat,
                             'ext_payout_ref', p_ext_payout_ref, 'ccy', v_settle.CCY),
          jsonb_build_object('traceparent', current_setting('app.trace_id', TRUE)))
  RETURNING EVENT_UUID INTO v_event;

  -- Phase 5: close idempotency
  UPDATE WLT_API_MESSAGE SET PROCESS_STATUS='SUCCESS', HTTP_STATUS=200,
     OBJECT_RESPONE_DATA = jsonb_build_object('tfr_internal_key', v_tfr, 'amount', p_amount,
       'fee_gross', v_fee, 'vat_amount', v_vat, 'total_deducted', v_total,
       'settlement_balance_after', v_settle.ACTUAL_BAL, 'event_uuid', v_event)::text,
     PROCESSED_AT = clock_timestamp()
   WHERE OBJECT_REF_ID = p_reference;

  RETURN QUERY SELECT v_tfr, 'SUCCESS'::varchar, p_amount, v_fee, v_vat, v_total, v_settle.ACTUAL_BAL, v_event;
END $$;


-- -----------------------------------------------------------------------------
-- post_merchant_withdraw_reversal — idempotent credit-back of a merchant withdraw.
--   Locates the original via WLT_API_MESSAGE(orig_reference). Credits the
--   settlement wallet back principal + fee, posts RVMWD + RVFEE (refund fee/VAT),
--   flips the GL legs. Idempotent on RVMWD-<orig_reference>.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION post_merchant_withdraw_reversal(
  p_orig_reference VARCHAR(64),
  p_fail_code      VARCHAR(40),
  p_fail_reason    VARCHAR(500),
  p_initiator      VARCHAR(32) DEFAULT 'OPS_MANUAL',
  p_channel        VARCHAR(20) DEFAULT 'SYS',
  p_actor          VARCHAR(64) DEFAULT NULL
)
RETURNS TABLE (
  reversal_tfr_key         BIGINT,
  was_already_reversed     BOOLEAN,
  settlement_balance_after NUMERIC(18,2),
  event_uuid               UUID
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog AS $$
#variable_conflict use_column
DECLARE
  v_actor  VARCHAR(64) := COALESCE(p_actor, session_user);
  v_orig   WLT_API_MESSAGE%ROWTYPE;
  v_rev    WLT_API_MESSAGE%ROWTYPE;
  v_rref   VARCHAR(64) := left('RVMWD-'||p_orig_reference, 64);
  v_grp    VARCHAR(32);
  v_amt NUMERIC(18,2); v_fee NUMERIC(18,2); v_vat NUMERIC(18,2); v_net NUMERIC(18,2);
  v_orig_tfr BIGINT; v_orig_seq BIGINT;
  v_settle WLT_ACCT%ROWTYPE;
  v_def    WLT_TRAN_DEF%ROWTYPE;
  v_liab_gl VARCHAR(32);
  v_rev_tfr BIGINT; v_event UUID; v_cinfo JSONB; v_seq_base BIGINT;
BEGIN
  PERFORM set_config('audit.actor', v_actor, TRUE);
  PERFORM set_config('audit.channel', p_channel, TRUE);

  -- Idempotent on the reversal key
  SELECT * INTO v_rev FROM WLT_API_MESSAGE WHERE OBJECT_REF_ID = v_rref FOR UPDATE;
  IF FOUND AND v_rev.PROCESS_STATUS = 'SUCCESS' THEN
    RETURN QUERY SELECT (v_rev.OBJECT_RESPONE_DATA::jsonb->>'reversal_tfr_key')::bigint, TRUE,
                        (v_rev.OBJECT_RESPONE_DATA::jsonb->>'settlement_balance_after')::numeric,
                        (v_rev.OBJECT_RESPONE_DATA::jsonb->>'event_uuid')::uuid;
    RETURN;
  END IF;

  -- Load the original posted merchant withdraw
  SELECT * INTO v_orig FROM WLT_API_MESSAGE
   WHERE OBJECT_REF_ID = p_orig_reference AND OBJECT_SUBJECT = 'MERCHANT_WITHDRAW' FOR UPDATE;
  IF NOT FOUND OR v_orig.PROCESS_STATUS <> 'SUCCESS' THEN
    RAISE EXCEPTION 'WD_NOT_FOUND: merchant withdraw % not posted', p_orig_reference USING ERRCODE = 'P0040';
  END IF;

  v_grp      := v_orig.OBJECT_REQUEST_DATA::jsonb->>'group_id';
  v_orig_tfr := (v_orig.OBJECT_RESPONE_DATA::jsonb->>'tfr_internal_key')::bigint;
  v_amt      := (v_orig.OBJECT_RESPONE_DATA::jsonb->>'amount')::numeric;
  v_fee      := (v_orig.OBJECT_RESPONE_DATA::jsonb->>'fee_gross')::numeric;
  v_vat      := (v_orig.OBJECT_RESPONE_DATA::jsonb->>'vat_amount')::numeric;
  v_net      := v_fee - v_vat;

  SELECT * INTO v_settle FROM WLT_ACCT WHERE GROUP_ID = v_grp AND ACCT_ROLE = 'SETTLEMENT' FOR UPDATE;
  SELECT * INTO v_def    FROM WLT_TRAN_DEF WHERE TRAN_TYPE = 'MERCHWD';
  SELECT GL_CODE_LIAB INTO v_liab_gl FROM WLT_ACCT_TYPE WHERE ACCT_TYPE = v_settle.ACCT_TYPE;
  SELECT SEQ_NO INTO v_orig_seq FROM WLT_TRAN_HIST WHERE TFR_INTERNAL_KEY = v_orig_tfr AND TRAN_TYPE = 'MERCHWD' LIMIT 1;
  v_cinfo := fn_build_client_info(v_settle.CLIENT_NO);

  INSERT INTO WLT_API_MESSAGE (OBJECT_REF_ID, OBJECT_CHANNEL, OBJECT_SUBJECT, OBJECT_REQUEST_DATA, PROCESS_STATUS)
  VALUES (v_rref, p_channel, 'MERCHANT_WITHDRAW_REVERSAL',
          jsonb_build_object('orig_reference', p_orig_reference, 'fail_code', p_fail_code, 'initiator', p_initiator)::text, 'PENDING')
  ON CONFLICT (OBJECT_REF_ID) DO NOTHING;

  v_rev_tfr := nextval('seq_tfr');

  -- Credit back settlement: principal + fee
  UPDATE WLT_ACCT SET ACTUAL_BAL = ACTUAL_BAL + v_amt + v_fee, VERSION = VERSION + 1, LAST_TRAN_DATE = clock_timestamp()
   WHERE INTERNAL_KEY = v_settle.INTERNAL_KEY RETURNING ACTUAL_BAL INTO v_settle.ACTUAL_BAL;

  -- RVMWD (credit-back principal)
  INSERT INTO WLT_TRAN_HIST (INTERNAL_KEY, TRAN_TYPE, TRAN_DATE, EFFECT_DATE, POST_DATE, VALUE_DATE,
     TRAN_AMT, CR_DR_MAINT_IND, PREVIOUS_BAL_AMT, ACTUAL_BAL_AMT,
     TFR_INTERNAL_KEY, REFERENCE, ORIG_SEQ_NO, CCY, SOURCE_TYPE, SOURCE_MODULE, TRAN_DESC, GROUP_ID, CLIENT_INFO)
  VALUES (v_settle.INTERNAL_KEY, 'RVMWD', CURRENT_DATE, CURRENT_DATE, CURRENT_DATE, CURRENT_DATE,
     v_amt, 'CR', v_settle.ACTUAL_BAL - v_amt - v_fee, v_settle.ACTUAL_BAL - v_fee,
     v_rev_tfr, v_rref, v_orig_seq, v_settle.CCY, p_channel, 'WLT',
     'Reverse merchant withdraw: '||COALESCE(p_fail_code,'?'), v_grp, v_cinfo)
  RETURNING SEQ_NO INTO v_seq_base;

  IF v_fee > 0 THEN
    INSERT INTO WLT_TRAN_HIST (INTERNAL_KEY, TRAN_TYPE, TRAN_DATE, EFFECT_DATE, POST_DATE, VALUE_DATE,
       TRAN_AMT, CR_DR_MAINT_IND, PREVIOUS_BAL_AMT, ACTUAL_BAL_AMT,
       TFR_INTERNAL_KEY, TFR_SEQ_NO, REFERENCE, ORIG_SEQ_NO, CCY, SOURCE_MODULE, TRAN_DESC, GROUP_ID, CLIENT_INFO)
    VALUES (v_settle.INTERNAL_KEY, 'RVFEE', CURRENT_DATE, CURRENT_DATE, CURRENT_DATE, CURRENT_DATE,
       v_fee, 'CR', v_settle.ACTUAL_BAL - v_fee, v_settle.ACTUAL_BAL,
       v_rev_tfr, v_seq_base, v_rref, v_orig_seq, v_settle.CCY, 'WLT',
       'Refund fee + VAT (merchant withdraw)', v_grp, v_cinfo);
  END IF;

  -- GL flip: DR nostro / CR settlement (principal); fee: DR 401.02 + DR 203.01 / CR settlement
  INSERT INTO WLT_BATCH (TRAN_KEY, SEQ_NO, GL_CODE, CLIENT_NO, ACCT_INTERNAL_KEY, AMOUNT, TRAN_NATURE, CCY, REFERENCE, POST_DATE, VALUE_DATE)
  VALUES
    (v_rev_tfr, 1, v_def.CONTRA_GL_CODE, v_settle.CLIENT_NO, v_settle.INTERNAL_KEY, v_amt, 'DR', v_settle.CCY, v_rref, CURRENT_DATE, CURRENT_DATE),
    (v_rev_tfr, 2, v_liab_gl,            v_settle.CLIENT_NO, v_settle.INTERNAL_KEY, v_amt, 'CR', v_settle.CCY, v_rref, CURRENT_DATE, CURRENT_DATE);
  IF v_fee > 0 THEN
    INSERT INTO WLT_BATCH (TRAN_KEY, SEQ_NO, GL_CODE, CLIENT_NO, ACCT_INTERNAL_KEY, AMOUNT, TRAN_NATURE, CCY, REFERENCE, POST_DATE, VALUE_DATE)
    VALUES
      (v_rev_tfr, 3, v_def.FEE_GL_CODE, v_settle.CLIENT_NO, v_settle.INTERNAL_KEY, v_net, 'DR', v_settle.CCY, v_rref, CURRENT_DATE, CURRENT_DATE),
      (v_rev_tfr, 4, v_def.VAT_GL_CODE, v_settle.CLIENT_NO, v_settle.INTERNAL_KEY, v_vat, 'DR', v_settle.CCY, v_rref, CURRENT_DATE, CURRENT_DATE),
      (v_rev_tfr, 5, v_liab_gl,         v_settle.CLIENT_NO, v_settle.INTERNAL_KEY, v_fee, 'CR', v_settle.CCY, v_rref, CURRENT_DATE, CURRENT_DATE);
  END IF;

  INSERT INTO WLT_OUTBOX (AGGREGATE_TYPE, AGGREGATE_ID, EVENT_TYPE, PARTITION_KEY, TOPIC, PAYLOAD, HEADERS)
  VALUES ('MERCHANT_WITHDRAW', v_rev_tfr::text, 'wallet.merchant_withdraw.reversed.v1', v_grp, 'wallet.withdrawals',
          jsonb_build_object('reversal_tfr_key', v_rev_tfr, 'orig_reference', p_orig_reference, 'group_id', v_grp,
                             'amount', v_amt, 'fee_gross', v_fee, 'fail_code', p_fail_code, 'initiator', p_initiator),
          jsonb_build_object('traceparent', current_setting('app.trace_id', TRUE)))
  RETURNING EVENT_UUID INTO v_event;

  UPDATE WLT_API_MESSAGE SET PROCESS_STATUS='SUCCESS', HTTP_STATUS=200,
     OBJECT_RESPONE_DATA = jsonb_build_object('reversal_tfr_key', v_rev_tfr,
        'settlement_balance_after', v_settle.ACTUAL_BAL, 'event_uuid', v_event)::text,
     PROCESSED_AT = clock_timestamp()
   WHERE OBJECT_REF_ID = v_rref;

  RETURN QUERY SELECT v_rev_tfr, FALSE, v_settle.ACTUAL_BAL, v_event;
END $$;

COMMIT;
