-- =============================================================================
-- Core Wallet — Stored Procedure catalog (Y1 / 20 TPS scope)
--
-- Deploy order:
--   psql -d wallet -f wallet_schema.sql    (creates tables + audit trigger)
--   psql -d wallet -f wallet_sp.sql        (this file — adds business SPs)
--
-- Contract for every SP:
--   - Phase 0  input guards
--   - Phase 1  idempotency gate (WLT_API_MESSAGE FOR UPDATE)
--   - Phase 2  validate (no lock — pure SELECTs)
--   - Phase 3  build CLIENT_INFO snapshot
--   - Phase 4  atomic posting (UPDATE WLT_ACCT VERSION-CAS → INSERTs → OUTBOX)
--   - Phase 5  close idempotency
--
-- Audit context: every SP calls set_config('audit.actor', ..., TRUE) and
-- set_config('audit.channel', ..., TRUE) at entry. Trigger trg_audit_cols
-- (BEFORE INSERT/UPDATE on every table) auto-fills CHANNEL/CREATED_*/UPDATED_*.
--
-- PII: beneficiary_acct on withdraw is encrypted via pgp_sym_encrypt with a
-- DEK from current_setting('app.pii_dek'). Set per-database for dev:
--   ALTER DATABASE wallet SET app.pii_dek = 'dev_only_change_in_prod_kms';
-- =============================================================================

\set ON_ERROR_STOP on

BEGIN;

-- Ensure dev DEK is set for pgp_sym_encrypt (override in prod via KMS).
ALTER DATABASE wallet SET app.pii_dek = 'dev_only_change_in_prod_kms';


-- =============================================================================
-- §1. HELPER FUNCTIONS
-- =============================================================================

-- Build the CLIENT_INFO JSONB snapshot from FM_CLIENT + FM_CLIENT_INDVL + WLT_CLIENT_KYC.
-- STABLE = same input → same output within a TX, can be inlined by planner.
CREATE OR REPLACE FUNCTION fn_build_client_info(p_client_no VARCHAR)
RETURNS JSONB
LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'client_no',         c.CLIENT_NO,
    'kyc_tier',          k.KYC_TIER,
    'name_initials',     left(coalesce(c.CLIENT_SHORT, c.CLIENT_NAME, ''), 3),
    'residence_status',  i.RESIDENT_STATUS,
    'country_loc',       c.COUNTRY_LOC,
    'country_citizen',   c.COUNTRY_CITIZEN,
    'risk_level',        k.RISK_LEVEL,
    'customer_segment',  c.CLIENT_GRP
  )
    FROM FM_CLIENT c
    LEFT JOIN FM_CLIENT_INDVL i ON i.CLIENT_NO = c.CLIENT_NO
    LEFT JOIN WLT_CLIENT_KYC  k ON k.CLIENT_NO = c.CLIENT_NO
   WHERE c.CLIENT_NO = p_client_no
$$;

-- Validate METADATA JSONB (size ≤ 1 KB, no P1 keys).
CREATE OR REPLACE FUNCTION fn_validate_metadata(p_metadata JSONB)
RETURNS VOID
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  IF p_metadata IS NULL THEN RETURN; END IF;
  IF octet_length(p_metadata::text) > 1024 THEN
    RAISE EXCEPTION 'METADATA_TOO_LARGE: %', octet_length(p_metadata::text)
      USING ERRCODE = 'P0011';
  END IF;
  IF p_metadata ?| ARRAY['phone','email','cccd','passport','full_name','bank_acct_no'] THEN
    RAISE EXCEPTION 'METADATA_HAS_P1: forbidden keys present' USING ERRCODE = 'P0012';
  END IF;
END $$;


-- =============================================================================
-- §2. post_topup — Treasury credits the customer wallet (s2s)
-- =============================================================================

CREATE OR REPLACE FUNCTION post_topup(
  p_acct_no    VARCHAR(20),
  p_amount     NUMERIC(18,2),
  p_reference  VARCHAR(64),
  p_metadata   JSONB DEFAULT '{}'::jsonb,
  p_channel    VARCHAR(20) DEFAULT 'TREASURY',
  p_actor      VARCHAR(64) DEFAULT NULL
)
RETURNS TABLE (
  tfr_internal_key  BIGINT,
  status            VARCHAR,
  new_balance       NUMERIC(18,2),
  event_uuid        UUID
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
#variable_conflict use_column
DECLARE
  v_actor       VARCHAR(64) := COALESCE(p_actor, session_user);
  v_acct        WLT_ACCT%ROWTYPE;
  v_def         WLT_TRAN_DEF%ROWTYPE;
  v_acct_type   WLT_ACCT_TYPE%ROWTYPE;
  v_tfr_key     BIGINT;
  v_event_uuid  UUID;
  v_client_info JSONB;
  v_existing    WLT_API_MESSAGE%ROWTYPE;
BEGIN
  -- Audit context (defensive — Go middleware should also set these)
  PERFORM set_config('audit.actor',   v_actor,   TRUE);
  PERFORM set_config('audit.channel', p_channel, TRUE);

  -- ─── Phase 0: input guards ───────────────────────────────────────────
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'INVALID_AMOUNT' USING ERRCODE = 'P0010';
  END IF;
  PERFORM fn_validate_metadata(p_metadata);

  -- ─── Phase 1: idempotency gate ──────────────────────────────────────
  SELECT * INTO v_existing FROM WLT_API_MESSAGE
   WHERE OBJECT_REF_ID = p_reference FOR UPDATE;
  IF FOUND AND v_existing.PROCESS_STATUS = 'SUCCESS' THEN
    RETURN QUERY
    SELECT (v_existing.OBJECT_RESPONE_DATA::jsonb->>'tfr_internal_key')::bigint,
           'DUPLICATE'::varchar,
           (v_existing.OBJECT_RESPONE_DATA::jsonb->>'new_balance')::numeric,
           (v_existing.OBJECT_RESPONE_DATA::jsonb->>'event_uuid')::uuid;
    RETURN;
  END IF;
  INSERT INTO WLT_API_MESSAGE (OBJECT_REF_ID, OBJECT_CHANNEL, OBJECT_SUBJECT,
                               OBJECT_REQUEST_DATA, PROCESS_STATUS)
  VALUES (p_reference, p_channel, 'TOPUP',
          jsonb_build_object('acct_no', p_acct_no, 'amount', p_amount)::text,
          'PENDING')
  ON CONFLICT (OBJECT_REF_ID) DO NOTHING;

  -- ─── Phase 2: validate ─────────────────────────────────────────────
  SELECT * INTO v_def       FROM WLT_TRAN_DEF  WHERE TRAN_TYPE = 'TOPUP';
  IF v_def.STATUS <> 'A' THEN
    RAISE EXCEPTION 'TRAN_TYPE_INACTIVE' USING ERRCODE = 'P0020';
  END IF;

  SELECT * INTO v_acct      FROM WLT_ACCT      WHERE ACCT_NO = p_acct_no;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ACCT_NOT_FOUND: %', p_acct_no USING ERRCODE = 'P0021';
  END IF;
  -- Topups target customer wallets only. SHARD/SETTLEMENT are internal group
  -- sub-accounts fed by sweeps/settlement (wallet_sp_merchant.sql); reject them
  -- so a mis-routed/hostile ACCT_NO cannot credit a hot-wallet sub-account.
  IF v_acct.ACCT_ROLE <> 'STANDALONE' THEN
    RAISE EXCEPTION 'ACCT_ROLE_INVALID: % is a % wallet (not STANDALONE)', p_acct_no, v_acct.ACCT_ROLE USING ERRCODE = 'P0028';
  END IF;
  IF v_acct.ACCT_STATUS <> 'A' THEN
    RAISE EXCEPTION 'ACCT_NOT_ACTIVE: status=%', v_acct.ACCT_STATUS USING ERRCODE = 'P0022';
  END IF;
  IF v_acct.CR_BLOCKED = 'Y' THEN
    RAISE EXCEPTION 'CR_RESTRAINT_ACTIVE' USING ERRCODE = 'P0029';
  END IF;

  SELECT * INTO v_acct_type FROM WLT_ACCT_TYPE WHERE ACCT_TYPE = v_acct.ACCT_TYPE;

  -- ─── Phase 3: build client snapshot ────────────────────────────────
  v_client_info := fn_build_client_info(v_acct.CLIENT_NO);

  -- ─── Phase 4: atomic posting ───────────────────────────────────────
  v_tfr_key := nextval('seq_tfr');

  UPDATE WLT_ACCT
     SET ACTUAL_BAL     = ACTUAL_BAL + p_amount,
         VERSION        = VERSION + 1,
         LAST_TRAN_DATE = clock_timestamp()
   WHERE INTERNAL_KEY = v_acct.INTERNAL_KEY
     AND VERSION      = v_acct.VERSION
  RETURNING ACTUAL_BAL INTO v_acct.ACTUAL_BAL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'VERSION_CONFLICT' USING ERRCODE = '40001';
  END IF;

  -- TRAN_HIST (1 leg: TOPUP)
  INSERT INTO WLT_TRAN_HIST (
    INTERNAL_KEY, TRAN_TYPE, TRAN_DATE, EFFECT_DATE, POST_DATE, VALUE_DATE,
    TRAN_AMT, CR_DR_MAINT_IND, PREVIOUS_BAL_AMT, ACTUAL_BAL_AMT,
    TFR_INTERNAL_KEY, REFERENCE, CCY, SOURCE_TYPE, SOURCE_MODULE,
    TRAN_DESC, NARRATIVE, GROUP_ID, SHARD_INDEX, METADATA, CLIENT_INFO
  ) VALUES (
    v_acct.INTERNAL_KEY, 'TOPUP', CURRENT_DATE, CURRENT_DATE, CURRENT_DATE, CURRENT_DATE,
    p_amount, 'CR', v_acct.ACTUAL_BAL - p_amount, v_acct.ACTUAL_BAL,
    v_tfr_key, p_reference, v_acct.CCY, p_channel, 'WLT',
    'Topup from Treasury', left(p_metadata->>'narrative',250), v_acct.GROUP_ID, v_acct.SHARD_INDEX, p_metadata, v_client_info
  );

  -- BATCH (2 GL legs: DR nostro / CR wallet liability)
  INSERT INTO WLT_BATCH (TRAN_KEY, SEQ_NO, GL_CODE, CLIENT_NO, ACCT_INTERNAL_KEY,
                         AMOUNT, TRAN_NATURE, CCY, REFERENCE, POST_DATE, VALUE_DATE)
  VALUES
    (v_tfr_key, 1, v_def.CONTRA_GL_CODE,      v_acct.CLIENT_NO, v_acct.INTERNAL_KEY,
       p_amount, 'DR', v_acct.CCY, p_reference, CURRENT_DATE, CURRENT_DATE),
    (v_tfr_key, 2, v_acct_type.GL_CODE_LIAB,  v_acct.CLIENT_NO, v_acct.INTERNAL_KEY,
       p_amount, 'CR', v_acct.CCY, p_reference, CURRENT_DATE, CURRENT_DATE);

  -- ACCT_BAL daily snapshot
  INSERT INTO WLT_ACCT_BAL (INTERNAL_KEY, TRAN_DATE, ACTUAL_BAL, CALC_BAL, PREV_ACTUAL_BAL)
  VALUES (v_acct.INTERNAL_KEY, CURRENT_DATE, v_acct.ACTUAL_BAL,
          v_acct.ACTUAL_BAL - v_acct.TOTAL_RESTRAINED_AMT, v_acct.ACTUAL_BAL - p_amount)
  ON CONFLICT (INTERNAL_KEY, TRAN_DATE) DO UPDATE
    SET ACTUAL_BAL = EXCLUDED.ACTUAL_BAL,
        CALC_BAL   = EXCLUDED.CALC_BAL;

  -- OUTBOX (atomic event)
  INSERT INTO WLT_OUTBOX (AGGREGATE_TYPE, AGGREGATE_ID, EVENT_TYPE,
                          PARTITION_KEY, TOPIC, PAYLOAD, HEADERS)
  VALUES ('TRANSACTION', v_tfr_key::text, 'wallet.topup.posted.v1',
          p_acct_no, 'wallet.transactions',
          jsonb_build_object('tfr_internal_key', v_tfr_key, 'acct_no', p_acct_no,
                             'client_no', v_acct.CLIENT_NO, 'amount', p_amount,
                             'ccy', v_acct.CCY, 'value_date', CURRENT_DATE),
          jsonb_build_object('traceparent', current_setting('app.trace_id', TRUE)))
  RETURNING EVENT_UUID INTO v_event_uuid;

  -- ─── Phase 5: close idempotency ─────────────────────────────────────
  UPDATE WLT_API_MESSAGE
     SET PROCESS_STATUS      = 'SUCCESS',
         HTTP_STATUS         = 200,
         OBJECT_RESPONE_DATA = jsonb_build_object(
           'tfr_internal_key', v_tfr_key,
           'new_balance',      v_acct.ACTUAL_BAL,
           'event_uuid',       v_event_uuid)::text,
         PROCESSED_AT        = clock_timestamp()
   WHERE OBJECT_REF_ID = p_reference;

  RETURN QUERY SELECT v_tfr_key, 'SUCCESS'::varchar, v_acct.ACTUAL_BAL, v_event_uuid;
END $$;


-- =============================================================================
-- §3. post_transfer — wallet → wallet in-book transfer (with fee + VAT)
-- =============================================================================

-- p_tran_type picks the transfer tran-type → its WLT_TRAN_DEF row drives the fee:
--   'TRFOUT' → FIXED 5,500 + VAT (fee transfer); 'TRFOUTF' → FEE_TYPE NONE (free).
-- Must be a DR-family type. The credit leg is always 'TRFIN'.
-- Drop the pre-tran_type 7-arg signature so we don't leave a stale overload.
DROP FUNCTION IF EXISTS post_transfer(varchar,varchar,numeric,varchar,jsonb,varchar,varchar);
CREATE OR REPLACE FUNCTION post_transfer(
  p_from_acct_no   VARCHAR(20),
  p_to_acct_no     VARCHAR(20),
  p_amount         NUMERIC(18,2),
  p_reference      VARCHAR(64),
  p_tran_type      VARCHAR(10)  DEFAULT 'TRFOUT',
  p_metadata       JSONB DEFAULT '{}'::jsonb,
  p_channel        VARCHAR(20) DEFAULT 'MOBILE',
  p_actor          VARCHAR(64) DEFAULT NULL
)
RETURNS TABLE (
  tfr_internal_key  BIGINT,
  status            VARCHAR,
  new_balance_from  NUMERIC(18,2),
  new_balance_to    NUMERIC(18,2),
  fee_gross         NUMERIC(18,2),
  vat_amount        NUMERIC(18,2),
  event_uuid        UUID
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
#variable_conflict use_column
DECLARE
  v_actor       VARCHAR(64) := COALESCE(p_actor, session_user);
  v_acct_a      WLT_ACCT%ROWTYPE;    -- "from" wallet (sender, debited)
  v_acct_b      WLT_ACCT%ROWTYPE;    -- "to" wallet (receiver, credited)
  v_acct_a_type WLT_ACCT_TYPE%ROWTYPE;
  v_acct_b_type WLT_ACCT_TYPE%ROWTYPE;
  v_def         WLT_TRAN_DEF%ROWTYPE;
  v_def_fee     WLT_TRAN_DEF%ROWTYPE;
  v_def_in      WLT_TRAN_DEF%ROWTYPE;
  v_kyc_a       WLT_CLIENT_KYC%ROWTYPE;
  v_fee_gross   NUMERIC(18,2) := 0;
  v_vat_amt     NUMERIC(18,2) := 0;
  v_fee_net     NUMERIC(18,2) := 0;
  v_total_debit NUMERIC(18,2);
  v_tfr_key     BIGINT;
  v_out_seq     BIGINT;   -- SEQ_NO of the TRFOUT (origin) leg; fee leg refers to it
  v_cur_bal     NUMERIC(18,2);   -- re-read on CAS miss to classify the failure
  v_cur_restr   NUMERIC(18,2);
  v_event_uuid  UUID;
  v_client_info_a JSONB;
  v_client_info_b JSONB;
  v_existing    WLT_API_MESSAGE%ROWTYPE;
BEGIN
  PERFORM set_config('audit.actor',   v_actor,   TRUE);
  PERFORM set_config('audit.channel', p_channel, TRUE);

  -- ─── Phase 0 ────────────────────────────────────────────────────────
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'INVALID_AMOUNT' USING ERRCODE = 'P0010';
  END IF;
  IF p_from_acct_no = p_to_acct_no THEN
    RAISE EXCEPTION 'SAME_ACCOUNT' USING ERRCODE = 'P0013';
  END IF;
  PERFORM fn_validate_metadata(p_metadata);

  -- ─── Phase 1: idempotency ──────────────────────────────────────────
  SELECT * INTO v_existing FROM WLT_API_MESSAGE WHERE OBJECT_REF_ID = p_reference FOR UPDATE;
  IF FOUND AND v_existing.PROCESS_STATUS = 'SUCCESS' THEN
    RETURN QUERY
    SELECT (v_existing.OBJECT_RESPONE_DATA::jsonb->>'tfr_internal_key')::bigint,
           'DUPLICATE'::varchar,
           (v_existing.OBJECT_RESPONE_DATA::jsonb->>'new_balance_from')::numeric,
           (v_existing.OBJECT_RESPONE_DATA::jsonb->>'new_balance_to')::numeric,
           (v_existing.OBJECT_RESPONE_DATA::jsonb->>'fee_gross')::numeric,
           (v_existing.OBJECT_RESPONE_DATA::jsonb->>'vat_amount')::numeric,
           (v_existing.OBJECT_RESPONE_DATA::jsonb->>'event_uuid')::uuid;
    RETURN;
  END IF;
  INSERT INTO WLT_API_MESSAGE (OBJECT_REF_ID, OBJECT_CHANNEL, OBJECT_SUBJECT,
                               OBJECT_REQUEST_DATA, PROCESS_STATUS)
  VALUES (p_reference, p_channel, 'TRANSFER',
          jsonb_build_object('from', p_from_acct_no, 'to', p_to_acct_no, 'amount', p_amount)::text,
          'PENDING')
  ON CONFLICT (OBJECT_REF_ID) DO NOTHING;

  -- ─── Phase 2: validate ─────────────────────────────────────────────
  SELECT * INTO v_def      FROM WLT_TRAN_DEF WHERE TRAN_TYPE = p_tran_type;
  IF NOT FOUND OR v_def.STATUS <> 'A' THEN
    RAISE EXCEPTION 'TRAN_TYPE_INACTIVE: %', p_tran_type USING ERRCODE = 'P0020';
  END IF;
  IF v_def.CR_DR_MAINT_IND <> 'DR' THEN
    RAISE EXCEPTION 'INVALID_AMOUNT: % is not a DR transfer type', p_tran_type USING ERRCODE = 'P0010';
  END IF;
  SELECT * INTO v_def_in   FROM WLT_TRAN_DEF WHERE TRAN_TYPE = 'TRFIN';
  IF v_def_in.STATUS <> 'A' THEN
    RAISE EXCEPTION 'TRAN_TYPE_INACTIVE: TRFIN' USING ERRCODE = 'P0020';
  END IF;
  SELECT * INTO v_def_fee  FROM WLT_TRAN_DEF WHERE TRAN_TYPE = v_def.FEE_TRAN_TYPE;

  SELECT * INTO v_acct_a   FROM WLT_ACCT WHERE ACCT_NO = p_from_acct_no;
  IF NOT FOUND THEN RAISE EXCEPTION 'FROM_ACCT_NOT_FOUND' USING ERRCODE = 'P0021'; END IF;
  SELECT * INTO v_acct_b   FROM WLT_ACCT WHERE ACCT_NO = p_to_acct_no;
  IF NOT FOUND THEN RAISE EXCEPTION 'TO_ACCT_NOT_FOUND'   USING ERRCODE = 'P0021'; END IF;

  -- Sender MUST be a customer wallet — never debit an internal group sub-account
  -- via the customer transfer API.
  IF v_acct_a.ACCT_ROLE <> 'STANDALONE' THEN
    RAISE EXCEPTION 'ACCT_ROLE_INVALID: from-account % is a % wallet (must be STANDALONE)', p_from_acct_no, v_acct_a.ACCT_ROLE USING ERRCODE = 'P0028';
  END IF;
  -- Receiver may be a customer wallet (P2P) OR a merchant SETTLEMENT wallet
  -- (customer→merchant payment credits the group's settlement account). A SHARD
  -- sub-account is still rejected: shards are fed only by SWEEP, and crediting a
  -- shard directly would corrupt the group's sharding/aggregation invariants.
  IF v_acct_b.ACCT_ROLE NOT IN ('STANDALONE','SETTLEMENT') THEN
    RAISE EXCEPTION 'ACCT_ROLE_INVALID: to-account % is a % wallet (must be STANDALONE or SETTLEMENT)', p_to_acct_no, v_acct_b.ACCT_ROLE USING ERRCODE = 'P0028';
  END IF;

  IF v_acct_a.ACCT_STATUS <> 'A' THEN
    RAISE EXCEPTION 'FROM_ACCT_NOT_ACTIVE: %', v_acct_a.ACCT_STATUS USING ERRCODE = 'P0022';
  END IF;
  IF v_acct_b.ACCT_STATUS <> 'A' THEN
    RAISE EXCEPTION 'TO_ACCT_NOT_ACTIVE: %', v_acct_b.ACCT_STATUS USING ERRCODE = 'P0022';
  END IF;

  SELECT * INTO v_acct_a_type FROM WLT_ACCT_TYPE WHERE ACCT_TYPE = v_acct_a.ACCT_TYPE;
  SELECT * INTO v_acct_b_type FROM WLT_ACCT_TYPE WHERE ACCT_TYPE = v_acct_b.ACCT_TYPE;
  SELECT * INTO v_kyc_a       FROM WLT_CLIENT_KYC WHERE CLIENT_NO = v_acct_a.CLIENT_NO;
  IF v_kyc_a.KYC_TIER < '1' THEN
    RAISE EXCEPTION 'TIER_INSUFFICIENT' USING ERRCODE = 'P0023';
  END IF;

  -- Fee + VAT (gross-inclusive)
  IF v_def.FEE_TYPE = 'FIXED' THEN
    v_fee_gross := v_def.FEE_AMT;
  ELSIF v_def.FEE_TYPE = 'PERCENT' THEN
    v_fee_gross := LEAST(GREATEST(p_amount * v_def.FEE_RATE, v_def.FEE_MIN), v_def.FEE_MAX);
  END IF;
  v_vat_amt    := ROUND(v_fee_gross * v_def.VAT_RATE / (1 + v_def.VAT_RATE), 2);
  v_fee_net    := v_fee_gross - v_vat_amt;
  v_total_debit := p_amount + v_fee_gross;

  IF p_amount < v_def.MIN_TRAN_AMT OR p_amount > v_def.MAX_TRAN_AMT THEN
    RAISE EXCEPTION 'AMOUNT_OUT_OF_RANGE' USING ERRCODE = 'P0024';
  END IF;

  -- DR restraint check on sender
  IF EXISTS (
    SELECT 1 FROM WLT_RESTRAINTS r
     WHERE (r.INTERNAL_KEY = v_acct_a.INTERNAL_KEY OR r.GROUP_ID = v_acct_a.GROUP_ID)
       AND r.RESTRAINT_TYPE IN ('DEBIT','ALL')
       AND r.STATUS = 'A'
       AND CURRENT_DATE BETWEEN r.START_DATE AND COALESCE(r.END_DATE, DATE '9999-12-31')
       AND r.PLEDGED_AMT = 0
  ) THEN
    RAISE EXCEPTION 'DR_RESTRAINT_ACTIVE' USING ERRCODE = 'P0025';
  END IF;

  -- CR restraint check on receiver
  IF v_acct_b.CR_BLOCKED = 'Y' THEN
    RAISE EXCEPTION 'CR_RESTRAINT_ACTIVE' USING ERRCODE = 'P0029';
  END IF;

  -- Fund check via CALC_BAL (already excludes restrained amount)
  IF v_acct_a.CALC_BAL < v_total_debit THEN
    RAISE EXCEPTION 'INSUFFICIENT_FUNDS: calc_bal=%, required=%',
                    v_acct_a.CALC_BAL, v_total_debit USING ERRCODE = 'P0026';
  END IF;

  -- ─── Phase 3: client snapshots ─────────────────────────────────────
  v_client_info_a := fn_build_client_info(v_acct_a.CLIENT_NO);
  v_client_info_b := fn_build_client_info(v_acct_b.CLIENT_NO);

  -- ─── Phase 4: atomic posting (ordered locking by INTERNAL_KEY ASC) ──
  v_tfr_key := nextval('seq_tfr');

  -- Order updates to avoid deadlock on opposite-direction transfers
  IF v_acct_a.INTERNAL_KEY < v_acct_b.INTERNAL_KEY THEN
    UPDATE WLT_ACCT
       SET ACTUAL_BAL = ACTUAL_BAL - v_total_debit,
           VERSION    = VERSION + 1,
           LAST_TRAN_DATE = clock_timestamp()
     WHERE INTERNAL_KEY = v_acct_a.INTERNAL_KEY AND VERSION = v_acct_a.VERSION
       AND ACTUAL_BAL - TOTAL_RESTRAINED_AMT >= v_total_debit   -- inline fund guard
    RETURNING ACTUAL_BAL INTO v_acct_a.ACTUAL_BAL;
    IF NOT FOUND THEN
      -- CAS missed: re-read sender to tell apart insufficient funds vs version conflict.
      SELECT ACTUAL_BAL, TOTAL_RESTRAINED_AMT INTO v_cur_bal, v_cur_restr
        FROM WLT_ACCT WHERE INTERNAL_KEY = v_acct_a.INTERNAL_KEY;
      IF v_cur_bal - v_cur_restr < v_total_debit THEN
        RAISE EXCEPTION 'INSUFFICIENT_FUNDS: calc_bal=%, required=%',
                        v_cur_bal - v_cur_restr, v_total_debit USING ERRCODE = 'P0026';
      END IF;
      RAISE EXCEPTION 'VERSION_CONFLICT_FROM' USING ERRCODE = '40001';
    END IF;

    UPDATE WLT_ACCT
       SET ACTUAL_BAL = ACTUAL_BAL + p_amount,
           VERSION    = VERSION + 1,
           LAST_TRAN_DATE = clock_timestamp()
     WHERE INTERNAL_KEY = v_acct_b.INTERNAL_KEY AND VERSION = v_acct_b.VERSION
    RETURNING ACTUAL_BAL INTO v_acct_b.ACTUAL_BAL;
    IF NOT FOUND THEN RAISE EXCEPTION 'VERSION_CONFLICT_TO' USING ERRCODE = '40001'; END IF;
  ELSE
    UPDATE WLT_ACCT
       SET ACTUAL_BAL = ACTUAL_BAL + p_amount,
           VERSION    = VERSION + 1,
           LAST_TRAN_DATE = clock_timestamp()
     WHERE INTERNAL_KEY = v_acct_b.INTERNAL_KEY AND VERSION = v_acct_b.VERSION
    RETURNING ACTUAL_BAL INTO v_acct_b.ACTUAL_BAL;
    IF NOT FOUND THEN RAISE EXCEPTION 'VERSION_CONFLICT_TO' USING ERRCODE = '40001'; END IF;

    UPDATE WLT_ACCT
       SET ACTUAL_BAL = ACTUAL_BAL - v_total_debit,
           VERSION    = VERSION + 1,
           LAST_TRAN_DATE = clock_timestamp()
     WHERE INTERNAL_KEY = v_acct_a.INTERNAL_KEY AND VERSION = v_acct_a.VERSION
       AND ACTUAL_BAL - TOTAL_RESTRAINED_AMT >= v_total_debit   -- inline fund guard
    RETURNING ACTUAL_BAL INTO v_acct_a.ACTUAL_BAL;
    IF NOT FOUND THEN
      -- CAS missed: re-read sender to tell apart insufficient funds vs version conflict.
      SELECT ACTUAL_BAL, TOTAL_RESTRAINED_AMT INTO v_cur_bal, v_cur_restr
        FROM WLT_ACCT WHERE INTERNAL_KEY = v_acct_a.INTERNAL_KEY;
      IF v_cur_bal - v_cur_restr < v_total_debit THEN
        RAISE EXCEPTION 'INSUFFICIENT_FUNDS: calc_bal=%, required=%',
                        v_cur_bal - v_cur_restr, v_total_debit USING ERRCODE = 'P0026';
      END IF;
      RAISE EXCEPTION 'VERSION_CONFLICT_FROM' USING ERRCODE = '40001';
    END IF;
  END IF;

  -- TRAN_HIST × 3 (TRFOUT sender, TRFIN receiver, FEETRF sender if fee).
  -- Insert the TRFOUT (origin) leg first and capture its SEQ_NO so the fee
  -- leg can point back to it via TFR_SEQ_NO.
  INSERT INTO WLT_TRAN_HIST (
    INTERNAL_KEY, TRAN_TYPE, TRAN_DATE, EFFECT_DATE, POST_DATE, VALUE_DATE,
    TRAN_AMT, CR_DR_MAINT_IND, PREVIOUS_BAL_AMT, ACTUAL_BAL_AMT,
    TFR_INTERNAL_KEY, REFERENCE, CCY, SOURCE_TYPE, SOURCE_MODULE,
    TRAN_DESC, NARRATIVE, GROUP_ID, SHARD_INDEX, METADATA, CLIENT_INFO
  ) VALUES
    (v_acct_a.INTERNAL_KEY, p_tran_type, CURRENT_DATE, CURRENT_DATE, CURRENT_DATE, CURRENT_DATE,
     p_amount, 'DR', v_acct_a.ACTUAL_BAL + v_total_debit, v_acct_a.ACTUAL_BAL + v_fee_gross,
     v_tfr_key, p_reference, v_acct_a.CCY, p_channel, 'WLT',
     'Transfer out', left(p_metadata->>'narrative',250), v_acct_a.GROUP_ID, v_acct_a.SHARD_INDEX, p_metadata, v_client_info_a)
  RETURNING SEQ_NO INTO v_out_seq;

  INSERT INTO WLT_TRAN_HIST (
    INTERNAL_KEY, TRAN_TYPE, TRAN_DATE, EFFECT_DATE, POST_DATE, VALUE_DATE,
    TRAN_AMT, CR_DR_MAINT_IND, PREVIOUS_BAL_AMT, ACTUAL_BAL_AMT,
    TFR_INTERNAL_KEY, TFR_SEQ_NO, REFERENCE, CCY, SOURCE_TYPE, SOURCE_MODULE,
    TRAN_DESC, NARRATIVE, GROUP_ID, SHARD_INDEX, METADATA, CLIENT_INFO
  ) VALUES
    (v_acct_b.INTERNAL_KEY, 'TRFIN',  CURRENT_DATE, CURRENT_DATE, CURRENT_DATE, CURRENT_DATE,
     p_amount, 'CR', v_acct_b.ACTUAL_BAL - p_amount, v_acct_b.ACTUAL_BAL,
     v_tfr_key, v_out_seq, p_reference, v_acct_b.CCY, p_channel, 'WLT',
     'Transfer in',  left(p_metadata->>'narrative',250), v_acct_b.GROUP_ID, v_acct_b.SHARD_INDEX, p_metadata, v_client_info_b);

  IF v_fee_gross > 0 THEN
    INSERT INTO WLT_TRAN_HIST (
      INTERNAL_KEY, TRAN_TYPE, TRAN_DATE, EFFECT_DATE, POST_DATE, VALUE_DATE,
      TRAN_AMT, CR_DR_MAINT_IND, PREVIOUS_BAL_AMT, ACTUAL_BAL_AMT,
      TFR_INTERNAL_KEY, TFR_SEQ_NO, REFERENCE, CCY, SOURCE_MODULE,
      TRAN_DESC, NARRATIVE, GROUP_ID, SHARD_INDEX, METADATA, CLIENT_INFO
    ) VALUES
      (v_acct_a.INTERNAL_KEY, v_def.FEE_TRAN_TYPE, CURRENT_DATE, CURRENT_DATE, CURRENT_DATE, CURRENT_DATE,
       v_fee_gross, 'DR', v_acct_a.ACTUAL_BAL + v_fee_gross, v_acct_a.ACTUAL_BAL,
       v_tfr_key, v_out_seq, p_reference, v_acct_a.CCY, 'WLT',
       'Fee + VAT for transfer', left(p_metadata->>'narrative',250), v_acct_a.GROUP_ID, v_acct_a.SHARD_INDEX, p_metadata, v_client_info_a);
  END IF;

  -- BATCH (5 GL legs: 2 transfer + 3 fee/VAT if fee > 0)
  INSERT INTO WLT_BATCH (TRAN_KEY, SEQ_NO, GL_CODE, CLIENT_NO, ACCT_INTERNAL_KEY,
                         AMOUNT, TRAN_NATURE, CCY, REFERENCE, POST_DATE, VALUE_DATE)
  VALUES
    (v_tfr_key, 1, v_acct_a_type.GL_CODE_LIAB, v_acct_a.CLIENT_NO, v_acct_a.INTERNAL_KEY,
       p_amount, 'DR', v_acct_a.CCY, p_reference, CURRENT_DATE, CURRENT_DATE),
    (v_tfr_key, 2, v_acct_b_type.GL_CODE_LIAB, v_acct_b.CLIENT_NO, v_acct_b.INTERNAL_KEY,
       p_amount, 'CR', v_acct_b.CCY, p_reference, CURRENT_DATE, CURRENT_DATE);
  IF v_fee_gross > 0 THEN
    INSERT INTO WLT_BATCH (TRAN_KEY, SEQ_NO, GL_CODE, CLIENT_NO, ACCT_INTERNAL_KEY,
                           AMOUNT, TRAN_NATURE, CCY, REFERENCE, POST_DATE, VALUE_DATE)
    VALUES
      (v_tfr_key, 3, v_acct_a_type.GL_CODE_LIAB, v_acct_a.CLIENT_NO, v_acct_a.INTERNAL_KEY,
         v_fee_gross, 'DR', v_acct_a.CCY, p_reference, CURRENT_DATE, CURRENT_DATE),
      (v_tfr_key, 4, v_def.FEE_GL_CODE, v_acct_a.CLIENT_NO, v_acct_a.INTERNAL_KEY,
         v_fee_net,   'CR', v_acct_a.CCY, p_reference, CURRENT_DATE, CURRENT_DATE),
      (v_tfr_key, 5, v_def.VAT_GL_CODE, v_acct_a.CLIENT_NO, v_acct_a.INTERNAL_KEY,
         v_vat_amt,   'CR', v_acct_a.CCY, p_reference, CURRENT_DATE, CURRENT_DATE);
  END IF;

  -- ACCT_BAL daily snapshots × 2
  INSERT INTO WLT_ACCT_BAL (INTERNAL_KEY, TRAN_DATE, ACTUAL_BAL, CALC_BAL, PREV_ACTUAL_BAL)
  VALUES
    (v_acct_a.INTERNAL_KEY, CURRENT_DATE, v_acct_a.ACTUAL_BAL,
     v_acct_a.ACTUAL_BAL - v_acct_a.TOTAL_RESTRAINED_AMT, v_acct_a.ACTUAL_BAL + v_total_debit),
    (v_acct_b.INTERNAL_KEY, CURRENT_DATE, v_acct_b.ACTUAL_BAL,
     v_acct_b.ACTUAL_BAL - v_acct_b.TOTAL_RESTRAINED_AMT, v_acct_b.ACTUAL_BAL - p_amount)
  ON CONFLICT (INTERNAL_KEY, TRAN_DATE) DO UPDATE
    SET ACTUAL_BAL = EXCLUDED.ACTUAL_BAL, CALC_BAL = EXCLUDED.CALC_BAL;

  -- OUTBOX
  INSERT INTO WLT_OUTBOX (AGGREGATE_TYPE, AGGREGATE_ID, EVENT_TYPE,
                          PARTITION_KEY, TOPIC, PAYLOAD, HEADERS)
  VALUES ('TRANSACTION', v_tfr_key::text, 'wallet.transfer.posted.v1',
          v_tfr_key::text, 'wallet.transactions',
          jsonb_build_object('tfr_internal_key', v_tfr_key,
                             'from_acct', p_from_acct_no, 'to_acct', p_to_acct_no,
                             'from_client', v_acct_a.CLIENT_NO, 'to_client', v_acct_b.CLIENT_NO,
                             'amount', p_amount, 'fee_gross', v_fee_gross, 'vat_amount', v_vat_amt,
                             'ccy', v_acct_a.CCY, 'value_date', CURRENT_DATE),
          jsonb_build_object('traceparent', current_setting('app.trace_id', TRUE)))
  RETURNING EVENT_UUID INTO v_event_uuid;

  -- ─── Phase 5: close idempotency ─────────────────────────────────────
  UPDATE WLT_API_MESSAGE
     SET PROCESS_STATUS      = 'SUCCESS',
         HTTP_STATUS         = 200,
         OBJECT_RESPONE_DATA = jsonb_build_object(
           'tfr_internal_key', v_tfr_key,
           'new_balance_from', v_acct_a.ACTUAL_BAL,
           'new_balance_to',   v_acct_b.ACTUAL_BAL,
           'fee_gross',        v_fee_gross,
           'vat_amount',       v_vat_amt,
           'event_uuid',       v_event_uuid)::text,
         PROCESSED_AT        = clock_timestamp()
   WHERE OBJECT_REF_ID = p_reference;

  RETURN QUERY SELECT v_tfr_key, 'SUCCESS'::varchar,
                      v_acct_a.ACTUAL_BAL, v_acct_b.ACTUAL_BAL,
                      v_fee_gross, v_vat_amt, v_event_uuid;
END $$;


-- =============================================================================
-- §4. post_withdraw — wallet → external bank (sync ledger commit + Treasury handoff)
-- =============================================================================

CREATE OR REPLACE FUNCTION post_withdraw(
  p_acct_no          VARCHAR(20),
  p_amount           NUMERIC(18,2),
  p_reference        VARCHAR(64),
  p_ext_payout_ref   VARCHAR(64),
  p_beneficiary_bank VARCHAR(20),
  p_beneficiary_acct VARCHAR(40),                     -- plaintext; SP encrypts
  p_metadata         JSONB DEFAULT '{}'::jsonb,
  p_channel          VARCHAR(20) DEFAULT 'MOBILE',
  p_actor            VARCHAR(64) DEFAULT NULL
)
RETURNS TABLE (
  tfr_internal_key  BIGINT,
  status            VARCHAR,
  new_balance       NUMERIC(18,2),
  fee_gross         NUMERIC(18,2),
  vat_amount        NUMERIC(18,2),
  event_uuid        UUID
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
#variable_conflict use_column
DECLARE
  v_actor       VARCHAR(64) := COALESCE(p_actor, session_user);
  v_acct        WLT_ACCT%ROWTYPE;
  v_acct_type   WLT_ACCT_TYPE%ROWTYPE;
  v_def         WLT_TRAN_DEF%ROWTYPE;
  v_kyc         WLT_CLIENT_KYC%ROWTYPE;
  v_fee_gross   NUMERIC(18,2) := 0;
  v_vat_amt     NUMERIC(18,2) := 0;
  v_fee_net     NUMERIC(18,2) := 0;
  v_total_debit NUMERIC(18,2);
  v_monthly_used  NUMERIC(18,2);
  v_monthly_limit NUMERIC(18,2);
  v_tfr_key     BIGINT;
  v_out_seq     BIGINT;   -- SEQ_NO of the WDRAW (origin) leg; fee leg refers to it
  v_cur_bal     NUMERIC(18,2);   -- re-read on CAS miss to classify the failure
  v_cur_restr   NUMERIC(18,2);
  v_event_uuid  UUID;
  v_client_info JSONB;
  v_benef_enc   BYTEA;
  v_dek         TEXT := current_setting('app.pii_dek', TRUE);
  v_existing    WLT_API_MESSAGE%ROWTYPE;
BEGIN
  PERFORM set_config('audit.actor',   v_actor,   TRUE);
  PERFORM set_config('audit.channel', p_channel, TRUE);

  -- Phase 0
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'INVALID_AMOUNT' USING ERRCODE = 'P0010';
  END IF;
  PERFORM fn_validate_metadata(p_metadata);
  IF v_dek IS NULL OR v_dek = '' THEN
    RAISE EXCEPTION 'PII_DEK_NOT_SET — set ALTER DATABASE ... SET app.pii_dek=...'
      USING ERRCODE = 'P0030';
  END IF;

  -- Phase 1: idempotency
  SELECT * INTO v_existing FROM WLT_API_MESSAGE WHERE OBJECT_REF_ID = p_reference FOR UPDATE;
  IF FOUND AND v_existing.PROCESS_STATUS = 'SUCCESS' THEN
    RETURN QUERY
    SELECT (v_existing.OBJECT_RESPONE_DATA::jsonb->>'tfr_internal_key')::bigint,
           'DUPLICATE'::varchar,
           (v_existing.OBJECT_RESPONE_DATA::jsonb->>'new_balance')::numeric,
           (v_existing.OBJECT_RESPONE_DATA::jsonb->>'fee_gross')::numeric,
           (v_existing.OBJECT_RESPONE_DATA::jsonb->>'vat_amount')::numeric,
           (v_existing.OBJECT_RESPONE_DATA::jsonb->>'event_uuid')::uuid;
    RETURN;
  END IF;
  INSERT INTO WLT_API_MESSAGE (OBJECT_REF_ID, OBJECT_CHANNEL, OBJECT_SUBJECT,
                               OBJECT_REQUEST_DATA, PROCESS_STATUS)
  VALUES (p_reference, p_channel, 'WITHDRAW',
          jsonb_build_object('acct_no', p_acct_no, 'amount', p_amount,
                             'ext_payout_ref', p_ext_payout_ref)::text, 'PENDING')
  ON CONFLICT (OBJECT_REF_ID) DO NOTHING;

  -- Phase 2: validate
  SELECT * INTO v_def       FROM WLT_TRAN_DEF  WHERE TRAN_TYPE = 'WDRAW';
  IF v_def.STATUS <> 'A' THEN
    RAISE EXCEPTION 'TRAN_TYPE_INACTIVE' USING ERRCODE = 'P0020';
  END IF;

  SELECT * INTO v_acct      FROM WLT_ACCT      WHERE ACCT_NO = p_acct_no;
  IF NOT FOUND THEN RAISE EXCEPTION 'ACCT_NOT_FOUND' USING ERRCODE = 'P0021'; END IF;
  IF v_acct.ACCT_STATUS <> 'A' THEN
    RAISE EXCEPTION 'ACCT_NOT_ACTIVE: %', v_acct.ACCT_STATUS USING ERRCODE = 'P0022';
  END IF;

  SELECT * INTO v_acct_type FROM WLT_ACCT_TYPE WHERE ACCT_TYPE = v_acct.ACCT_TYPE;
  SELECT * INTO v_kyc       FROM WLT_CLIENT_KYC WHERE CLIENT_NO = v_acct.CLIENT_NO;
  IF v_kyc.KYC_TIER < '2' THEN
    RAISE EXCEPTION 'TIER_INSUFFICIENT: tier=%, required >= 2', v_kyc.KYC_TIER
      USING ERRCODE = 'P0023';
  END IF;

  -- Fee + VAT
  IF v_def.FEE_TYPE = 'FIXED' THEN
    v_fee_gross := v_def.FEE_AMT;
  ELSIF v_def.FEE_TYPE = 'PERCENT' THEN
    v_fee_gross := LEAST(GREATEST(p_amount * v_def.FEE_RATE, v_def.FEE_MIN), v_def.FEE_MAX);
  END IF;
  v_vat_amt    := ROUND(v_fee_gross * v_def.VAT_RATE / (1 + v_def.VAT_RATE), 2);
  v_fee_net    := v_fee_gross - v_vat_amt;
  v_total_debit := p_amount + v_fee_gross;

  IF p_amount < v_def.MIN_TRAN_AMT OR p_amount > v_def.MAX_TRAN_AMT THEN
    RAISE EXCEPTION 'AMOUNT_OUT_OF_RANGE' USING ERRCODE = 'P0024';
  END IF;

  -- DR restraint
  IF EXISTS (
    SELECT 1 FROM WLT_RESTRAINTS r
     WHERE (r.INTERNAL_KEY = v_acct.INTERNAL_KEY OR r.GROUP_ID = v_acct.GROUP_ID)
       AND r.RESTRAINT_TYPE IN ('DEBIT','ALL')
       AND r.STATUS = 'A'
       AND CURRENT_DATE BETWEEN r.START_DATE AND COALESCE(r.END_DATE, DATE '9999-12-31')
       AND r.PLEDGED_AMT = 0
  ) THEN
    RAISE EXCEPTION 'DR_RESTRAINT_ACTIVE' USING ERRCODE = 'P0025';
  END IF;

  -- Fund
  IF v_acct.CALC_BAL < v_total_debit THEN
    RAISE EXCEPTION 'INSUFFICIENT_FUNDS: calc_bal=%, required=%',
                    v_acct.CALC_BAL, v_total_debit USING ERRCODE = 'P0026';
  END IF;

  -- Monthly tier limit (simple inline SUM — OK at 20 TPS)
  SELECT COALESCE(SUM(TRAN_AMT), 0) INTO v_monthly_used
    FROM WLT_TRAN_HIST
   WHERE INTERNAL_KEY = v_acct.INTERNAL_KEY
     AND TRAN_TYPE IN ('WDRAW','TRFOUT')
     AND POST_DATE >= date_trunc('month', CURRENT_DATE);
  v_monthly_limit := CASE v_kyc.KYC_TIER
                       WHEN '1' THEN 20000000::numeric
                       WHEN '2' THEN v_acct_type.MONTHLY_LIMIT
                       WHEN '3' THEN 9999999999::numeric
                     END;
  IF v_monthly_used + p_amount > v_monthly_limit THEN
    RAISE EXCEPTION 'TIER_LIMIT_EXCEEDED: used=%, limit=%',
                    v_monthly_used, v_monthly_limit USING ERRCODE = 'P0027';
  END IF;

  -- Phase 3: snapshot
  v_client_info := fn_build_client_info(v_acct.CLIENT_NO);

  -- Phase 4: atomic posting
  v_tfr_key := nextval('seq_tfr');
  v_benef_enc := pgp_sym_encrypt(p_beneficiary_acct, v_dek, 'cipher-algo=aes256');

  -- Inline fund guard (defense-in-depth): the WHERE re-asserts available funds
  -- atomically with the version-CAS, so an overdraft is impossible even if a
  -- restraint slipped in without bumping VERSION (DLD §3 "fund check inline").
  UPDATE WLT_ACCT
     SET ACTUAL_BAL  = ACTUAL_BAL - v_total_debit,
         VERSION     = VERSION + 1,
         LAST_TRAN_DATE = clock_timestamp()
   WHERE INTERNAL_KEY = v_acct.INTERNAL_KEY
     AND VERSION      = v_acct.VERSION
     AND ACTUAL_BAL - TOTAL_RESTRAINED_AMT >= v_total_debit
  RETURNING ACTUAL_BAL INTO v_acct.ACTUAL_BAL;
  IF NOT FOUND THEN
    -- CAS missed: re-read to tell apart insufficient funds vs version conflict.
    SELECT ACTUAL_BAL, TOTAL_RESTRAINED_AMT INTO v_cur_bal, v_cur_restr
      FROM WLT_ACCT WHERE INTERNAL_KEY = v_acct.INTERNAL_KEY;
    IF v_cur_bal - v_cur_restr < v_total_debit THEN
      RAISE EXCEPTION 'INSUFFICIENT_FUNDS: calc_bal=%, required=%',
                      v_cur_bal - v_cur_restr, v_total_debit USING ERRCODE = 'P0026';
    END IF;
    RAISE EXCEPTION 'VERSION_CONFLICT' USING ERRCODE = '40001';
  END IF;

  -- TRAN_HIST × 2
  INSERT INTO WLT_TRAN_HIST (
    INTERNAL_KEY, TRAN_TYPE, TRAN_DATE, EFFECT_DATE, POST_DATE, VALUE_DATE,
    TRAN_AMT, CR_DR_MAINT_IND, PREVIOUS_BAL_AMT, ACTUAL_BAL_AMT,
    TFR_INTERNAL_KEY, REFERENCE, CCY, SOURCE_TYPE, SOURCE_MODULE,
    TRAN_DESC, NARRATIVE, GROUP_ID, SHARD_INDEX, METADATA, CLIENT_INFO
  ) VALUES
    (v_acct.INTERNAL_KEY, 'WDRAW', CURRENT_DATE, CURRENT_DATE, CURRENT_DATE, CURRENT_DATE,
     p_amount, 'DR', v_acct.ACTUAL_BAL + v_total_debit, v_acct.ACTUAL_BAL + v_fee_gross,
     v_tfr_key, p_reference, v_acct.CCY, p_channel, 'WLT',
     'Withdraw to bank', left(p_metadata->>'narrative',250), v_acct.GROUP_ID, v_acct.SHARD_INDEX, p_metadata, v_client_info)
  RETURNING SEQ_NO INTO v_out_seq;

  IF v_fee_gross > 0 THEN
    INSERT INTO WLT_TRAN_HIST (
      INTERNAL_KEY, TRAN_TYPE, TRAN_DATE, EFFECT_DATE, POST_DATE, VALUE_DATE,
      TRAN_AMT, CR_DR_MAINT_IND, PREVIOUS_BAL_AMT, ACTUAL_BAL_AMT,
      TFR_INTERNAL_KEY, TFR_SEQ_NO, REFERENCE, CCY, SOURCE_MODULE,
      TRAN_DESC, NARRATIVE, GROUP_ID, SHARD_INDEX, METADATA, CLIENT_INFO
    ) VALUES
      (v_acct.INTERNAL_KEY, 'FEEWD', CURRENT_DATE, CURRENT_DATE, CURRENT_DATE, CURRENT_DATE,
       v_fee_gross, 'DR', v_acct.ACTUAL_BAL + v_fee_gross, v_acct.ACTUAL_BAL,
       v_tfr_key, v_out_seq, p_reference, v_acct.CCY, 'WLT',
       'Fee + VAT for withdraw', left(p_metadata->>'narrative',250), v_acct.GROUP_ID, v_acct.SHARD_INDEX, p_metadata, v_client_info);
  END IF;

  -- BATCH × 5
  INSERT INTO WLT_BATCH (TRAN_KEY, SEQ_NO, GL_CODE, CLIENT_NO, ACCT_INTERNAL_KEY,
                         AMOUNT, TRAN_NATURE, CCY, REFERENCE, POST_DATE, VALUE_DATE)
  VALUES
    (v_tfr_key, 1, v_acct_type.GL_CODE_LIAB, v_acct.CLIENT_NO, v_acct.INTERNAL_KEY,
       p_amount, 'DR', v_acct.CCY, p_reference, CURRENT_DATE, CURRENT_DATE),
    (v_tfr_key, 2, v_def.CONTRA_GL_CODE,    v_acct.CLIENT_NO, v_acct.INTERNAL_KEY,
       p_amount, 'CR', v_acct.CCY, p_reference, CURRENT_DATE, CURRENT_DATE);
  IF v_fee_gross > 0 THEN
    INSERT INTO WLT_BATCH (TRAN_KEY, SEQ_NO, GL_CODE, CLIENT_NO, ACCT_INTERNAL_KEY,
                           AMOUNT, TRAN_NATURE, CCY, REFERENCE, POST_DATE, VALUE_DATE)
    VALUES
      (v_tfr_key, 3, v_acct_type.GL_CODE_LIAB, v_acct.CLIENT_NO, v_acct.INTERNAL_KEY,
         v_fee_gross, 'DR', v_acct.CCY, p_reference, CURRENT_DATE, CURRENT_DATE),
      (v_tfr_key, 4, v_def.FEE_GL_CODE, v_acct.CLIENT_NO, v_acct.INTERNAL_KEY,
         v_fee_net,   'CR', v_acct.CCY, p_reference, CURRENT_DATE, CURRENT_DATE),
      (v_tfr_key, 5, v_def.VAT_GL_CODE, v_acct.CLIENT_NO, v_acct.INTERNAL_KEY,
         v_vat_amt,   'CR', v_acct.CCY, p_reference, CURRENT_DATE, CURRENT_DATE);
  END IF;

  -- ACCT_BAL daily
  INSERT INTO WLT_ACCT_BAL (INTERNAL_KEY, TRAN_DATE, ACTUAL_BAL, CALC_BAL, PREV_ACTUAL_BAL)
  VALUES (v_acct.INTERNAL_KEY, CURRENT_DATE, v_acct.ACTUAL_BAL,
          v_acct.ACTUAL_BAL - v_acct.TOTAL_RESTRAINED_AMT, v_acct.ACTUAL_BAL + v_total_debit)
  ON CONFLICT (INTERNAL_KEY, TRAN_DATE) DO UPDATE
    SET ACTUAL_BAL = EXCLUDED.ACTUAL_BAL, CALC_BAL = EXCLUDED.CALC_BAL;

  -- WITHDRAW_TRACK (disbursement state machine — see HLD §6.3)
  INSERT INTO WLT_WITHDRAW_TRACK (
    TFR_INTERNAL_KEY, ACCT_NO, CLIENT_NO, AMOUNT, FEE_GROSS, CCY,
    EXT_PAYOUT_REF, BENEFICIARY_BANK, BENEFICIARY_ACCT_ENC, STATUS
  ) VALUES (
    v_tfr_key, p_acct_no, v_acct.CLIENT_NO, p_amount, v_fee_gross, v_acct.CCY,
    p_ext_payout_ref, p_beneficiary_bank, v_benef_enc, 'SUBMITTED'
  );

  -- OUTBOX
  INSERT INTO WLT_OUTBOX (AGGREGATE_TYPE, AGGREGATE_ID, EVENT_TYPE,
                          PARTITION_KEY, TOPIC, PAYLOAD, HEADERS)
  VALUES ('WITHDRAW', v_tfr_key::text, 'wallet.withdraw.posted.v1',
          p_acct_no, 'wallet.withdrawals',
          jsonb_build_object('tfr_internal_key', v_tfr_key,
                             'acct_no', p_acct_no, 'client_no', v_acct.CLIENT_NO,
                             'amount', p_amount, 'fee_gross', v_fee_gross,
                             'vat_amount', v_vat_amt, 'ccy', v_acct.CCY,
                             'value_date', CURRENT_DATE,
                             'ext_payout_ref', p_ext_payout_ref,
                             'beneficiary_bank', p_beneficiary_bank,
                             'beneficiary_acct_masked',
                             '****' || right(p_beneficiary_acct, 4),
                             'kyc_tier_at_post', v_kyc.KYC_TIER),
          jsonb_build_object('traceparent', current_setting('app.trace_id', TRUE)))
  RETURNING EVENT_UUID INTO v_event_uuid;

  -- Phase 5: close idempotency
  UPDATE WLT_API_MESSAGE
     SET PROCESS_STATUS      = 'SUCCESS',
         HTTP_STATUS         = 200,
         OBJECT_RESPONE_DATA = jsonb_build_object(
           'tfr_internal_key', v_tfr_key,
           'new_balance',      v_acct.ACTUAL_BAL,
           'fee_gross',        v_fee_gross,
           'vat_amount',       v_vat_amt,
           'event_uuid',       v_event_uuid)::text,
         PROCESSED_AT        = clock_timestamp()
   WHERE OBJECT_REF_ID = p_reference;

  RETURN QUERY SELECT v_tfr_key, 'SUCCESS'::varchar, v_acct.ACTUAL_BAL,
                      v_fee_gross, v_vat_amt, v_event_uuid;
END $$;


-- =============================================================================
-- §5. post_withdraw_reversal — idempotent credit-back on Treasury failure or SLA
-- =============================================================================

CREATE OR REPLACE FUNCTION post_withdraw_reversal(
  p_ext_payout_ref VARCHAR(64),
  p_fail_code      VARCHAR(40),
  p_fail_reason    VARCHAR(500),
  p_initiator      VARCHAR(32),                       -- 'TREASURY_FAILED' | 'SLA_TIMEOUT' | 'OPS_MANUAL'
  p_channel        VARCHAR(20) DEFAULT 'SYS',
  p_actor          VARCHAR(64) DEFAULT NULL
)
RETURNS TABLE (
  reversal_tfr_key       BIGINT,
  was_already_reversed   BOOLEAN,
  event_uuid             UUID
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
#variable_conflict use_column
DECLARE
  v_actor       VARCHAR(64) := COALESCE(p_actor, session_user);
  v_track       WLT_WITHDRAW_TRACK%ROWTYPE;
  v_acct        WLT_ACCT%ROWTYPE;
  v_acct_type   WLT_ACCT_TYPE%ROWTYPE;
  v_orig_def    WLT_TRAN_DEF%ROWTYPE;
  v_rev_tfr_key BIGINT;
  v_event_uuid  UUID;
  v_client_info JSONB;
  v_orig_legs   RECORD;
BEGIN
  PERFORM set_config('audit.actor',   v_actor,   TRUE);
  PERFORM set_config('audit.channel', p_channel, TRUE);

  -- Lock the track row
  SELECT * INTO v_track FROM WLT_WITHDRAW_TRACK
   WHERE EXT_PAYOUT_REF = p_ext_payout_ref FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'WD_NOT_FOUND: %', p_ext_payout_ref USING ERRCODE = 'P0040';
  END IF;

  -- Idempotent on REVERSED
  IF v_track.STATUS = 'REVERSED' THEN
    RETURN QUERY SELECT v_track.REVERSAL_TFR_KEY, TRUE,
                        (SELECT EVENT_UUID FROM WLT_OUTBOX
                          WHERE AGGREGATE_ID = v_track.REVERSAL_TFR_KEY::text
                            AND EVENT_TYPE = 'wallet.withdraw.reversed.v1'
                          LIMIT 1);
    RETURN;
  END IF;

  -- Refuse to reverse a completed withdraw
  IF v_track.STATUS = 'COMPLETED' THEN
    RAISE EXCEPTION 'WD_ALREADY_COMPLETED: cannot reverse %', p_ext_payout_ref
      USING ERRCODE = 'P0041';
  END IF;

  -- Fetch wallet
  SELECT * INTO v_acct      FROM WLT_ACCT      WHERE ACCT_NO = v_track.ACCT_NO;
  SELECT * INTO v_acct_type FROM WLT_ACCT_TYPE WHERE ACCT_TYPE = v_acct.ACCT_TYPE;
  SELECT * INTO v_orig_def  FROM WLT_TRAN_DEF  WHERE TRAN_TYPE = 'WDRAW';

  -- Client snapshot (current — for reversal audit)
  v_client_info := fn_build_client_info(v_acct.CLIENT_NO);

  -- Atomic: credit back ACTUAL_BAL + post RVWD/RVFEE legs + flip GL legs
  v_rev_tfr_key := nextval('seq_tfr');

  UPDATE WLT_ACCT
     SET ACTUAL_BAL  = ACTUAL_BAL + v_track.AMOUNT + v_track.FEE_GROSS,
         VERSION     = VERSION + 1,
         LAST_TRAN_DATE = clock_timestamp()
   WHERE INTERNAL_KEY = v_acct.INTERNAL_KEY
  RETURNING ACTUAL_BAL INTO v_acct.ACTUAL_BAL;
  -- Note: no VERSION CAS here because reversal is a system-initiated atomic op;
  -- contention is rare and serializing on the track FOR UPDATE is sufficient.

  -- RVWD leg (credit-back of principal)
  INSERT INTO WLT_TRAN_HIST (
    INTERNAL_KEY, TRAN_TYPE, TRAN_DATE, EFFECT_DATE, POST_DATE, VALUE_DATE,
    TRAN_AMT, CR_DR_MAINT_IND, PREVIOUS_BAL_AMT, ACTUAL_BAL_AMT,
    TFR_INTERNAL_KEY, REFERENCE, ORIG_SEQ_NO, CCY, SOURCE_TYPE, SOURCE_MODULE,
    TRAN_DESC, GROUP_ID, SHARD_INDEX, CLIENT_INFO
  ) VALUES (
    v_acct.INTERNAL_KEY, 'RVWD', CURRENT_DATE, CURRENT_DATE, CURRENT_DATE, CURRENT_DATE,
    v_track.AMOUNT, 'CR',
    v_acct.ACTUAL_BAL - v_track.AMOUNT - v_track.FEE_GROSS,
    v_acct.ACTUAL_BAL - v_track.FEE_GROSS,
    v_rev_tfr_key, 'RVWD-' || p_ext_payout_ref, v_track.TFR_INTERNAL_KEY,
    v_acct.CCY, p_channel, 'WLT',
    'Reverse withdraw: ' || COALESCE(p_fail_code, '?'),
    v_acct.GROUP_ID, v_acct.SHARD_INDEX, v_client_info);

  -- RVFEE leg (refund fee + VAT) if fee was collected
  IF v_track.FEE_GROSS > 0 THEN
    INSERT INTO WLT_TRAN_HIST (
      INTERNAL_KEY, TRAN_TYPE, TRAN_DATE, EFFECT_DATE, POST_DATE, VALUE_DATE,
      TRAN_AMT, CR_DR_MAINT_IND, PREVIOUS_BAL_AMT, ACTUAL_BAL_AMT,
      TFR_INTERNAL_KEY, REFERENCE, ORIG_SEQ_NO, CCY, SOURCE_MODULE,
      TRAN_DESC, GROUP_ID, SHARD_INDEX, CLIENT_INFO
    ) VALUES (
      v_acct.INTERNAL_KEY, 'RVFEE', CURRENT_DATE, CURRENT_DATE, CURRENT_DATE, CURRENT_DATE,
      v_track.FEE_GROSS, 'CR',
      v_acct.ACTUAL_BAL - v_track.FEE_GROSS, v_acct.ACTUAL_BAL,
      v_rev_tfr_key, 'RVFEE-' || p_ext_payout_ref, v_track.TFR_INTERNAL_KEY,
      v_acct.CCY, 'WLT',
      'Refund fee + VAT', v_acct.GROUP_ID, v_acct.SHARD_INDEX, v_client_info);
  END IF;

  -- Mirror GL legs flipped
  INSERT INTO WLT_BATCH (TRAN_KEY, SEQ_NO, GL_CODE, CLIENT_NO, ACCT_INTERNAL_KEY,
                         AMOUNT, TRAN_NATURE, CCY, REFERENCE, POST_DATE, VALUE_DATE)
  VALUES
    (v_rev_tfr_key, 1, v_orig_def.CONTRA_GL_CODE, v_acct.CLIENT_NO, v_acct.INTERNAL_KEY,
       v_track.AMOUNT, 'DR', v_acct.CCY, 'RVWD-' || p_ext_payout_ref, CURRENT_DATE, CURRENT_DATE),
    (v_rev_tfr_key, 2, v_acct_type.GL_CODE_LIAB, v_acct.CLIENT_NO, v_acct.INTERNAL_KEY,
       v_track.AMOUNT, 'CR', v_acct.CCY, 'RVWD-' || p_ext_payout_ref, CURRENT_DATE, CURRENT_DATE);
  IF v_track.FEE_GROSS > 0 THEN
    INSERT INTO WLT_BATCH (TRAN_KEY, SEQ_NO, GL_CODE, CLIENT_NO, ACCT_INTERNAL_KEY,
                           AMOUNT, TRAN_NATURE, CCY, REFERENCE, POST_DATE, VALUE_DATE)
    VALUES
      (v_rev_tfr_key, 3, v_orig_def.FEE_GL_CODE, v_acct.CLIENT_NO, v_acct.INTERNAL_KEY,
         ROUND(v_track.FEE_GROSS * (1 - v_orig_def.VAT_RATE/(1+v_orig_def.VAT_RATE)), 2),
         'DR', v_acct.CCY, 'RVFEE-' || p_ext_payout_ref, CURRENT_DATE, CURRENT_DATE),
      (v_rev_tfr_key, 4, v_orig_def.VAT_GL_CODE, v_acct.CLIENT_NO, v_acct.INTERNAL_KEY,
         ROUND(v_track.FEE_GROSS * v_orig_def.VAT_RATE/(1+v_orig_def.VAT_RATE), 2),
         'DR', v_acct.CCY, 'RVFEE-' || p_ext_payout_ref, CURRENT_DATE, CURRENT_DATE),
      (v_rev_tfr_key, 5, v_acct_type.GL_CODE_LIAB, v_acct.CLIENT_NO, v_acct.INTERNAL_KEY,
         v_track.FEE_GROSS, 'CR', v_acct.CCY, 'RVFEE-' || p_ext_payout_ref, CURRENT_DATE, CURRENT_DATE);
  END IF;

  -- ACCT_BAL
  INSERT INTO WLT_ACCT_BAL (INTERNAL_KEY, TRAN_DATE, ACTUAL_BAL, CALC_BAL, PREV_ACTUAL_BAL)
  VALUES (v_acct.INTERNAL_KEY, CURRENT_DATE, v_acct.ACTUAL_BAL,
          v_acct.ACTUAL_BAL - v_acct.TOTAL_RESTRAINED_AMT,
          v_acct.ACTUAL_BAL - v_track.AMOUNT - v_track.FEE_GROSS)
  ON CONFLICT (INTERNAL_KEY, TRAN_DATE) DO UPDATE
    SET ACTUAL_BAL = EXCLUDED.ACTUAL_BAL, CALC_BAL = EXCLUDED.CALC_BAL;

  -- Update track
  UPDATE WLT_WITHDRAW_TRACK
     SET STATUS            = 'REVERSED',
         REVERSED_AT       = clock_timestamp(),
         REVERSAL_TFR_KEY  = v_rev_tfr_key,
         FAIL_CODE         = COALESCE(FAIL_CODE,   p_fail_code),
         FAIL_REASON       = COALESCE(FAIL_REASON, p_fail_reason),
         TREASURY_FINAL_AT = COALESCE(TREASURY_FINAL_AT, clock_timestamp()),
         VERSION           = VERSION + 1
   WHERE TFR_INTERNAL_KEY = v_track.TFR_INTERNAL_KEY;

  -- OUTBOX
  INSERT INTO WLT_OUTBOX (AGGREGATE_TYPE, AGGREGATE_ID, EVENT_TYPE,
                          PARTITION_KEY, TOPIC, PAYLOAD)
  VALUES ('TRANSACTION', v_rev_tfr_key::text,
          'wallet.withdraw.reversed.v1', v_track.ACCT_NO,
          'wallet.withdrawals',
          jsonb_build_object('ext_payout_ref', p_ext_payout_ref,
                             'reversal_tfr_key', v_rev_tfr_key,
                             'orig_tfr_key', v_track.TFR_INTERNAL_KEY,
                             'amount', v_track.AMOUNT + v_track.FEE_GROSS,
                             'fail_code', p_fail_code,
                             'reason', p_fail_reason,
                             'initiator', p_initiator))
  RETURNING EVENT_UUID INTO v_event_uuid;

  RETURN QUERY SELECT v_rev_tfr_key, FALSE, v_event_uuid;
END $$;


-- =============================================================================
-- §6. mark_withdraw_acked — Treasury accepted the disbursement
-- =============================================================================

CREATE OR REPLACE FUNCTION mark_withdraw_acked(
  p_ext_payout_ref   VARCHAR(64),
  p_treasury_batch_id VARCHAR(64),
  p_channel          VARCHAR(20) DEFAULT 'TREASURY',
  p_actor            VARCHAR(64) DEFAULT NULL
)
RETURNS TABLE (acct_no VARCHAR, status VARCHAR, event_uuid UUID)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
#variable_conflict use_column
DECLARE
  v_actor      VARCHAR(64) := COALESCE(p_actor, session_user);
  v_track      WLT_WITHDRAW_TRACK%ROWTYPE;
  v_event_uuid UUID;
BEGIN
  PERFORM set_config('audit.actor',   v_actor,   TRUE);
  PERFORM set_config('audit.channel', p_channel, TRUE);

  UPDATE WLT_WITHDRAW_TRACK
     SET STATUS            = 'ACKED',
         TREASURY_BATCH_ID = p_treasury_batch_id,
         TREASURY_ACK_AT   = clock_timestamp(),
         VERSION           = VERSION + 1
   WHERE EXT_PAYOUT_REF = p_ext_payout_ref
     AND STATUS         = 'SUBMITTED'
  RETURNING * INTO v_track;

  IF NOT FOUND THEN
    -- Either not found OR already past SUBMITTED (idempotent no-op for already-ACKED)
    SELECT * INTO v_track FROM WLT_WITHDRAW_TRACK WHERE EXT_PAYOUT_REF = p_ext_payout_ref;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'WD_NOT_FOUND: %', p_ext_payout_ref USING ERRCODE = 'P0040';
    END IF;
    IF v_track.STATUS IN ('ACKED','DISBURSING','COMPLETED','REVERSED') THEN
      RETURN QUERY SELECT v_track.ACCT_NO, v_track.STATUS, NULL::UUID;
      RETURN;
    END IF;
    RAISE EXCEPTION 'WD_INVALID_STATE: % cannot transition to ACKED', v_track.STATUS
      USING ERRCODE = 'P0042';
  END IF;

  INSERT INTO WLT_OUTBOX (AGGREGATE_TYPE, AGGREGATE_ID, EVENT_TYPE,
                          PARTITION_KEY, TOPIC, PAYLOAD)
  VALUES ('WITHDRAW', v_track.TFR_INTERNAL_KEY::text,
          'wallet.withdraw.acked.v1', v_track.ACCT_NO, 'wallet.withdrawals',
          jsonb_build_object('ext_payout_ref', p_ext_payout_ref,
                             'treasury_batch_id', p_treasury_batch_id,
                             'tfr_internal_key', v_track.TFR_INTERNAL_KEY,
                             'acked_at', clock_timestamp()))
  RETURNING EVENT_UUID INTO v_event_uuid;

  RETURN QUERY SELECT v_track.ACCT_NO, v_track.STATUS, v_event_uuid;
END $$;


-- =============================================================================
-- §7. mark_withdraw_disbursing — Treasury submitted to NAPAS
-- =============================================================================

CREATE OR REPLACE FUNCTION mark_withdraw_disbursing(
  p_ext_payout_ref VARCHAR(64),
  p_channel        VARCHAR(20) DEFAULT 'TREASURY',
  p_actor          VARCHAR(64) DEFAULT NULL
)
RETURNS TABLE (acct_no VARCHAR, status VARCHAR, event_uuid UUID)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
#variable_conflict use_column
DECLARE
  v_actor      VARCHAR(64) := COALESCE(p_actor, session_user);
  v_track      WLT_WITHDRAW_TRACK%ROWTYPE;
  v_event_uuid UUID;
BEGIN
  PERFORM set_config('audit.actor',   v_actor,   TRUE);
  PERFORM set_config('audit.channel', p_channel, TRUE);

  UPDATE WLT_WITHDRAW_TRACK
     SET STATUS  = 'DISBURSING',
         VERSION = VERSION + 1
   WHERE EXT_PAYOUT_REF = p_ext_payout_ref
     AND STATUS         = 'ACKED'
  RETURNING * INTO v_track;

  IF NOT FOUND THEN
    SELECT * INTO v_track FROM WLT_WITHDRAW_TRACK WHERE EXT_PAYOUT_REF = p_ext_payout_ref;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'WD_NOT_FOUND' USING ERRCODE = 'P0040';
    END IF;
    IF v_track.STATUS IN ('DISBURSING','COMPLETED','REVERSED') THEN
      RETURN QUERY SELECT v_track.ACCT_NO, v_track.STATUS, NULL::UUID;
      RETURN;
    END IF;
    RAISE EXCEPTION 'WD_INVALID_STATE: % cannot transition to DISBURSING', v_track.STATUS
      USING ERRCODE = 'P0042';
  END IF;

  INSERT INTO WLT_OUTBOX (AGGREGATE_TYPE, AGGREGATE_ID, EVENT_TYPE,
                          PARTITION_KEY, TOPIC, PAYLOAD)
  VALUES ('WITHDRAW', v_track.TFR_INTERNAL_KEY::text,
          'wallet.withdraw.disbursing.v1', v_track.ACCT_NO, 'wallet.withdrawals',
          jsonb_build_object('ext_payout_ref', p_ext_payout_ref,
                             'tfr_internal_key', v_track.TFR_INTERNAL_KEY))
  RETURNING EVENT_UUID INTO v_event_uuid;

  RETURN QUERY SELECT v_track.ACCT_NO, v_track.STATUS, v_event_uuid;
END $$;


-- =============================================================================
-- §8. mark_withdraw_completed — NAPAS settlement succeeded (terminal)
-- =============================================================================

CREATE OR REPLACE FUNCTION mark_withdraw_completed(
  p_ext_payout_ref VARCHAR(64),
  p_napas_ref      VARCHAR(64),
  p_channel        VARCHAR(20) DEFAULT 'TREASURY',
  p_actor          VARCHAR(64) DEFAULT NULL
)
RETURNS TABLE (acct_no VARCHAR, status VARCHAR, event_uuid UUID)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
#variable_conflict use_column
DECLARE
  v_actor      VARCHAR(64) := COALESCE(p_actor, session_user);
  v_track      WLT_WITHDRAW_TRACK%ROWTYPE;
  v_event_uuid UUID;
BEGIN
  PERFORM set_config('audit.actor',   v_actor,   TRUE);
  PERFORM set_config('audit.channel', p_channel, TRUE);

  UPDATE WLT_WITHDRAW_TRACK
     SET STATUS            = 'COMPLETED',
         NAPAS_REF         = p_napas_ref,
         TREASURY_FINAL_AT = clock_timestamp(),
         VERSION           = VERSION + 1
   WHERE EXT_PAYOUT_REF = p_ext_payout_ref
     AND STATUS         IN ('ACKED','DISBURSING')
  RETURNING * INTO v_track;

  IF NOT FOUND THEN
    SELECT * INTO v_track FROM WLT_WITHDRAW_TRACK WHERE EXT_PAYOUT_REF = p_ext_payout_ref;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'WD_NOT_FOUND' USING ERRCODE = 'P0040';
    END IF;
    IF v_track.STATUS = 'COMPLETED' THEN
      -- Idempotent
      RETURN QUERY SELECT v_track.ACCT_NO, v_track.STATUS, NULL::UUID;
      RETURN;
    END IF;
    IF v_track.STATUS = 'REVERSED' THEN
      RAISE EXCEPTION 'WD_ALREADY_REVERSED: cannot complete %', p_ext_payout_ref
        USING ERRCODE = 'P0043';
    END IF;
    RAISE EXCEPTION 'WD_INVALID_STATE: % cannot transition to COMPLETED', v_track.STATUS
      USING ERRCODE = 'P0042';
  END IF;

  INSERT INTO WLT_OUTBOX (AGGREGATE_TYPE, AGGREGATE_ID, EVENT_TYPE,
                          PARTITION_KEY, TOPIC, PAYLOAD)
  VALUES ('WITHDRAW', v_track.TFR_INTERNAL_KEY::text,
          'wallet.withdraw.completed.v1', v_track.ACCT_NO, 'wallet.withdrawals',
          jsonb_build_object('ext_payout_ref', p_ext_payout_ref,
                             'napas_ref', p_napas_ref,
                             'tfr_internal_key', v_track.TFR_INTERNAL_KEY,
                             'settled_at', clock_timestamp()))
  RETURNING EVENT_UUID INTO v_event_uuid;

  RETURN QUERY SELECT v_track.ACCT_NO, v_track.STATUS, v_event_uuid;
END $$;


-- =============================================================================
-- §9. GRANT EXECUTE — wallet_app role can call business SPs
-- =============================================================================

GRANT EXECUTE ON FUNCTION post_topup(VARCHAR, NUMERIC, VARCHAR, JSONB, VARCHAR, VARCHAR) TO wallet_app;
GRANT EXECUTE ON FUNCTION post_transfer(VARCHAR, VARCHAR, NUMERIC, VARCHAR, VARCHAR, JSONB, VARCHAR, VARCHAR) TO wallet_app;
GRANT EXECUTE ON FUNCTION post_withdraw(VARCHAR, NUMERIC, VARCHAR, VARCHAR, VARCHAR, VARCHAR, JSONB, VARCHAR, VARCHAR) TO wallet_app;
GRANT EXECUTE ON FUNCTION post_withdraw_reversal(VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR) TO wallet_app;
GRANT EXECUTE ON FUNCTION mark_withdraw_acked(VARCHAR, VARCHAR, VARCHAR, VARCHAR) TO wallet_app;
GRANT EXECUTE ON FUNCTION mark_withdraw_disbursing(VARCHAR, VARCHAR, VARCHAR) TO wallet_app;
GRANT EXECUTE ON FUNCTION mark_withdraw_completed(VARCHAR, VARCHAR, VARCHAR, VARCHAR) TO wallet_app;

GRANT EXECUTE ON FUNCTION fn_build_client_info(VARCHAR) TO wallet_app;
GRANT EXECUTE ON FUNCTION fn_validate_metadata(JSONB)   TO wallet_app;

-- Sequence
GRANT USAGE, SELECT ON SEQUENCE seq_tfr TO wallet_app;


COMMIT;

-- =============================================================================
-- POST-DEPLOY VERIFICATION (run manually after deploy)
-- =============================================================================
-- SELECT proname, pg_get_function_arguments(oid)
--   FROM pg_proc WHERE proname LIKE 'post_%' OR proname LIKE 'mark_%' OR proname LIKE 'fn_%'
--  ORDER BY proname;
--
-- Smoke test (requires seed data — wallets, KYC):
--   SELECT * FROM post_topup('9701000000000099', 1000000, 'TEST-01', '{}', 'TREASURY', 'sys');
-- =============================================================================
