-- =============================================================================
-- schema.sql — consolidated DDL for the wallet database (PostgreSQL 17)
-- Tables (incl. the 4 PARTITIONED PARENTS, no child partitions), sequences,
-- indexes, constraints, functions, procedures, triggers (incl. balanced-posting
-- CONSTRAINT TRIGGER), views, extensions, GRANTs. NO data, NO partitions.
-- Child partitions are created by partitions.sql (run AFTER this). Indexes &
-- triggers live on the parents and propagate to partitions automatically.
-- Roles wallet_app/pii_ro/eod must exist before restore (GRANTs).
-- =============================================================================
--
-- PostgreSQL database dump
--

\restrict eNeiC0gZxcJL2tzxYid3O3nPahNN9QsS0H8w26RB3m1uj8FlOR0wtmZSdw1NR1v

-- Dumped from database version 17.10
-- Dumped by pg_dump version 17.10

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: pgcrypto; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;


--
-- Name: EXTENSION pgcrypto; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pgcrypto IS 'cryptographic functions';


--
-- Name: uuid-ossp; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA public;


--
-- Name: EXTENSION "uuid-ossp"; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION "uuid-ossp" IS 'generate universally unique identifiers (UUIDs)';


--
-- Name: app.pii_dek; Type: DATABASE SETTING; Schema: -; Owner: -
--
-- Dev DEK for pgp_sym_encrypt/decrypt of PII (phone/email/beneficiary acct) used
-- by fn_create_client, the posting SPs, and the masked views. Set per-database so
-- it survives reconnects (PgBouncer txn-mode). OVERRIDE IN PROD via KMS. DB-name
-- agnostic so this export restores cleanly into any target database name.
--

DO $pii_dek$ BEGIN
  EXECUTE format('ALTER DATABASE %I SET app.pii_dek = %L',
                 current_database(), 'dev_only_change_in_prod_kms');
END $pii_dek$;


--
-- Name: activate_hot_wallet(character varying, smallint, character varying, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.activate_hot_wallet(p_group_id character varying, p_shard_count smallint DEFAULT 4, p_channel character varying DEFAULT 'OPS'::character varying, p_actor character varying DEFAULT NULL::character varying) RETURNS TABLE(group_id character varying, shard_count smallint, settlement_acct_no character varying, shard_acct_nos character varying[])
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_catalog'
    AS $$
#variable_conflict use_column
-- Promote a cold merchant/agent group (0 shards) to a hot wallet by
-- materialising N empty SHARD sub-accounts and flipping WLT_ACCT_GROUP.SHARD_COUNT.
--
-- Shards are created with ZERO balance — no funds move, so no ledger entry is
-- needed (same invariant as open_account: never inject off-ledger balance). The
-- settlement account keeps the whole balance; incoming top-ups route to shards
-- via fn_resolve_shard_acct_no, and post_sweep_shard later drains them back.
--
-- One-way from cold: re-activating an already-hot group raises
-- GROUP_ALREADY_ACTIVATED (rescaling an existing fleet is a separate operation).
-- SECURITY DEFINER because wallet_app holds only SELECT on WLT_ACCT_GROUP.
DECLARE
  v_grp      WLT_ACCT_GROUP%ROWTYPE;
  v_settle   WLT_ACCT%ROWTYPE;
  v_existing INT;
  v_no       VARCHAR(20);
  v_accts    VARCHAR(20)[] := '{}';
  i          INT;
BEGIN
  PERFORM set_config('audit.actor',   COALESCE(p_actor, 'ops'), TRUE);
  PERFORM set_config('audit.channel', COALESCE(p_channel, 'OPS'), TRUE);

  -- 1. shard count must be a supported hot tier (mirrors chk_shard_count: 4/8/16)
  IF p_shard_count NOT IN (4, 8, 16) THEN
    RAISE EXCEPTION 'INVALID_SHARD_COUNT: % (allowed: 4, 8, 16)', p_shard_count
      USING ERRCODE = 'P0052';
  END IF;

  -- 2. lock the group; must exist
  SELECT * INTO v_grp FROM WLT_ACCT_GROUP WHERE GROUP_ID = p_group_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'GROUP_NOT_FOUND: %', p_group_id USING ERRCODE = 'P0050';
  END IF;

  -- 3. activation is one-way from cold (shard_count = 0 AND no physical shards)
  SELECT count(*) INTO v_existing FROM WLT_ACCT
   WHERE GROUP_ID = p_group_id AND ACCT_ROLE = 'SHARD';
  IF v_grp.SHARD_COUNT <> 0 OR v_existing > 0 THEN
    RAISE EXCEPTION 'GROUP_ALREADY_ACTIVATED: % already has % shard(s)', p_group_id, v_existing
      USING ERRCODE = 'P0053';
  END IF;

  -- 4. settlement account anchors client_no + ccy + acct_type for the new shards
  SELECT * INTO v_settle FROM WLT_ACCT
   WHERE GROUP_ID = p_group_id AND ACCT_ROLE = 'SETTLEMENT' FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'SETTLEMENT_NOT_FOUND: group % has no settlement account', p_group_id
      USING ERRCODE = 'P0054';
  END IF;

  -- 5. materialise N empty SHARD wallets (shard_index 0..N-1, balance 0)
  FOR i IN 0 .. p_shard_count - 1 LOOP
    v_no := '9701' || LPAD(nextval('seq_acct_no')::text, 10, '0');
    INSERT INTO WLT_ACCT (ACCT_NO, CLIENT_NO, ACCT_TYPE, CCY, ACCT_STATUS,
       ACTUAL_BAL, PREV_DAY_ACTUAL_BAL, ACCT_ROLE, GROUP_ID, SHARD_INDEX, CHANNEL)
    VALUES (v_no, v_settle.CLIENT_NO, v_settle.ACCT_TYPE, v_settle.CCY, 'A',
       0, 0, 'SHARD', p_group_id, i, p_channel);
    v_accts := array_append(v_accts, v_no);
  END LOOP;

  -- 6. flip the group's configured shard_count to the hot tier
  UPDATE WLT_ACCT_GROUP SET SHARD_COUNT = p_shard_count WHERE GROUP_ID = p_group_id;

  RETURN QUERY SELECT p_group_id, p_shard_count, v_settle.ACCT_NO, v_accts;
END $$;


--
-- Name: add_restraint(character varying, character varying, character varying, numeric, date, date, character varying, character varying, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.add_restraint(p_acct_no character varying, p_type character varying, p_purpose character varying, p_pledged_amt numeric DEFAULT 0, p_start_date date DEFAULT CURRENT_DATE, p_end_date date DEFAULT NULL::date, p_narrative character varying DEFAULT NULL::character varying, p_reference_doc character varying DEFAULT NULL::character varying, p_actor character varying DEFAULT NULL::character varying) RETURNS TABLE(restraint_id bigint, status character varying, pledged_amt numeric, available_bal_after numeric, version integer)
    LANGUAGE plpgsql
    AS $$
#variable_conflict use_column
DECLARE
  v_acct    WLT_ACCT%ROWTYPE;
  v_actor   VARCHAR(40)   := COALESCE(p_actor, session_user);
  v_start   DATE          := COALESCE(p_start_date, CURRENT_DATE);
  v_pledged NUMERIC(18,2) := COALESCE(p_pledged_amt, 0);
  v_id      BIGINT;
  v_restr   NUMERIC(18,2);
  v_ver     INTEGER;
BEGIN
  -- ── validation (cheap, no lock) ──
  IF p_type NOT IN ('DEBIT','CREDIT','ALL','INFO') THEN
    RAISE EXCEPTION 'RESTRAINT_TYPE_INVALID' USING ERRCODE = 'P0060';
  END IF;
  IF p_purpose NOT IN ('COURT_ORDER','AML_HOLD','DISPUTE_HOLD','FRAUD_HOLD',
                       'TAX_LIEN','PLEDGE','FRAUD_WATCH','KYC_REVIEW') THEN
    RAISE EXCEPTION 'RESTRAINT_PURPOSE_INVALID' USING ERRCODE = 'P0061';
  END IF;
  -- hard type↔purpose constraints (RST-11): court must be ALL, pledge must be DEBIT
  IF (p_purpose = 'COURT_ORDER' AND p_type <> 'ALL')
     OR (p_purpose = 'PLEDGE' AND p_type <> 'DEBIT') THEN
    RAISE EXCEPTION 'RESTRAINT_TYPE_PURPOSE_CONFLICT' USING ERRCODE = 'P0062';
  END IF;
  IF p_end_date IS NOT NULL AND p_end_date < v_start THEN
    RAISE EXCEPTION 'RESTRAINT_DATE_INVALID' USING ERRCODE = 'P0063';
  END IF;

  IF p_type = 'INFO' THEN
    v_pledged := 0;   -- INFO never reserves funds
  END IF;

  -- ── lock the account row ──
  SELECT * INTO v_acct FROM WLT_ACCT WHERE acct_no = p_acct_no FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ACCT_NOT_FOUND: %', p_acct_no USING ERRCODE = 'P0001';
  END IF;
  IF v_acct.acct_status = 'C' THEN
    RAISE EXCEPTION 'ACCT_NOT_ACTIVE: account closed' USING ERRCODE = 'P0004';
  END IF;

  IF p_type IN ('DEBIT','ALL') AND v_pledged > 0 AND v_pledged > v_acct.actual_bal THEN
    RAISE EXCEPTION 'RESTRAINT_AMT_EXCEEDS_BALANCE' USING ERRCODE = 'P0064';
  END IF;

  -- ── insert the restraint ──
  INSERT INTO WLT_RESTRAINTS(
    internal_key, restraint_type, restraint_purpose, pledged_amt,
    start_date, end_date, status, narrative, reference_doc, created_by)
  VALUES (
    v_acct.internal_key, p_type, p_purpose, v_pledged,
    v_start, p_end_date, 'A', p_narrative, p_reference_doc, v_actor)
  RETURNING seq_no INTO v_id;

  -- ── roll up onto the account ──
  UPDATE WLT_ACCT
     SET total_restrained_amt = total_restrained_amt
                                + CASE WHEN p_type IN ('DEBIT','ALL') THEN v_pledged ELSE 0 END,
         cr_blocked           = CASE WHEN p_type IN ('CREDIT','ALL') THEN 'Y' ELSE cr_blocked END,
         restraint_present    = 'Y',
         version              = version + 1
   WHERE internal_key = v_acct.internal_key
   RETURNING total_restrained_amt, version INTO v_restr, v_ver;

  RETURN QUERY SELECT v_id, 'A'::varchar, v_pledged,
                      (v_acct.actual_bal - v_restr)::numeric, v_ver;
END;
$$;


--
-- Name: create_client(character varying, character varying, character varying, character varying, character varying, character varying, character varying, character varying, date, character varying, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_client(p_client_name character varying, p_client_type character varying, p_global_id character varying DEFAULT NULL::character varying, p_global_id_type character varying DEFAULT NULL::character varying, p_country_loc character varying DEFAULT 'VN'::character varying, p_country_citizen character varying DEFAULT 'VN'::character varying, p_surname character varying DEFAULT NULL::character varying, p_given_name character varying DEFAULT NULL::character varying, p_birth_date date DEFAULT NULL::date, p_sex character varying DEFAULT NULL::character varying, p_actor character varying DEFAULT NULL::character varying) RETURNS TABLE(client_no character varying, status character varying, created_at timestamp with time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
#variable_conflict use_column
DECLARE
  v_no      VARCHAR(48);
  v_created TIMESTAMPTZ;
  v_extra   JSONB;
BEGIN
  -- Unified client types: IND (individual), CORP (corporate), MER (merchant).
  -- CORP and MER are organization-like and handled identically below (no INDVL row).
  IF p_client_type IS NULL OR p_client_type NOT IN ('IND','CORP','MER') THEN
    RAISE EXCEPTION 'INVALID_CLIENT_TYPE' USING ERRCODE = 'P0070';
  END IF;
  IF p_client_name IS NULL OR length(btrim(p_client_name)) = 0 THEN
    RAISE EXCEPTION 'INVALID_REQUEST: client_name required' USING ERRCODE = 'P0071';
  END IF;
  IF p_global_id IS NOT NULL AND EXISTS (
       SELECT 1 FROM FM_CLIENT
        WHERE global_id = p_global_id
          AND global_id_type = COALESCE(p_global_id_type, 'CCCD')) THEN
    RAISE EXCEPTION 'CLIENT_ALREADY_EXISTS' USING ERRCODE = 'P0072';
  END IF;

  v_no := 'C' || LPAD(nextval('seq_client')::text, 10, '0');

  INSERT INTO FM_CLIENT(client_no, global_id, global_id_type, client_name,
       client_type, country_loc, country_citizen, status)
  VALUES (v_no, p_global_id, p_global_id_type, p_client_name,
       p_client_type, COALESCE(p_country_loc, 'VN'), COALESCE(p_country_citizen, 'VN'), 'A')
  RETURNING created_at INTO v_created;

  -- Centralized KYC (US-1.15): exactly one FM_CLIENT_KYC row per client; type-specific
  -- identity lives in extra_data JSONB (FM_CLIENT_INDVL folded in). The onboarding flow
  -- captures the phone later, so the phone columns stay NULL here (tier 1 / status P).
  IF p_client_type = 'IND' THEN
    v_extra := jsonb_strip_nulls(jsonb_build_object(
      'surname',         p_surname,
      'given_name',      p_given_name,
      'resident_status', 'R'));
  ELSE
    v_extra := '{}'::jsonb;   -- ORG (CORP/MER): legal_rep/ubo/business_reg_no set via onboarding
  END IF;

  -- Identity document + personal birth/sex are flat real columns; the rest of
  -- the type-specific bag stays in extra_data.
  INSERT INTO FM_CLIENT_KYC(client_no, kyc_tier, status, extra_data,
       global_id, global_id_type, birthdate, sex)
  VALUES (v_no, '1', 'P', v_extra,
       p_global_id,
       CASE WHEN p_global_id IS NULL THEN NULL ELSE COALESCE(p_global_id_type, 'CCCD') END,
       p_birth_date, p_sex);

  RETURN QUERY SELECT v_no, 'A'::varchar, v_created;
END;
$$;


--
-- Name: onboard_client(...); Type: FUNCTION; Schema: public; Owner: -
--
-- US-1.1 (OTP-free) + US-1.7: step 1 of onboarding — create the client, its
-- centralized FM_CLIENT_KYC row (tier 1, phone captured here — no OTP), and open
-- the first zero-balance wallet, all in ONE transaction. Type-specific identity
-- (IND surname/given_name/…, ORG legal_rep/ubo/business_reg_no/…) rides extra_data.
--

CREATE FUNCTION public.onboard_client(p_client_name character varying, p_client_type character varying, p_phone character varying, p_global_id character varying DEFAULT NULL::character varying, p_global_id_type character varying DEFAULT NULL::character varying, p_email character varying DEFAULT NULL::character varying, p_country_loc character varying DEFAULT 'VN'::character varying, p_country_citizen character varying DEFAULT 'VN'::character varying, p_acct_type character varying DEFAULT 'CONSUMER'::character varying, p_ccy character varying DEFAULT 'VND'::character varying, p_birth_date date DEFAULT NULL::date, p_sex character varying DEFAULT NULL::character varying, p_date_issue date DEFAULT NULL::date, p_expire_date date DEFAULT NULL::date, p_place_issue character varying DEFAULT NULL::character varying, p_extra_data jsonb DEFAULT '{}'::jsonb, p_actor character varying DEFAULT NULL::character varying) RETURNS TABLE(client_no character varying, acct_no character varying, internal_key bigint, kyc_tier character varying, kyc_status character varying, balance numeric, ccy character varying, created_at timestamp with time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
#variable_conflict use_column
DECLARE
  v_no      VARCHAR(48);
  v_created TIMESTAMPTZ;
  v_dek     TEXT  := current_setting('app.pii_dek', TRUE);
  v_extra   JSONB := COALESCE(p_extra_data, '{}'::jsonb);
  v_ccy     VARCHAR(4) := COALESCE(p_ccy, 'VND');
  v_acct    VARCHAR(20);
  v_key     BIGINT;
BEGIN
  IF p_client_type IS NULL OR p_client_type NOT IN ('IND','CORP','MER') THEN
    RAISE EXCEPTION 'INVALID_CLIENT_TYPE' USING ERRCODE = 'P0070';
  END IF;
  IF p_client_name IS NULL OR length(btrim(p_client_name)) = 0 THEN
    RAISE EXCEPTION 'INVALID_REQUEST: client_name required' USING ERRCODE = 'P0071';
  END IF;
  IF p_phone IS NULL OR p_phone !~ '^0[0-9]{9}$' THEN
    RAISE EXCEPTION 'INVALID_PHONE_FORMAT: %', p_phone USING ERRCODE = 'P0076';
  END IF;
  IF v_dek IS NULL OR v_dek = '' THEN
    RAISE EXCEPTION 'PII_DEK_NOT_SET — set ALTER DATABASE ... SET app.pii_dek=...'
      USING ERRCODE = 'P0030';
  END IF;
  IF jsonb_typeof(v_extra) <> 'object' THEN
    RAISE EXCEPTION 'INVALID_REQUEST: extra_data must be a JSON object' USING ERRCODE = 'P0071';
  END IF;
  -- BR-09 (US-1.7): organizations must carry the legal identity in extra_data.
  IF p_client_type IN ('CORP','MER')
     AND NOT (v_extra ? 'business_reg_no' AND v_extra ? 'legal_rep') THEN
    RAISE EXCEPTION 'ORG_FIELDS_REQUIRED: business_reg_no + legal_rep' USING ERRCODE = 'P0077';
  END IF;
  IF p_global_id IS NOT NULL AND EXISTS (
       SELECT 1 FROM FM_CLIENT
        WHERE global_id = p_global_id
          AND global_id_type = COALESCE(p_global_id_type, 'CCCD')) THEN
    RAISE EXCEPTION 'CLIENT_ALREADY_EXISTS' USING ERRCODE = 'P0072';
  END IF;
  IF EXISTS (SELECT 1 FROM FM_CLIENT_KYC WHERE phone_no_hash = digest(p_phone, 'sha256')) THEN
    RAISE EXCEPTION 'PHONE_ALREADY_REGISTERED' USING ERRCODE = 'P0075';
  END IF;

  v_no := 'C' || LPAD(nextval('seq_client')::text, 10, '0');

  INSERT INTO FM_CLIENT(client_no, global_id, global_id_type, client_name,
       client_type, country_loc, country_citizen, status)
  VALUES (v_no, p_global_id, p_global_id_type, p_client_name,
       p_client_type, COALESCE(p_country_loc, 'VN'), COALESCE(p_country_citizen, 'VN'), 'A')
  RETURNING created_at INTO v_created;

  -- Centralized KYC (US-1.15): phone is captured at registration (no OTP); the
  -- client is active at tier 1 (receive-only — tier 2+ unlocked via update_kyc).
  INSERT INTO FM_CLIENT_KYC(client_no, phone_no_enc, phone_no_hash, email_enc,
       kyc_tier, status, extra_data,
       global_id, global_id_type, date_issue, expire_date, place_issue, birthdate, sex)
  VALUES (v_no,
       pgp_sym_encrypt(p_phone, v_dek, 'cipher-algo=aes256'),
       digest(p_phone, 'sha256'),
       CASE WHEN p_email IS NULL THEN NULL
            ELSE pgp_sym_encrypt(p_email, v_dek, 'cipher-algo=aes256') END,
       '1', 'A', v_extra,
       p_global_id,
       CASE WHEN p_global_id IS NULL THEN NULL ELSE COALESCE(p_global_id_type, 'CCCD') END,
       p_date_issue, p_expire_date, p_place_issue, p_birth_date, p_sex);

  -- Open the first wallet (zero balance) in the same TX — reuses the acct-type /
  -- per-client count guards in open_account.
  SELECT o.acct_no, o.internal_key INTO v_acct, v_key
    FROM open_account(v_no, COALESCE(p_acct_type, 'CONSUMER'), v_ccy, p_actor) o;

  RETURN QUERY SELECT v_no, v_acct, v_key, '1'::varchar, 'A'::varchar, 0::numeric, v_ccy, v_created;
END;
$$;


--
-- Name: update_kyc(...); Type: FUNCTION; Schema: public; Owner: -
--
-- US-1.2: step 2 of onboarding — submit/update KYC info (eKYC result) and raise
-- the tier. Patches the centralized FM_CLIENT_KYC row; non-null args overwrite,
-- p_extra_data is MERGED (jsonb ||). Reaching tier >= 2 stamps verified_at/by.
--

CREATE FUNCTION public.update_kyc(p_client_no character varying, p_kyc_tier character varying DEFAULT NULL::character varying, p_status character varying DEFAULT NULL::character varying, p_risk_level character varying DEFAULT NULL::character varying, p_ekyc_provider character varying DEFAULT NULL::character varying, p_ekyc_ref character varying DEFAULT NULL::character varying, p_face_match_score numeric DEFAULT NULL::numeric, p_liveness_result character varying DEFAULT NULL::character varying, p_extra_data jsonb DEFAULT NULL::jsonb, p_actor character varying DEFAULT NULL::character varying) RETURNS TABLE(client_no character varying, kyc_tier character varying, status character varying, risk_level character varying, verified_at timestamp with time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
#variable_conflict use_column
DECLARE
  v_tier     VARCHAR(4);
  v_status   VARCHAR(4);
  v_risk     VARCHAR(4);
  v_verified TIMESTAMPTZ;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM FM_CLIENT WHERE client_no = p_client_no) THEN
    RAISE EXCEPTION 'CLIENT_NOT_FOUND' USING ERRCODE = 'P0073';
  END IF;
  IF p_kyc_tier IS NOT NULL AND p_kyc_tier NOT IN ('0','1','2','3') THEN
    RAISE EXCEPTION 'INVALID_REQUEST: kyc_tier must be 0..3' USING ERRCODE = 'P0071';
  END IF;
  IF p_extra_data IS NOT NULL AND jsonb_typeof(p_extra_data) <> 'object' THEN
    RAISE EXCEPTION 'INVALID_REQUEST: extra_data must be a JSON object' USING ERRCODE = 'P0071';
  END IF;

  UPDATE FM_CLIENT_KYC
     SET kyc_tier         = COALESCE(p_kyc_tier, kyc_tier),
         status           = COALESCE(p_status, status),
         risk_level       = COALESCE(p_risk_level, risk_level),
         ekyc_provider    = COALESCE(p_ekyc_provider, ekyc_provider),
         ekyc_ref         = COALESCE(p_ekyc_ref, ekyc_ref),
         face_match_score = COALESCE(p_face_match_score, face_match_score),
         liveness_result  = COALESCE(p_liveness_result, liveness_result),
         extra_data       = CASE WHEN p_extra_data IS NULL THEN extra_data
                                 ELSE extra_data || p_extra_data END,
         verified_at      = CASE WHEN p_kyc_tier IS NOT NULL AND p_kyc_tier >= '2'
                                 THEN NOW() ELSE verified_at END,
         verified_by      = CASE WHEN p_kyc_tier IS NOT NULL AND p_kyc_tier >= '2'
                                 THEN COALESCE(p_actor, verified_by) ELSE verified_by END
   WHERE client_no = p_client_no
   RETURNING kyc_tier, status, risk_level, verified_at
        INTO v_tier, v_status, v_risk, v_verified;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'KYC_NOT_FOUND: %', p_client_no USING ERRCODE = 'P0078';
  END IF;

  RETURN QUERY SELECT p_client_no, v_tier, v_status, v_risk, v_verified;
END;
$$;


--
-- Name: eod_close_period(date); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.eod_close_period(IN p_biz_date date)
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_started TIMESTAMPTZ := clock_timestamp();
  v_missing TEXT;
  v_unbal   INTEGER;
BEGIN
  IF p_biz_date IS NULL THEN
    RAISE EXCEPTION 'EOD_INVALID_DATE' USING ERRCODE = 'P0090';
  END IF;
  IF p_biz_date >= CURRENT_DATE THEN
    RAISE EXCEPTION 'EOD_PERIOD_NOT_PAST: cannot close % — not strictly before CURRENT_DATE (%)',
      p_biz_date, CURRENT_DATE USING ERRCODE = 'P0090';
  END IF;
  PERFORM set_config('audit.actor', 'EOD', false);

  -- already closed → idempotent no-op
  IF EXISTS (SELECT 1 FROM WLT_PERIOD WHERE biz_date = p_biz_date AND status = 'CLOSED') THEN
    PERFORM eod_log(p_biz_date, 'CLOSE_PERIOD', 'DONE', 0, v_started, 'already closed');
    COMMIT;
    RETURN;
  END IF;

  -- every prerequisite task must be DONE before the period may be sealed
  SELECT string_agg(t.task, ', ') INTO v_missing
    FROM (VALUES ('SNAPSHOT'),('PREV_DAY_ROLL'),('EXPIRE_RESTRAINTS'),('GL_FEED'),('TRIAL_BALANCE'))
           AS t(task)
   WHERE NOT EXISTS (SELECT 1 FROM WLT_EOD_RUN r
                      WHERE r.biz_date = p_biz_date AND r.task = t.task AND r.status = 'DONE');
  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION 'EOD_PERIOD_INCOMPLETE: task(s) not DONE for %: %', p_biz_date, v_missing
      USING ERRCODE = 'P0091';
  END IF;

  -- record (never block on) an unbalanced trial balance — see US-6.3
  SELECT count(*) INTO v_unbal FROM WLT_TRIAL_BALANCE_PROOF
   WHERE biz_date = p_biz_date AND is_balanced = false;
  IF v_unbal > 0 THEN
    RAISE WARNING 'CLOSE_PERIOD %: % currency proof(s) NOT balanced — sealing anyway (recorded in proof)',
      p_biz_date, v_unbal;
  END IF;

  INSERT INTO WLT_PERIOD(biz_date, status, closed_at, closed_by)
       VALUES (p_biz_date, 'CLOSED', now(), 'EOD')
  ON CONFLICT (biz_date) DO UPDATE
       SET status = 'CLOSED', closed_at = now(), closed_by = 'EOD';

  INSERT INTO WLT_EOD_RUN(biz_date, task, status, last_key, started_at, finished_at)
       VALUES (p_biz_date, 'CLOSE_PERIOD', 'DONE', 0, v_started, now())
  ON CONFLICT (biz_date, task)
       DO UPDATE SET status = 'DONE', finished_at = now(), message = NULL;
  PERFORM eod_log(p_biz_date, 'CLOSE_PERIOD', 'DONE', 1, v_started);
  COMMIT;
END;
$$;


--
-- Name: eod_expire_restraints(date); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.eod_expire_restraints(IN p_biz_date date)
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_keys    BIGINT[];
  v_key     BIGINT;
  v_n       BIGINT := 0;
  v_started TIMESTAMPTZ := clock_timestamp();
BEGIN
  IF p_biz_date IS NULL THEN
    RAISE EXCEPTION 'EOD_INVALID_DATE' USING ERRCODE = 'P0090';
  END IF;
  PERFORM set_config('audit.actor', 'EOD', false);

  INSERT INTO WLT_EOD_RUN(biz_date, task, status, last_key, started_at)
       VALUES (p_biz_date, 'EXPIRE_RESTRAINTS', 'RUNNING', 0, now())
  ON CONFLICT (biz_date, task)
       DO UPDATE SET status = 'RUNNING', started_at = now(), message = NULL;

  -- account-scoped restraints whose window closed before the business date
  SELECT array_agg(DISTINCT internal_key) INTO v_keys
    FROM WLT_RESTRAINTS
   WHERE status = 'A' AND internal_key IS NOT NULL
     AND end_date IS NOT NULL AND end_date < p_biz_date;

  IF v_keys IS NOT NULL THEN
    FOREACH v_key IN ARRAY v_keys LOOP          -- array iteration: COMMIT-safe (no portal)
      UPDATE WLT_RESTRAINTS
         SET status = 'E', removed_at = now(), removed_by = 'EOD',
             removed_reason = 'auto-expired: end_date < ' || p_biz_date::text
       WHERE internal_key = v_key AND status = 'A'
         AND end_date IS NOT NULL AND end_date < p_biz_date;

      UPDATE WLT_ACCT a
         SET total_restrained_amt = agg.restr,
             cr_blocked           = agg.crblk,
             restraint_present    = agg.present,
             version              = a.version + 1
        FROM (
          SELECT
            COALESCE(SUM(CASE WHEN restraint_type IN ('DEBIT','ALL')
                              THEN pledged_amt ELSE 0 END), 0)                 AS restr,
            CASE WHEN bool_or(restraint_type IN ('CREDIT','ALL'))
                 THEN 'Y' ELSE 'N' END                                        AS crblk,
            CASE WHEN count(*) > 0 THEN 'Y' ELSE 'N' END                      AS present
          FROM WLT_RESTRAINTS
           WHERE internal_key = v_key AND status = 'A'
             AND p_biz_date BETWEEN start_date AND COALESCE(end_date, DATE '9999-12-31')
        ) agg
       WHERE a.internal_key = v_key;

      v_n := v_n + 1;
      COMMIT;
    END LOOP;
  END IF;

  UPDATE WLT_EOD_RUN SET status = 'DONE', finished_at = now(), rows_done = v_n
    WHERE biz_date = p_biz_date AND task = 'EXPIRE_RESTRAINTS';
  PERFORM eod_log(p_biz_date, 'EXPIRE_RESTRAINTS', 'DONE', v_n, v_started);
  COMMIT;
END;
$$;


--
-- Name: eod_gl_feed_post(date, bigint); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.eod_gl_feed_post(IN p_biz_date date, IN p_step bigint DEFAULT 50000)
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_lo      BIGINT;
  v_max     BIGINT;
  v_n       BIGINT;
  v_tot     BIGINT := 0;
  v_started TIMESTAMPTZ := clock_timestamp();
BEGIN
  IF p_biz_date IS NULL OR p_biz_date > CURRENT_DATE THEN
    RAISE EXCEPTION 'EOD_INVALID_DATE: %', p_biz_date USING ERRCODE = 'P0090';
  END IF;
  PERFORM set_config('audit.actor', 'EOD', false);   -- session-scoped: survives COMMITs

  INSERT INTO WLT_EOD_RUN(biz_date, task, status, last_key, started_at)
       VALUES (p_biz_date, 'GL_FEED', 'RUNNING', 0, now())
  ON CONFLICT (biz_date, task)
       DO UPDATE SET status = 'RUNNING', started_at = now(), message = NULL;

  SELECT last_key, rows_done INTO v_lo, v_tot
    FROM WLT_EOD_RUN WHERE biz_date = p_biz_date AND task = 'GL_FEED';
  SELECT COALESCE(max(tran_key), 0) INTO v_max FROM WLT_GL_BATCH WHERE post_date = p_biz_date;

  WHILE v_lo <= v_max LOOP
    UPDATE WLT_GL_BATCH
       SET status = 'S', time_stamp = now()
     WHERE post_date = p_biz_date
       AND status    = 'P'
       AND tran_key  >  v_lo
       AND tran_key  <= v_lo + p_step;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_tot := v_tot + v_n;
    v_lo  := v_lo + p_step;
    UPDATE WLT_EOD_RUN SET last_key = v_lo, rows_done = v_tot
      WHERE biz_date = p_biz_date AND task = 'GL_FEED';
    COMMIT;                                          -- short TX: release + advance xmin
  END LOOP;

  UPDATE WLT_EOD_RUN SET status = 'DONE', finished_at = now()
    WHERE biz_date = p_biz_date AND task = 'GL_FEED';
  PERFORM eod_log(p_biz_date, 'GL_FEED', 'DONE', v_tot, v_started);
  COMMIT;
END;
$$;


--
-- Name: eod_log(date, character varying, character varying, bigint, timestamp with time zone, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.eod_log(p_biz_date date, p_task character varying, p_status character varying, p_rows bigint, p_started timestamp with time zone, p_message text DEFAULT NULL::text) RETURNS void
    LANGUAGE sql
    AS $$
  INSERT INTO WLT_EOD_AUDIT_LOG(biz_date, task, status, rows_done, started_at, finished_at, message)
  VALUES (p_biz_date, p_task, p_status, p_rows, p_started, clock_timestamp(), p_message);
$$;


--
-- Name: eod_mark_failed(date, character varying, text); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.eod_mark_failed(IN p_biz_date date, IN p_task character varying, IN p_message text DEFAULT NULL::text)
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_started TIMESTAMPTZ;
BEGIN
  UPDATE WLT_EOD_RUN SET status = 'FAILED', finished_at = now(), message = p_message
    WHERE biz_date = p_biz_date AND task = p_task
    RETURNING started_at INTO v_started;
  PERFORM eod_log(p_biz_date, p_task, 'FAILED', 0, COALESCE(v_started, clock_timestamp()), p_message);
  COMMIT;
END;
$$;


--
-- Name: eod_prev_day_roll(date, bigint); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.eod_prev_day_roll(IN p_biz_date date, IN p_step bigint DEFAULT 10000)
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_lo      BIGINT;
  v_max     BIGINT;
  v_n       BIGINT;
  v_tot     BIGINT := 0;
  v_started TIMESTAMPTZ := clock_timestamp();
BEGIN
  IF p_biz_date IS NULL THEN
    RAISE EXCEPTION 'EOD_INVALID_DATE' USING ERRCODE = 'P0090';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM WLT_EOD_RUN
                  WHERE biz_date = p_biz_date AND task = 'SNAPSHOT' AND status = 'DONE') THEN
    RAISE EXCEPTION 'EOD_SNAPSHOT_NOT_DONE: run eod_snapshot(%) first', p_biz_date
      USING ERRCODE = 'P0091';
  END IF;
  PERFORM set_config('audit.actor', 'EOD', false);

  INSERT INTO WLT_EOD_RUN(biz_date, task, status, last_key, started_at)
       VALUES (p_biz_date, 'PREV_DAY_ROLL', 'RUNNING', 0, now())
  ON CONFLICT (biz_date, task)
       DO UPDATE SET status = 'RUNNING', started_at = now(), message = NULL;

  SELECT last_key, rows_done INTO v_lo, v_tot
    FROM WLT_EOD_RUN WHERE biz_date = p_biz_date AND task = 'PREV_DAY_ROLL';
  SELECT COALESCE(max(internal_key), 0) INTO v_max
    FROM WLT_ACCT_BAL WHERE tran_date = p_biz_date;

  WHILE v_lo <= v_max LOOP
    UPDATE WLT_ACCT a
       SET prev_day_actual_bal = b.actual_bal
      FROM WLT_ACCT_BAL b
     WHERE b.tran_date    = p_biz_date
       AND b.internal_key = a.internal_key
       AND b.internal_key >  v_lo
       AND b.internal_key <= v_lo + p_step
       AND a.prev_day_actual_bal IS DISTINCT FROM b.actual_bal;   -- skip no-op writes
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_tot := v_tot + v_n;
    v_lo  := v_lo + p_step;
    UPDATE WLT_EOD_RUN SET last_key = v_lo, rows_done = v_tot
      WHERE biz_date = p_biz_date AND task = 'PREV_DAY_ROLL';
    COMMIT;
  END LOOP;

  UPDATE WLT_EOD_RUN SET status = 'DONE', finished_at = now()
    WHERE biz_date = p_biz_date AND task = 'PREV_DAY_ROLL';
  PERFORM eod_log(p_biz_date, 'PREV_DAY_ROLL', 'DONE', v_tot, v_started);
  COMMIT;
END;
$$;


--
-- Name: eod_snapshot(date, bigint); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.eod_snapshot(IN p_biz_date date, IN p_step bigint DEFAULT 50000)
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_lo      BIGINT;
  v_max     BIGINT;
  v_n       BIGINT;
  v_tot     BIGINT := 0;
  v_started TIMESTAMPTZ := clock_timestamp();
BEGIN
  IF p_biz_date IS NULL OR p_biz_date > CURRENT_DATE THEN
    RAISE EXCEPTION 'EOD_INVALID_DATE: %', p_biz_date USING ERRCODE = 'P0090';
  END IF;
  PERFORM set_config('audit.actor', 'EOD', false);   -- session-scoped: survives COMMITs

  -- claim or resume the control row (does NOT reset last_key on resume)
  INSERT INTO WLT_EOD_RUN(biz_date, task, status, last_key, started_at)
       VALUES (p_biz_date, 'SNAPSHOT', 'RUNNING', 0, now())
  ON CONFLICT (biz_date, task)
       DO UPDATE SET status = 'RUNNING', started_at = now(), message = NULL;

  SELECT last_key, rows_done INTO v_lo, v_tot
    FROM WLT_EOD_RUN WHERE biz_date = p_biz_date AND task = 'SNAPSHOT';
  SELECT COALESCE(max(internal_key), 0) INTO v_max FROM WLT_ACCT;

  WHILE v_lo <= v_max LOOP
    WITH last_leg AS (
      SELECT DISTINCT ON (h.internal_key) h.internal_key, h.actual_bal_amt
        FROM WLT_TRAN_HIST h
       WHERE h.post_date = p_biz_date
         AND h.internal_key >  v_lo
         AND h.internal_key <= v_lo + p_step
       ORDER BY h.internal_key, h.seq_no DESC      -- last leg of the day
    )
    INSERT INTO WLT_ACCT_BAL(internal_key, tran_date, actual_bal, calc_bal,
                             prev_actual_bal, prev_calc_bal)
    SELECT l.internal_key,
           p_biz_date,
           l.actual_bal_amt,                                       -- close (ledger truth)
           l.actual_bal_amt - a.total_restrained_amt,              -- available (final overlay)
           a.prev_day_actual_bal,                                  -- INSERT-only: day-open
           a.prev_day_actual_bal                                   -- INSERT-only: prev available
      FROM last_leg l
      JOIN WLT_ACCT a ON a.internal_key = l.internal_key
    ON CONFLICT (internal_key, tran_date) DO UPDATE                -- finalise posting's row
       SET actual_bal    = EXCLUDED.actual_bal,
           calc_bal      = EXCLUDED.calc_bal,
           prev_calc_bal = COALESCE(WLT_ACCT_BAL.prev_calc_bal, WLT_ACCT_BAL.prev_actual_bal);
           -- prev_actual_bal NOT set: keep the day-open posting captured on leg 1

    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_tot := v_tot + v_n;
    v_lo  := v_lo + p_step;
    UPDATE WLT_EOD_RUN SET last_key = v_lo, rows_done = v_tot
      WHERE biz_date = p_biz_date AND task = 'SNAPSHOT';
    COMMIT;                                          -- short TX: release + advance xmin
  END LOOP;

  UPDATE WLT_EOD_RUN SET status = 'DONE', finished_at = now()
    WHERE biz_date = p_biz_date AND task = 'SNAPSHOT';
  PERFORM eod_log(p_biz_date, 'SNAPSHOT', 'DONE', v_tot, v_started);
  COMMIT;
END;
$$;


--
-- Name: eod_trial_balance(date); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.eod_trial_balance(IN p_biz_date date)
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_started TIMESTAMPTZ := clock_timestamp();
  r_ccy     RECORD;
  v_cnt     INTEGER;
  v_gdr     NUMERIC(24,2);
  v_gcr     NUMERIC(24,2);
  v_net     NUMERIC(24,2);
  v_content VARCHAR(64);
  v_prev    VARCHAR(64);
  v_chain   VARCHAR(64);
  v_bal     BOOLEAN;
BEGIN
  IF p_biz_date IS NULL OR p_biz_date > CURRENT_DATE THEN
    RAISE EXCEPTION 'EOD_INVALID_DATE: %', p_biz_date USING ERRCODE = 'P0090';
  END IF;
  PERFORM set_config('audit.actor', 'EOD', false);

  INSERT INTO WLT_EOD_RUN(biz_date, task, status, started_at)
       VALUES (p_biz_date, 'TRIAL_BALANCE', 'RUNNING', now())
  ON CONFLICT (biz_date, task)
       DO UPDATE SET status = 'RUNNING', started_at = now(), message = NULL;

  -- every currency that moved today, or carried a balance from the prior TB
  FOR r_ccy IN
    SELECT ccy FROM WLT_GL_BATCH WHERE post_date = p_biz_date
    UNION
    SELECT ccy FROM WLT_TRIAL_BALANCE
     WHERE biz_date = (SELECT max(biz_date) FROM WLT_TRIAL_BALANCE WHERE biz_date < p_biz_date)
  LOOP
    DELETE FROM WLT_TRIAL_BALANCE WHERE biz_date = p_biz_date AND ccy = r_ccy.ccy;  -- idempotent rebuild

    INSERT INTO WLT_TRIAL_BALANCE(biz_date, gl_code, ccy, gl_desc,
                                  opening_bal, period_dr, period_cr, closing_bal)
    WITH prior AS (            -- carry-forward opening = most recent prior closing
      SELECT gl_code, closing_bal
        FROM WLT_TRIAL_BALANCE
       WHERE ccy = r_ccy.ccy
         AND biz_date = (SELECT max(biz_date) FROM WLT_TRIAL_BALANCE
                          WHERE ccy = r_ccy.ccy AND biz_date < p_biz_date)
    ),
    today AS (                 -- today's GL movement
      SELECT gl_code,
             COALESCE(SUM(amount) FILTER (WHERE tran_nature = 'DR'), 0) AS dr,
             COALESCE(SUM(amount) FILTER (WHERE tran_nature = 'CR'), 0) AS cr
        FROM WLT_GL_BATCH
       WHERE post_date = p_biz_date AND ccy = r_ccy.ccy
       GROUP BY gl_code
    ),
    keys AS (SELECT gl_code FROM prior UNION SELECT gl_code FROM today)
    SELECT p_biz_date, k.gl_code, r_ccy.ccy, g.gl_code_desc,
           COALESCE(pr.closing_bal, 0),
           COALESCE(t.dr, 0),
           COALESCE(t.cr, 0),
           COALESCE(pr.closing_bal, 0) + COALESCE(t.dr, 0) - COALESCE(t.cr, 0)
      FROM keys k
      LEFT JOIN prior pr ON pr.gl_code = k.gl_code
      LEFT JOIN today t  ON t.gl_code  = k.gl_code
      JOIN fm_gl_mast g  ON g.gl_code  = k.gl_code;

    -- totals + canonical content hash over the ordered lines
    SELECT count(*), COALESCE(sum(period_dr), 0), COALESCE(sum(period_cr), 0),
           COALESCE(sum(closing_bal), 0),
           encode(sha256(convert_to(
             COALESCE(string_agg(gl_code || ':' || period_dr || ':' || period_cr || ':' || closing_bal,
                                  '|' ORDER BY gl_code), ''), 'UTF8')), 'hex')
      INTO v_cnt, v_gdr, v_gcr, v_net, v_content
      FROM WLT_TRIAL_BALANCE WHERE biz_date = p_biz_date AND ccy = r_ccy.ccy;

    v_bal := (v_gdr = v_gcr AND v_net = 0);

    SELECT chain_hash INTO v_prev
      FROM WLT_TRIAL_BALANCE_PROOF
     WHERE ccy = r_ccy.ccy AND biz_date < p_biz_date
     ORDER BY biz_date DESC LIMIT 1;
    v_prev := COALESCE(v_prev, 'GENESIS');

    v_chain := encode(sha256(convert_to(
      p_biz_date::text || '|' || r_ccy.ccy || '|' || v_gdr || '|' || v_gcr || '|' ||
      v_net || '|' || v_content || '|' || v_prev, 'UTF8')), 'hex');

    INSERT INTO WLT_TRIAL_BALANCE_PROOF(biz_date, ccy, gl_count, grand_dr, grand_cr,
                                        net_balance, is_balanced, content_hash, prev_hash, chain_hash)
    VALUES (p_biz_date, r_ccy.ccy, v_cnt, v_gdr, v_gcr, v_net, v_bal, v_content, v_prev, v_chain)
    ON CONFLICT (biz_date, ccy) DO UPDATE SET
      gl_count = EXCLUDED.gl_count, grand_dr = EXCLUDED.grand_dr, grand_cr = EXCLUDED.grand_cr,
      net_balance = EXCLUDED.net_balance, is_balanced = EXCLUDED.is_balanced,
      content_hash = EXCLUDED.content_hash, prev_hash = EXCLUDED.prev_hash, chain_hash = EXCLUDED.chain_hash;

    IF NOT v_bal THEN
      RAISE WARNING 'TRIAL BALANCE NOT BALANCED % %: DR=% CR=% net=%',
        p_biz_date, r_ccy.ccy, v_gdr, v_gcr, v_net;
    END IF;
  END LOOP;

  SELECT count(*) INTO v_cnt FROM WLT_TRIAL_BALANCE WHERE biz_date = p_biz_date;
  UPDATE WLT_EOD_RUN SET status = 'DONE', finished_at = now(), rows_done = v_cnt
    WHERE biz_date = p_biz_date AND task = 'TRIAL_BALANCE';
  PERFORM eod_log(p_biz_date, 'TRIAL_BALANCE', 'DONE', v_cnt, v_started);
  COMMIT;
END;
$$;


--
-- Name: eod_verify_chain(character varying, date, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.eod_verify_chain(p_ccy character varying, p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date) RETURNS TABLE(biz_date date, is_balanced boolean, chain_ok boolean, link_ok boolean)
    LANGUAGE plpgsql
    AS $$
DECLARE
  r       RECORD;
  v_gdr   NUMERIC(24,2);
  v_gcr   NUMERIC(24,2);
  v_net   NUMERIC(24,2);
  v_cont  VARCHAR(64);
  v_chain VARCHAR(64);
  v_prev  VARCHAR(64) := 'GENESIS';
BEGIN
  FOR r IN
    SELECT pf.* FROM WLT_TRIAL_BALANCE_PROOF pf
     WHERE pf.ccy = p_ccy
       AND (p_from IS NULL OR pf.biz_date >= p_from)
       AND (p_to   IS NULL OR pf.biz_date <= p_to)
     ORDER BY pf.biz_date
  LOOP
    SELECT COALESCE(sum(tb.period_dr), 0), COALESCE(sum(tb.period_cr), 0), COALESCE(sum(tb.closing_bal), 0),
           encode(sha256(convert_to(
             COALESCE(string_agg(tb.gl_code || ':' || tb.period_dr || ':' || tb.period_cr || ':' || tb.closing_bal,
                                  '|' ORDER BY tb.gl_code), ''), 'UTF8')), 'hex')
      INTO v_gdr, v_gcr, v_net, v_cont
      FROM WLT_TRIAL_BALANCE tb WHERE tb.biz_date = r.biz_date AND tb.ccy = p_ccy;

    v_chain := encode(sha256(convert_to(
      r.biz_date::text || '|' || p_ccy || '|' || v_gdr || '|' || v_gcr || '|' ||
      v_net || '|' || v_cont || '|' || r.prev_hash, 'UTF8')), 'hex');

    biz_date    := r.biz_date;
    is_balanced := r.is_balanced;
    chain_ok    := (v_chain = r.chain_hash);   -- recomputed from stored lines == sealed?
    link_ok     := (r.prev_hash = v_prev);     -- prev_hash links to the previous day's chain?
    v_prev      := r.chain_hash;
    RETURN NEXT;
  END LOOP;
END;
$$;


--
-- Name: fn_assert_batch_balanced(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_assert_batch_balanced() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public', 'pg_catalog'
    AS $$
DECLARE
  v_dr NUMERIC(20,2);
  v_cr NUMERIC(20,2);
BEGIN
  SELECT COALESCE(SUM(AMOUNT) FILTER (WHERE TRAN_NATURE = 'DR'), 0),
         COALESCE(SUM(AMOUNT) FILTER (WHERE TRAN_NATURE = 'CR'), 0)
    INTO v_dr, v_cr
    -- GL-journal table is WLT_GL_BATCH on the current schema (renamed from
    -- WLT_BATCH). PL/pgSQL resolves this at execution time, so on a pre-rename
    -- upgrade the function is created harmlessly and the table exists by the
    -- time the trigger first fires (rename migration sorts AFTER this one).
    FROM WLT_GL_BATCH
   WHERE TRAN_KEY = NEW.TRAN_KEY
     AND CCY      = NEW.CCY;

  IF v_dr <> v_cr THEN
    RAISE EXCEPTION 'BATCH_UNBALANCED: tran_key=% ccy=% DR=% CR=%',
      NEW.TRAN_KEY, NEW.CCY, v_dr, v_cr
      USING ERRCODE = 'P0091';
  END IF;
  RETURN NULL;  -- AFTER trigger: result ignored
END
$$;


--
-- Name: fn_audit_client_change(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_audit_client_change() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
  v_old        JSONB;
  v_new        JSONB;
  v_diff       TEXT[];
  v_client_no  VARCHAR(48);
  v_pk         JSONB;
  v_actor      VARCHAR(64);
  v_src        VARCHAR(16);
BEGIN
  v_actor := COALESCE(current_setting('audit.actor', TRUE), session_user);
  v_src   := COALESCE(current_setting('audit.source', TRUE), 'SP_BACKFILL');

  IF TG_OP = 'INSERT' THEN
    v_old := NULL;
    v_new := to_jsonb(NEW);
    v_diff := ARRAY(SELECT jsonb_object_keys(v_new));
    v_client_no := NEW.CLIENT_NO;
  ELSIF TG_OP = 'UPDATE' THEN
    v_old := to_jsonb(OLD);
    v_new := to_jsonb(NEW);
    v_diff := ARRAY(
      SELECT k FROM jsonb_object_keys(v_new) k
       WHERE v_old->k IS DISTINCT FROM v_new->k
    );
    IF cardinality(v_diff) = 0 THEN
      RETURN NEW;
    END IF;
    v_client_no := NEW.CLIENT_NO;
  ELSIF TG_OP = 'DELETE' THEN
    v_old := to_jsonb(OLD);
    v_new := NULL;
    v_diff := ARRAY(SELECT jsonb_object_keys(v_old));
    v_client_no := OLD.CLIENT_NO;
  END IF;

  v_pk := jsonb_build_object('table', TG_TABLE_NAME, 'client_no', v_client_no);

  INSERT INTO WLT_CLIENT_AUDIT_LOG (
    CLIENT_NO, TABLE_NAME, ROW_PK, OPERATION,
    CHANGED_BY, CHANGE_SOURCE, CHANGE_REASON,
    OLD_VALUES, NEW_VALUES, CHANGED_FIELDS,
    REQUEST_ID, IP_ADDRESS, USER_AGENT,
    MAKER_ID, CHECKER_ID, APPROVAL_REF
  ) VALUES (
    v_client_no, TG_TABLE_NAME, v_pk, TG_OP,
    v_actor, v_src, current_setting('audit.reason', TRUE),
    v_old, v_new, v_diff,
    current_setting('audit.request_id', TRUE),
    NULLIF(current_setting('audit.ip', TRUE), '')::INET,
    current_setting('audit.user_agent', TRUE),
    current_setting('audit.maker_id', TRUE),
    current_setting('audit.checker_id', TRUE),
    current_setting('audit.approval_ref', TRUE)
  );

  RETURN COALESCE(NEW, OLD);
END $$;


--
-- Name: fn_create_client(character varying, character varying, character varying, character varying, character varying, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_create_client(p_client_name character varying, p_global_id character varying, p_phone character varying, p_email character varying DEFAULT NULL::character varying, p_client_type character varying DEFAULT 'IND'::character varying, p_kyc_tier character varying DEFAULT '1'::character varying) RETURNS character varying
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_client_no VARCHAR(48);
  v_key       TEXT := current_setting('app.pii_dek', TRUE);  -- same DEK the masked views decrypt with
BEGIN
  IF v_key IS NULL OR v_key = '' THEN
    RAISE EXCEPTION 'PII_DEK_NOT_SET — set ALTER DATABASE ... SET app.pii_dek=...'
      USING ERRCODE = 'P0030';
  END IF;
  v_client_no := 'C' || LPAD(nextval('seq_client')::text, 10, '0');

  INSERT INTO FM_CLIENT (CLIENT_NO, GLOBAL_ID, GLOBAL_ID_TYPE, CLIENT_NAME,
     CLIENT_TYPE, COUNTRY_LOC, COUNTRY_CITIZEN, STATUS)
  VALUES (v_client_no, p_global_id, 'CCCD', p_client_name,
     p_client_type, 'VN', 'VN', 'A');

  -- Centralized KYC (US-1.15): surname/given_name in extra_data; the CCCD number
  -- (global_id) + sex are flat real columns (FM_CLIENT_IDENTIFIERS flattened in).
  INSERT INTO FM_CLIENT_KYC (CLIENT_NO, PHONE_NO_ENC, PHONE_NO_HASH, EMAIL_ENC, KYC_TIER, STATUS,
       EXTRA_DATA, GLOBAL_ID, GLOBAL_ID_TYPE, SEX)
  VALUES (
    v_client_no,
    pgp_sym_encrypt(p_phone, v_key, 'cipher-algo=aes256'),
    digest(p_phone, 'sha256'),
    CASE WHEN p_email IS NULL THEN NULL ELSE pgp_sym_encrypt(p_email, v_key, 'cipher-algo=aes256') END,
    p_kyc_tier, 'A',
    CASE WHEN p_client_type = 'IND'
         THEN jsonb_build_object('surname', split_part(p_client_name,' ',1),
                                 'given_name', split_part(p_client_name,' ',-1),
                                 'resident_status', 'R')
         ELSE '{}'::jsonb END,
    p_global_id, 'CCCD',
    CASE WHEN p_client_type = 'IND' THEN 'M' ELSE NULL END);

  RETURN v_client_no;
END $$;


--
-- Name: fn_freeze_closed_period(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_freeze_closed_period() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public', 'pg_catalog'
    AS $$
DECLARE
  v_through DATE := fn_period_closed_through();
BEGIN
  IF v_through IS NULL THEN
    RETURN COALESCE(NEW, OLD);                       -- nothing sealed yet
  END IF;
  IF TG_OP IN ('UPDATE','DELETE') AND OLD.POST_DATE <= v_through THEN
    RAISE EXCEPTION 'PERIOD_CLOSED: % blocked — row is in a closed period (post_date %, closed through %)',
      TG_OP, OLD.POST_DATE, v_through USING ERRCODE = 'P0092';
  END IF;
  IF TG_OP IN ('INSERT','UPDATE') AND NEW.POST_DATE <= v_through THEN
    RAISE EXCEPTION 'PERIOD_CLOSED: post_date % is in a closed period (closed through %)',
      NEW.POST_DATE, v_through USING ERRCODE = 'P0092';
  END IF;
  RETURN COALESCE(NEW, OLD);
END
$$;


--
-- Name: fn_open_wallet(character varying, character varying, numeric, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_open_wallet(p_client_no character varying, p_acct_type character varying DEFAULT 'CONSUMER'::character varying, p_initial_fund numeric DEFAULT 0, p_ccy character varying DEFAULT 'VND'::character varying) RETURNS TABLE(internal_key bigint, acct_no character varying)
    LANGUAGE plpgsql
    AS $$
DECLARE v_acct_no VARCHAR(20); v_intkey BIGINT;
BEGIN
  v_acct_no := '9701' || LPAD(nextval('seq_acct_no')::text, 10, '0');

  -- Open with zero balance; fund through post_topup so the opening balance has a
  -- matching ledger entry + GL double-entry (DR 101.02.001 / CR wallet liability).
  -- Never set ACTUAL_BAL directly — that injects off-ledger balance.
  INSERT INTO WLT_ACCT (ACCT_NO, CLIENT_NO, ACCT_TYPE, CCY, ACCT_STATUS,
     ACTUAL_BAL, PREV_DAY_ACTUAL_BAL)
  VALUES (v_acct_no, p_client_no, p_acct_type, p_ccy, 'A', 0, 0)
  RETURNING WLT_ACCT.INTERNAL_KEY INTO v_intkey;

  IF p_initial_fund > 0 THEN
    PERFORM post_topup(v_acct_no, p_initial_fund,
                       'SEED-OPEN-' || v_acct_no, '{}'::jsonb, 'TREASURY', 'seed');
  END IF;

  RETURN QUERY SELECT v_intkey, v_acct_no;
END $$;


--
-- Name: fn_period_closed_through(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_period_closed_through() RETURNS date
    LANGUAGE sql STABLE
    AS $$
  SELECT max(biz_date) FROM WLT_PERIOD WHERE status = 'CLOSED';
$$;


--
-- Name: fn_resolve_shard_acct_no(character varying, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_resolve_shard_acct_no(p_group_id character varying, p_reference character varying) RETURNS character varying
    LANGUAGE plpgsql STABLE
    AS $$
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


--
-- Name: fn_set_audit_columns(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_set_audit_columns() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_actor   VARCHAR(64);
  v_channel VARCHAR(20);
  v_now     TIMESTAMPTZ := clock_timestamp();
BEGIN
  v_actor   := COALESCE(NULLIF(current_setting('audit.actor',   TRUE), ''), session_user);
  v_channel := COALESCE(NULLIF(current_setting('audit.channel', TRUE), ''), 'SYSTEM');

  IF TG_OP = 'INSERT' THEN
    NEW.CHANNEL    := COALESCE(NEW.CHANNEL,    v_channel);
    NEW.CREATED_BY := COALESCE(NULLIF(NEW.CREATED_BY, 'SYSTEM'), v_actor);
    NEW.CREATED_AT := COALESCE(NEW.CREATED_AT, v_now);
    NEW.UPDATED_BY := NEW.CREATED_BY;
    NEW.UPDATED_AT := NEW.CREATED_AT;
  ELSIF TG_OP = 'UPDATE' THEN
    NEW.UPDATED_AT := v_now;
    NEW.UPDATED_BY := v_actor;
    NEW.CREATED_AT := OLD.CREATED_AT;
    NEW.CREATED_BY := OLD.CREATED_BY;
    NEW.CHANNEL    := OLD.CHANNEL;
  END IF;
  RETURN NEW;
END $$;


--
-- Name: fn_validate_metadata(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_validate_metadata(p_metadata jsonb) RETURNS void
    LANGUAGE plpgsql IMMUTABLE
    AS $$
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


--
-- Name: get_balance(character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_balance(p_acct_no character varying) RETURNS TABLE(acct_no character varying, ccy character varying, acct_status character varying, actual_bal numeric, available_bal numeric, restrained_amt numeric, masked boolean, message text, last_tran_date timestamp with time zone, as_of timestamp with time zone)
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
  v   WLT_ACCT%ROWTYPE;
  v_aml BOOLEAN;
BEGIN
  SELECT * INTO v FROM WLT_ACCT WHERE WLT_ACCT.ACCT_NO = p_acct_no;
  IF NOT FOUND THEN
    RETURN;  -- empty set → 404 ACCT_NOT_FOUND
  END IF;

  -- BAL-02: active AML_HOLD restraint → mask balances
  SELECT EXISTS (
    SELECT 1 FROM WLT_RESTRAINTS r
     WHERE r.INTERNAL_KEY = v.INTERNAL_KEY
       AND r.STATUS = 'A'
       AND upper(r.RESTRAINT_PURPOSE) = 'AML_HOLD'
  ) INTO v_aml;

  IF v_aml THEN
    RETURN QUERY SELECT
      v.ACCT_NO, v.CCY, v.ACCT_STATUS,
      NULL::NUMERIC, NULL::NUMERIC, NULL::NUMERIC,
      TRUE, 'Contact CSKH'::TEXT,
      v.LAST_TRAN_DATE, now();
  ELSE
    RETURN QUERY SELECT
      v.ACCT_NO, v.CCY, v.ACCT_STATUS,
      v.ACTUAL_BAL,
      GREATEST(v.CALC_BAL, 0),
      v.TOTAL_RESTRAINED_AMT,
      FALSE, NULL::TEXT,
      v.LAST_TRAN_DATE, now();
  END IF;
END $$;


--
-- Name: get_balance_asof(character varying, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_balance_asof(p_acct_no character varying, p_as_of_date date) RETURNS TABLE(acct_no character varying, ccy character varying, actual_bal numeric, tran_date date, source text)
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
  v_intkey BIGINT;
  v_ccy    VARCHAR;
BEGIN
  IF p_as_of_date >= CURRENT_DATE THEN
    RAISE EXCEPTION 'INVALID_DATE: as_of_date must be < today (use realtime balance)';
  END IF;
  IF p_as_of_date < (CURRENT_DATE - INTERVAL '18 months') THEN
    RAISE EXCEPTION 'GONE_ONLINE: as_of_date older than 18 months → query archive';
  END IF;

  SELECT INTERNAL_KEY, CCY INTO v_intkey, v_ccy
    FROM WLT_ACCT WHERE WLT_ACCT.ACCT_NO = p_acct_no;
  IF NOT FOUND THEN
    RETURN;  -- 404
  END IF;

  RETURN QUERY
    SELECT p_acct_no, v_ccy, b.ACTUAL_BAL, b.TRAN_DATE, 'WLT_ACCT_BAL'::TEXT
    FROM WLT_ACCT_BAL b
    WHERE b.INTERNAL_KEY = v_intkey AND b.TRAN_DATE = p_as_of_date
    LIMIT 1;
END $$;


--
-- Name: get_balance_batch(character varying[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_balance_batch(p_acct_nos character varying[]) RETURNS TABLE(acct_no character varying, ccy character varying, actual_bal numeric, available_bal numeric, restrained_amt numeric)
    LANGUAGE plpgsql STABLE
    AS $$
BEGIN
  IF array_length(p_acct_nos, 1) > 100 THEN
    RAISE EXCEPTION 'BATCH_SIZE_EXCEEDED: max 100 acct_nos per call';
  END IF;

  RETURN QUERY
    SELECT a.ACCT_NO, a.CCY, a.ACTUAL_BAL,
           GREATEST(a.CALC_BAL, 0), a.TOTAL_RESTRAINED_AMT
    FROM WLT_ACCT a
    WHERE a.ACCT_NO = ANY (p_acct_nos);
END $$;


--
-- Name: get_balance_ops(character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_balance_ops(p_acct_no character varying) RETURNS TABLE(acct_no character varying, client_no character varying, ccy character varying, acct_status character varying, actual_bal numeric, ledger_bal numeric, calc_bal numeric, available_bal numeric, restrained_amt numeric, restraint_present character varying, cr_blocked character varying, active_restraints jsonb, version integer, previous_day_bal numeric, last_tran_date timestamp with time zone, as_of timestamp with time zone)
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
  v WLT_ACCT%ROWTYPE;
BEGIN
  SELECT * INTO v FROM WLT_ACCT WHERE WLT_ACCT.ACCT_NO = p_acct_no;
  IF NOT FOUND THEN
    RETURN;
  END IF;

  RETURN QUERY SELECT
    v.ACCT_NO, v.CLIENT_NO, v.CCY, v.ACCT_STATUS,
    v.ACTUAL_BAL,
    v.ACTUAL_BAL,                       -- ledger_bal = actual (no separate column)
    v.CALC_BAL,
    GREATEST(v.CALC_BAL, 0),
    v.TOTAL_RESTRAINED_AMT,
    v.RESTRAINT_PRESENT, v.CR_BLOCKED,
    COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'restraint_id', r.SEQ_NO,
               'purpose',      r.RESTRAINT_PURPOSE,
               'type',         r.RESTRAINT_TYPE,
               'pledged_amt',  r.PLEDGED_AMT,
               'end_date',     r.END_DATE)
             ORDER BY r.SEQ_NO)
      FROM WLT_RESTRAINTS r
      WHERE r.INTERNAL_KEY = v.INTERNAL_KEY AND r.STATUS = 'A'
    ), '[]'::jsonb),
    v.VERSION, v.PREV_DAY_ACTUAL_BAL,
    v.LAST_TRAN_DATE, now();
END $$;


--
-- Name: link_client_bank(character varying, character varying, character varying, character varying, character varying, boolean, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.link_client_bank(p_client_no character varying, p_bank_code character varying, p_acct_no character varying, p_bank_name character varying DEFAULT NULL::character varying, p_acct_holder_name character varying DEFAULT NULL::character varying, p_is_default boolean DEFAULT false, p_actor character varying DEFAULT NULL::character varying) RETURNS TABLE(link_id bigint, client_no character varying, is_default smallint, status character varying, created_at timestamp with time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
#variable_conflict use_column
DECLARE
  v_dek TEXT     := current_setting('app.pii_dek', TRUE);
  v_enc BYTEA;
  v_def SMALLINT := CASE WHEN p_is_default THEN 1 ELSE 0 END;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM FM_CLIENT WHERE client_no = p_client_no) THEN
    RAISE EXCEPTION 'CLIENT_NOT_FOUND' USING ERRCODE = 'P0073';
  END IF;
  IF p_bank_code IS NULL OR length(btrim(p_bank_code)) = 0 THEN
    RAISE EXCEPTION 'INVALID_REQUEST: bank_code required' USING ERRCODE = 'P0071';
  END IF;
  IF p_acct_no IS NULL OR length(btrim(p_acct_no)) = 0 THEN
    RAISE EXCEPTION 'INVALID_REQUEST: acct_no required' USING ERRCODE = 'P0071';
  END IF;
  IF v_dek IS NULL OR v_dek = '' THEN
    RAISE EXCEPTION 'PII_DEK_NOT_SET — set ALTER DATABASE ... SET app.pii_dek=...'
      USING ERRCODE = 'P0030';
  END IF;

  v_enc := pgp_sym_encrypt(p_acct_no, v_dek, 'cipher-algo=aes256');

  IF v_def = 1 THEN
    UPDATE FM_CLIENT_BANKS SET is_default = 0
     WHERE client_no = p_client_no AND is_default = 1;
  END IF;

  RETURN QUERY
  INSERT INTO FM_CLIENT_BANKS(client_no, bank_code, bank_name, acct_no_enc,
       acct_holder_name, is_default, status)
  VALUES (p_client_no, p_bank_code, p_bank_name, v_enc,
       p_acct_holder_name, v_def, 'A')
  RETURNING link_id, client_no, is_default, status, created_at;
END;
$$;


--
-- Name: mark_withdraw_acked(character varying, character varying, character varying, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.mark_withdraw_acked(p_ext_payout_ref character varying, p_treasury_batch_id character varying, p_channel character varying DEFAULT 'TREASURY'::character varying, p_actor character varying DEFAULT NULL::character varying) RETURNS TABLE(acct_no character varying, status character varying, event_uuid uuid)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_catalog'
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
  VALUES ('WITHDRAW', v_track.TRAN_INTERNAL_ID::text,
          'wallet.withdraw.acked.v1', v_track.ACCT_NO, 'wallet.withdrawals',
          jsonb_build_object('ext_payout_ref', p_ext_payout_ref,
                             'treasury_batch_id', p_treasury_batch_id,
                             'tran_internal_id', v_track.TRAN_INTERNAL_ID,
                             'acked_at', clock_timestamp()))
  RETURNING EVENT_UUID INTO v_event_uuid;

  RETURN QUERY SELECT v_track.ACCT_NO, v_track.STATUS, v_event_uuid;
END $$;


--
-- Name: mark_withdraw_completed(character varying, character varying, character varying, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.mark_withdraw_completed(p_ext_payout_ref character varying, p_napas_ref character varying, p_channel character varying DEFAULT 'TREASURY'::character varying, p_actor character varying DEFAULT NULL::character varying) RETURNS TABLE(acct_no character varying, status character varying, event_uuid uuid)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_catalog'
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
  VALUES ('WITHDRAW', v_track.TRAN_INTERNAL_ID::text,
          'wallet.withdraw.completed.v1', v_track.ACCT_NO, 'wallet.withdrawals',
          jsonb_build_object('ext_payout_ref', p_ext_payout_ref,
                             'napas_ref', p_napas_ref,
                             'tran_internal_id', v_track.TRAN_INTERNAL_ID,
                             'settled_at', clock_timestamp()))
  RETURNING EVENT_UUID INTO v_event_uuid;

  RETURN QUERY SELECT v_track.ACCT_NO, v_track.STATUS, v_event_uuid;
END $$;


--
-- Name: mark_withdraw_disbursing(character varying, character varying, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.mark_withdraw_disbursing(p_ext_payout_ref character varying, p_channel character varying DEFAULT 'TREASURY'::character varying, p_actor character varying DEFAULT NULL::character varying) RETURNS TABLE(acct_no character varying, status character varying, event_uuid uuid)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_catalog'
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
  VALUES ('WITHDRAW', v_track.TRAN_INTERNAL_ID::text,
          'wallet.withdraw.disbursing.v1', v_track.ACCT_NO, 'wallet.withdrawals',
          jsonb_build_object('ext_payout_ref', p_ext_payout_ref,
                             'tran_internal_id', v_track.TRAN_INTERNAL_ID))
  RETURNING EVENT_UUID INTO v_event_uuid;

  RETURN QUERY SELECT v_track.ACCT_NO, v_track.STATUS, v_event_uuid;
END $$;


--
-- Name: open_account(character varying, character varying, character varying, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.open_account(p_client_no character varying, p_acct_type character varying DEFAULT 'CONSUMER'::character varying, p_ccy character varying DEFAULT 'VND'::character varying, p_actor character varying DEFAULT NULL::character varying) RETURNS TABLE(acct_no character varying, internal_key bigint, acct_status character varying)
    LANGUAGE plpgsql
    AS $$
#variable_conflict use_column
DECLARE
  v_ccy   VARCHAR(4)  := COALESCE(p_ccy, 'VND');
  v_limit INT;
  v_cnt   INT;
  v_no    VARCHAR(20);
  v_key   BIGINT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM WLT_ACCT_TYPE WHERE acct_type = p_acct_type) THEN
    RAISE EXCEPTION 'INVALID_ACCT_TYPE' USING ERRCODE = 'P0080';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM FM_CLIENT WHERE client_no = p_client_no) THEN
    RAISE EXCEPTION 'CLIENT_NOT_FOUND' USING ERRCODE = 'P0073';
  END IF;

  -- wallet-count limit per client (§4.3); closed wallets excluded
  v_limit := CASE p_acct_type WHEN 'CONSUMER' THEN 3 WHEN 'MERCHANT' THEN 10 ELSE 1 END;
  SELECT count(*) INTO v_cnt
    FROM WLT_ACCT
   WHERE client_no = p_client_no
     AND acct_type = p_acct_type
     AND acct_status <> 'C'
     AND (p_acct_type <> 'CONSUMER' OR ccy = v_ccy);   -- CONSUMER limit is per-CCY
  IF v_cnt >= v_limit THEN
    RAISE EXCEPTION 'MAX_WALLET_PER_CLIENT_EXCEEDED' USING ERRCODE = 'P0081';
  END IF;

  v_no := '9701' || LPAD(nextval('seq_acct_no')::text, 10, '0');

  INSERT INTO WLT_ACCT(acct_no, client_no, acct_type, ccy, acct_status, actual_bal, acct_role)
  VALUES (v_no, p_client_no, p_acct_type, v_ccy, 'A', 0, 'STANDALONE')
  RETURNING internal_key INTO v_key;

  RETURN QUERY SELECT v_no, v_key, 'A'::varchar;
END;
$$;


--
-- Name: post_merchant_withdraw(character varying, numeric, character varying, character varying, boolean, character varying, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.post_merchant_withdraw(p_group_id character varying, p_amount numeric, p_reference character varying, p_ext_payout_ref character varying DEFAULT NULL::character varying, p_auto_sweep boolean DEFAULT true, p_channel character varying DEFAULT 'MOBILE'::character varying, p_actor character varying DEFAULT NULL::character varying) RETURNS TABLE(tran_internal_id bigint, status character varying, amount numeric, fee_gross numeric, vat_amount numeric, total_deducted numeric, settlement_balance_after numeric, event_uuid uuid)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_catalog'
    AS $$
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
    RETURN QUERY SELECT (v_existing.OBJECT_RESPONE_DATA::jsonb->>'tran_internal_id')::bigint,
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

  UPDATE WLT_ACCT SET ACTUAL_BAL = ACTUAL_BAL - v_total, VERSION = VERSION + 1, LAST_TRAN_DATE = clock_timestamp()
   WHERE INTERNAL_KEY = v_settle.INTERNAL_KEY AND VERSION = v_settle.VERSION
     AND ACTUAL_BAL - TOTAL_RESTRAINED_AMT >= v_total
  RETURNING ACTUAL_BAL INTO v_settle.ACTUAL_BAL;
  IF NOT FOUND THEN RAISE EXCEPTION 'VERSION_CONFLICT' USING ERRCODE='40001'; END IF;

  -- TRAN_HIST: MERCHWD (principal) + FEEMW (fee), fee leg → origin via TFR_SEQ_NO
  INSERT INTO WLT_TRAN_HIST (INTERNAL_KEY, TRAN_TYPE, POST_DATE, VALUE_DATE,
     TRAN_AMT, CR_DR_MAINT_IND, PREVIOUS_BAL_AMT, ACTUAL_BAL_AMT,
     TRAN_INTERNAL_ID, REFERENCE, CCY, SOURCE_TYPE, SOURCE_MODULE, TRAN_DESC, GROUP_ID)
  VALUES (v_settle.INTERNAL_KEY, 'MERCHWD', CURRENT_DATE, CURRENT_DATE,
     p_amount, 'DR', v_settle.ACTUAL_BAL + v_total, v_settle.ACTUAL_BAL + v_fee,
     v_tfr, p_reference, v_settle.CCY, p_channel, 'WLT', 'Merchant withdraw', p_group_id)
  RETURNING SEQ_NO INTO v_seq_base;

  IF v_fee > 0 THEN
    INSERT INTO WLT_TRAN_HIST (INTERNAL_KEY, TRAN_TYPE, POST_DATE, VALUE_DATE,
       TRAN_AMT, CR_DR_MAINT_IND, PREVIOUS_BAL_AMT, ACTUAL_BAL_AMT,
       TRAN_INTERNAL_ID, TFR_SEQ_NO, REFERENCE, CCY, SOURCE_MODULE, TRAN_DESC, GROUP_ID)
    VALUES (v_settle.INTERNAL_KEY, 'FEEMW', CURRENT_DATE, CURRENT_DATE,
       v_fee, 'DR', v_settle.ACTUAL_BAL + v_fee, v_settle.ACTUAL_BAL,
       v_tfr, v_seq_base, p_reference, v_settle.CCY, 'WLT', 'Fee + VAT for merchant withdraw', p_group_id);
  END IF;

  -- GL: DR settlement liability / CR nostro + fee legs. Resolve the liability GL
  -- into a variable first (the FK is checked at INSERT, so it must be a real code).
  SELECT GL_CODE_LIAB INTO v_liab_gl FROM WLT_ACCT_TYPE WHERE ACCT_TYPE = v_settle.ACCT_TYPE;
  INSERT INTO WLT_GL_BATCH (TRAN_KEY, SEQ_NO, GL_CODE, CLIENT_NO, ACCT_INTERNAL_KEY, AMOUNT, TRAN_NATURE, CCY, REFERENCE, POST_DATE, VALUE_DATE)
  VALUES
    (v_tfr, 1, v_liab_gl,            v_settle.CLIENT_NO, v_settle.INTERNAL_KEY, p_amount, 'DR', v_settle.CCY, p_reference, CURRENT_DATE, CURRENT_DATE),
    (v_tfr, 2, v_def.CONTRA_GL_CODE, v_settle.CLIENT_NO, v_settle.INTERNAL_KEY, p_amount, 'CR', v_settle.CCY, p_reference, CURRENT_DATE, CURRENT_DATE);
  IF v_fee > 0 THEN
    INSERT INTO WLT_GL_BATCH (TRAN_KEY, SEQ_NO, GL_CODE, CLIENT_NO, ACCT_INTERNAL_KEY, AMOUNT, TRAN_NATURE, CCY, REFERENCE, POST_DATE, VALUE_DATE)
    VALUES
      (v_tfr, 3, v_liab_gl,         v_settle.CLIENT_NO, v_settle.INTERNAL_KEY, v_fee, 'DR', v_settle.CCY, p_reference, CURRENT_DATE, CURRENT_DATE),
      (v_tfr, 4, v_def.FEE_GL_CODE, v_settle.CLIENT_NO, v_settle.INTERNAL_KEY, v_net, 'CR', v_settle.CCY, p_reference, CURRENT_DATE, CURRENT_DATE),
      (v_tfr, 5, v_def.VAT_GL_CODE, v_settle.CLIENT_NO, v_settle.INTERNAL_KEY, v_vat, 'CR', v_settle.CCY, p_reference, CURRENT_DATE, CURRENT_DATE);
  END IF;

  -- Outbox: Treasury consumes for batch disbursement (MWD-09)
  INSERT INTO WLT_OUTBOX (AGGREGATE_TYPE, AGGREGATE_ID, EVENT_TYPE, PARTITION_KEY, TOPIC, PAYLOAD, HEADERS)
  VALUES ('MERCHANT_WITHDRAW', v_tfr::text, 'wallet.merchant_withdraw.posted.v1', p_group_id, 'wallet.withdrawals',
          jsonb_build_object('tran_internal_id', v_tfr, 'group_id', p_group_id, 'settlement_acct', v_settle.ACCT_NO,
                             'amount', p_amount, 'fee_gross', v_fee, 'vat_amount', v_vat,
                             'ext_payout_ref', p_ext_payout_ref, 'ccy', v_settle.CCY),
          jsonb_build_object('traceparent', current_setting('app.trace_id', TRUE)))
  RETURNING EVENT_UUID INTO v_event;

  -- Phase 5: close idempotency
  UPDATE WLT_API_MESSAGE SET PROCESS_STATUS='SUCCESS', HTTP_STATUS=200,
     OBJECT_RESPONE_DATA = jsonb_build_object('tran_internal_id', v_tfr, 'amount', p_amount,
       'fee_gross', v_fee, 'vat_amount', v_vat, 'total_deducted', v_total,
       'settlement_balance_after', v_settle.ACTUAL_BAL, 'event_uuid', v_event)::text,
     PROCESSED_AT = clock_timestamp()
   WHERE OBJECT_REF_ID = p_reference;

  RETURN QUERY SELECT v_tfr, 'SUCCESS'::varchar, p_amount, v_fee, v_vat, v_total, v_settle.ACTUAL_BAL, v_event;
END $$;


--
-- Name: post_merchant_withdraw_reversal(character varying, character varying, character varying, character varying, character varying, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.post_merchant_withdraw_reversal(p_orig_reference character varying, p_fail_code character varying, p_fail_reason character varying, p_initiator character varying DEFAULT 'OPS_MANUAL'::character varying, p_channel character varying DEFAULT 'SYS'::character varying, p_actor character varying DEFAULT NULL::character varying) RETURNS TABLE(reversal_tfr_key bigint, was_already_reversed boolean, settlement_balance_after numeric, event_uuid uuid)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_catalog'
    AS $$
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
  v_orig_tfr := (v_orig.OBJECT_RESPONE_DATA::jsonb->>'tran_internal_id')::bigint;
  v_amt      := (v_orig.OBJECT_RESPONE_DATA::jsonb->>'amount')::numeric;
  v_fee      := (v_orig.OBJECT_RESPONE_DATA::jsonb->>'fee_gross')::numeric;
  v_vat      := (v_orig.OBJECT_RESPONE_DATA::jsonb->>'vat_amount')::numeric;
  v_net      := v_fee - v_vat;

  SELECT * INTO v_settle FROM WLT_ACCT WHERE GROUP_ID = v_grp AND ACCT_ROLE = 'SETTLEMENT' FOR UPDATE;
  SELECT * INTO v_def    FROM WLT_TRAN_DEF WHERE TRAN_TYPE = 'MERCHWD';
  SELECT GL_CODE_LIAB INTO v_liab_gl FROM WLT_ACCT_TYPE WHERE ACCT_TYPE = v_settle.ACCT_TYPE;
  SELECT SEQ_NO INTO v_orig_seq FROM WLT_TRAN_HIST WHERE TRAN_INTERNAL_ID = v_orig_tfr AND TRAN_TYPE = 'MERCHWD' LIMIT 1;

  INSERT INTO WLT_API_MESSAGE (OBJECT_REF_ID, OBJECT_CHANNEL, OBJECT_SUBJECT, OBJECT_REQUEST_DATA, PROCESS_STATUS)
  VALUES (v_rref, p_channel, 'MERCHANT_WITHDRAW_REVERSAL',
          jsonb_build_object('orig_reference', p_orig_reference, 'fail_code', p_fail_code, 'initiator', p_initiator)::text, 'PENDING')
  ON CONFLICT (OBJECT_REF_ID) DO NOTHING;

  v_rev_tfr := nextval('seq_tfr');

  -- Credit back settlement: principal + fee
  UPDATE WLT_ACCT SET ACTUAL_BAL = ACTUAL_BAL + v_amt + v_fee, VERSION = VERSION + 1, LAST_TRAN_DATE = clock_timestamp()
   WHERE INTERNAL_KEY = v_settle.INTERNAL_KEY RETURNING ACTUAL_BAL INTO v_settle.ACTUAL_BAL;

  -- RVMWD (credit-back principal)
  INSERT INTO WLT_TRAN_HIST (INTERNAL_KEY, TRAN_TYPE, POST_DATE, VALUE_DATE,
     TRAN_AMT, CR_DR_MAINT_IND, PREVIOUS_BAL_AMT, ACTUAL_BAL_AMT,
     TRAN_INTERNAL_ID, REFERENCE, ORIG_SEQ_NO, CCY, SOURCE_TYPE, SOURCE_MODULE, TRAN_DESC, GROUP_ID)
  VALUES (v_settle.INTERNAL_KEY, 'RVMWD', CURRENT_DATE, CURRENT_DATE,
     v_amt, 'CR', v_settle.ACTUAL_BAL - v_amt - v_fee, v_settle.ACTUAL_BAL - v_fee,
     v_rev_tfr, v_rref, v_orig_seq, v_settle.CCY, p_channel, 'WLT',
     'Reverse merchant withdraw: '||COALESCE(p_fail_code,'?'), v_grp)
  RETURNING SEQ_NO INTO v_seq_base;

  IF v_fee > 0 THEN
    INSERT INTO WLT_TRAN_HIST (INTERNAL_KEY, TRAN_TYPE, POST_DATE, VALUE_DATE,
       TRAN_AMT, CR_DR_MAINT_IND, PREVIOUS_BAL_AMT, ACTUAL_BAL_AMT,
       TRAN_INTERNAL_ID, TFR_SEQ_NO, REFERENCE, ORIG_SEQ_NO, CCY, SOURCE_MODULE, TRAN_DESC, GROUP_ID)
    VALUES (v_settle.INTERNAL_KEY, 'RVFEE', CURRENT_DATE, CURRENT_DATE,
       v_fee, 'CR', v_settle.ACTUAL_BAL - v_fee, v_settle.ACTUAL_BAL,
       v_rev_tfr, v_seq_base, v_rref, v_orig_seq, v_settle.CCY, 'WLT',
       'Refund fee + VAT (merchant withdraw)', v_grp);
  END IF;

  -- GL flip: DR nostro / CR settlement (principal); fee: DR 401.02 + DR 203.01 / CR settlement
  INSERT INTO WLT_GL_BATCH (TRAN_KEY, SEQ_NO, GL_CODE, CLIENT_NO, ACCT_INTERNAL_KEY, AMOUNT, TRAN_NATURE, CCY, REFERENCE, POST_DATE, VALUE_DATE)
  VALUES
    (v_rev_tfr, 1, v_def.CONTRA_GL_CODE, v_settle.CLIENT_NO, v_settle.INTERNAL_KEY, v_amt, 'DR', v_settle.CCY, v_rref, CURRENT_DATE, CURRENT_DATE),
    (v_rev_tfr, 2, v_liab_gl,            v_settle.CLIENT_NO, v_settle.INTERNAL_KEY, v_amt, 'CR', v_settle.CCY, v_rref, CURRENT_DATE, CURRENT_DATE);
  IF v_fee > 0 THEN
    INSERT INTO WLT_GL_BATCH (TRAN_KEY, SEQ_NO, GL_CODE, CLIENT_NO, ACCT_INTERNAL_KEY, AMOUNT, TRAN_NATURE, CCY, REFERENCE, POST_DATE, VALUE_DATE)
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


--
-- Name: post_sweep_shard(character varying, character varying, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.post_sweep_shard(p_shard_acct_no character varying, p_trigger character varying DEFAULT 'PERIODIC'::character varying, p_triggered_by character varying DEFAULT 'SWEEP_WORKER'::character varying) RETURNS TABLE(swept_amount numeric, settlement_bal_after numeric, tran_internal_id bigint)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_catalog'
    AS $$
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
  INSERT INTO WLT_TRAN_HIST (INTERNAL_KEY, TRAN_TYPE, POST_DATE, VALUE_DATE,
     TRAN_AMT, CR_DR_MAINT_IND, PREVIOUS_BAL_AMT, ACTUAL_BAL_AMT,
     TRAN_INTERNAL_ID, REFERENCE, CCY, SOURCE_TYPE, SOURCE_MODULE, TRAN_DESC, GROUP_ID, SHARD_INDEX)
  VALUES (v_shard.INTERNAL_KEY, 'SWEEPO', CURRENT_DATE, CURRENT_DATE,
     v_swept, 'DR', v_shard_before, v_shard.ACTUAL_BAL,
     v_tfr, 'SWEEP-'||v_tfr, v_shard.CCY, 'SWEEP', 'WLT', 'Sweep out to settlement',
     v_shard.GROUP_ID, v_shard.SHARD_INDEX)
  RETURNING SEQ_NO INTO v_seq_out;

  INSERT INTO WLT_TRAN_HIST (INTERNAL_KEY, TRAN_TYPE, POST_DATE, VALUE_DATE,
     TRAN_AMT, CR_DR_MAINT_IND, PREVIOUS_BAL_AMT, ACTUAL_BAL_AMT,
     TRAN_INTERNAL_ID, TFR_SEQ_NO, REFERENCE, CCY, SOURCE_TYPE, SOURCE_MODULE, TRAN_DESC, GROUP_ID)
  VALUES (v_settle.INTERNAL_KEY, 'SWEEPI', CURRENT_DATE, CURRENT_DATE,
     v_swept, 'CR', v_settle.ACTUAL_BAL - v_swept, v_settle.ACTUAL_BAL,
     v_tfr, v_seq_out, 'SWEEP-'||v_tfr, v_settle.CCY, 'SWEEP', 'WLT', 'Sweep in from shard',
     v_settle.GROUP_ID);

  -- GL: both MERCHANT wallets → 201.02.001; DR shard / CR settlement (net 0)
  INSERT INTO WLT_GL_BATCH (TRAN_KEY, SEQ_NO, GL_CODE, CLIENT_NO, ACCT_INTERNAL_KEY,
                         AMOUNT, TRAN_NATURE, CCY, REFERENCE, POST_DATE, VALUE_DATE)
  VALUES
    (v_tfr, 1, '201.02.001', v_shard.CLIENT_NO,  v_shard.INTERNAL_KEY,  v_swept, 'DR', v_shard.CCY,  'SWEEP-'||v_tfr, CURRENT_DATE, CURRENT_DATE),
    (v_tfr, 2, '201.02.001', v_settle.CLIENT_NO, v_settle.INTERNAL_KEY, v_swept, 'CR', v_settle.CCY, 'SWEEP-'||v_tfr, CURRENT_DATE, CURRENT_DATE);

  INSERT INTO WLT_SWEEP_LOG (GROUP_ID, SHARD_ACCT_NO, SETTLEMENT_ACCT_NO, SWEPT_AMOUNT,
                             SHARD_BAL_BEFORE, SHARD_BAL_AFTER, SETTLEMENT_BAL_AFTER,
                             TRAN_INTERNAL_ID, TRIGGER_TYPE, TRIGGERED_BY, STATUS)
  VALUES (v_shard.GROUP_ID, p_shard_acct_no, v_settle.ACCT_NO, v_swept,
          v_shard_before, v_shard.ACTUAL_BAL, v_settle.ACTUAL_BAL, v_tfr, p_trigger, p_triggered_by, 'SUCCESS');

  RETURN QUERY SELECT v_swept, v_settle.ACTUAL_BAL, v_tfr;
END $$;


--
-- Name: post_topup(character varying, numeric, character varying, jsonb, character varying, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.post_topup(p_acct_no character varying, p_amount numeric, p_reference character varying, p_metadata jsonb DEFAULT '{}'::jsonb, p_channel character varying DEFAULT 'TREASURY'::character varying, p_actor character varying DEFAULT NULL::character varying) RETURNS TABLE(tran_internal_id bigint, status character varying, new_balance numeric, event_uuid uuid)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_catalog'
    AS $$
#variable_conflict use_column
DECLARE
  v_actor       VARCHAR(64) := COALESCE(p_actor, session_user);
  v_acct        WLT_ACCT%ROWTYPE;
  v_def         WLT_TRAN_DEF%ROWTYPE;
  v_acct_type   WLT_ACCT_TYPE%ROWTYPE;
  v_tfr_key     BIGINT;
  v_event_uuid  UUID;
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
    SELECT (v_existing.OBJECT_RESPONE_DATA::jsonb->>'tran_internal_id')::bigint,
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
    INTERNAL_KEY, TRAN_TYPE, POST_DATE, VALUE_DATE,
    TRAN_AMT, CR_DR_MAINT_IND, PREVIOUS_BAL_AMT, ACTUAL_BAL_AMT,
    TRAN_INTERNAL_ID, REFERENCE, CCY, SOURCE_TYPE, SOURCE_MODULE,
    TRAN_DESC, NARRATIVE, GROUP_ID, SHARD_INDEX, METADATA
  ) VALUES (
    v_acct.INTERNAL_KEY, 'TOPUP', CURRENT_DATE, CURRENT_DATE,
    p_amount, 'CR', v_acct.ACTUAL_BAL - p_amount, v_acct.ACTUAL_BAL,
    v_tfr_key, p_reference, v_acct.CCY, p_channel, 'WLT',
    'Topup from Treasury', left(p_metadata->>'narrative',250), v_acct.GROUP_ID, v_acct.SHARD_INDEX, p_metadata
  );

  -- BATCH (2 GL legs: DR nostro / CR wallet liability)
  INSERT INTO WLT_GL_BATCH (TRAN_KEY, SEQ_NO, GL_CODE, CLIENT_NO, ACCT_INTERNAL_KEY,
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
          jsonb_build_object('tran_internal_id', v_tfr_key, 'acct_no', p_acct_no,
                             'client_no', v_acct.CLIENT_NO, 'amount', p_amount,
                             'ccy', v_acct.CCY, 'value_date', CURRENT_DATE),
          jsonb_build_object('traceparent', current_setting('app.trace_id', TRUE)))
  RETURNING EVENT_UUID INTO v_event_uuid;

  -- ─── Phase 5: close idempotency ─────────────────────────────────────
  UPDATE WLT_API_MESSAGE
     SET PROCESS_STATUS      = 'SUCCESS',
         HTTP_STATUS         = 200,
         OBJECT_RESPONE_DATA = jsonb_build_object(
           'tran_internal_id', v_tfr_key,
           'new_balance',      v_acct.ACTUAL_BAL,
           'event_uuid',       v_event_uuid)::text,
         PROCESSED_AT        = clock_timestamp()
   WHERE OBJECT_REF_ID = p_reference;

  RETURN QUERY SELECT v_tfr_key, 'SUCCESS'::varchar, v_acct.ACTUAL_BAL, v_event_uuid;
END $$;


--
-- Name: post_topup_reversal(character varying, character varying, character varying, character varying, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.post_topup_reversal(p_orig_reference character varying, p_reason character varying, p_initiator character varying DEFAULT 'OPS_MANUAL'::character varying, p_channel character varying DEFAULT 'SYS'::character varying, p_actor character varying DEFAULT NULL::character varying) RETURNS TABLE(reversal_tfr_key bigint, was_already_reversed boolean, new_balance numeric, event_uuid uuid)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_catalog'
    AS $$
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
  v_orig_tfr := (v_orig.OBJECT_RESPONE_DATA::jsonb->>'tran_internal_id')::bigint;

  SELECT * INTO v_acct FROM WLT_ACCT WHERE ACCT_NO = v_acct_no FOR UPDATE;
  SELECT * INTO v_def  FROM WLT_TRAN_DEF WHERE TRAN_TYPE = 'RVTPUP';
  SELECT GL_CODE_LIAB INTO v_liab_gl FROM WLT_ACCT_TYPE WHERE ACCT_TYPE = v_acct.ACCT_TYPE;
  SELECT SEQ_NO INTO v_orig_seq FROM WLT_TRAN_HIST WHERE TRAN_INTERNAL_ID = v_orig_tfr AND TRAN_TYPE = 'TOPUP' LIMIT 1;

  INSERT INTO WLT_API_MESSAGE (OBJECT_REF_ID, OBJECT_CHANNEL, OBJECT_SUBJECT, OBJECT_REQUEST_DATA, PROCESS_STATUS)
  VALUES (v_rref, p_channel, 'TOPUP_REVERSAL',
          jsonb_build_object('orig_reference', p_orig_reference, 'reason', p_reason, 'initiator', p_initiator)::text, 'PENDING')
  ON CONFLICT (OBJECT_REF_ID) DO NOTHING;

  v_rev_tfr := nextval('seq_tfr');

  -- A topup reversal is a DEBIT (removes erroneously-credited funds), so it is
  -- allowed on a temporarily-blocked ('B') wallet; only a CLOSED wallet is
  -- rejected — you cannot post to a closed account. Restraint is already
  -- honoured by the inline fund guard (CALC_BAL excludes restrained amounts).
  IF v_acct.ACCT_STATUS = 'C' THEN
    RAISE EXCEPTION 'ACCT_NOT_ACTIVE: wallet % is closed', v_acct_no USING ERRCODE = 'P0022';
  END IF;

  -- Claw back the credited amount (inline fund guard)
  UPDATE WLT_ACCT SET ACTUAL_BAL = ACTUAL_BAL - v_amt, VERSION = VERSION + 1, LAST_TRAN_DATE = clock_timestamp()
   WHERE INTERNAL_KEY = v_acct.INTERNAL_KEY
     AND ACTUAL_BAL - TOTAL_RESTRAINED_AMT >= v_amt
  RETURNING ACTUAL_BAL INTO v_acct.ACTUAL_BAL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'INSUFFICIENT_FUNDS: wallet % cannot cover topup claw-back of %', v_acct_no, v_amt USING ERRCODE = 'P0026';
  END IF;

  -- RVTPUP leg (DR wallet)
  INSERT INTO WLT_TRAN_HIST (INTERNAL_KEY, TRAN_TYPE, POST_DATE, VALUE_DATE,
     TRAN_AMT, CR_DR_MAINT_IND, PREVIOUS_BAL_AMT, ACTUAL_BAL_AMT,
     TRAN_INTERNAL_ID, REFERENCE, ORIG_SEQ_NO, CCY, SOURCE_TYPE, SOURCE_MODULE, TRAN_DESC, GROUP_ID)
  VALUES (v_acct.INTERNAL_KEY, 'RVTPUP', CURRENT_DATE, CURRENT_DATE,
     v_amt, 'DR', v_acct.ACTUAL_BAL + v_amt, v_acct.ACTUAL_BAL,
     v_rev_tfr, v_rref, v_orig_seq, v_acct.CCY, p_channel, 'WLT',
     'Reverse topup: '||COALESCE(p_reason,'?'), v_acct.GROUP_ID);

  -- GL flip: DR wallet liability / CR nostro
  INSERT INTO WLT_GL_BATCH (TRAN_KEY, SEQ_NO, GL_CODE, CLIENT_NO, ACCT_INTERNAL_KEY, AMOUNT, TRAN_NATURE, CCY, REFERENCE, POST_DATE, VALUE_DATE)
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


--
-- Name: post_transfer(character varying, character varying, numeric, character varying, character varying, jsonb, character varying, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.post_transfer(p_from_acct_no character varying, p_to_acct_no character varying, p_amount numeric, p_reference character varying, p_tran_type character varying DEFAULT 'TRFOUT'::character varying, p_metadata jsonb DEFAULT '{}'::jsonb, p_channel character varying DEFAULT 'MOBILE'::character varying, p_actor character varying DEFAULT NULL::character varying) RETURNS TABLE(tran_internal_id bigint, status character varying, new_balance_from numeric, new_balance_to numeric, fee_gross numeric, vat_amount numeric, event_uuid uuid)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_catalog'
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
  v_kyc_a       FM_CLIENT_KYC%ROWTYPE;
  v_fee_gross   NUMERIC(18,2) := 0;
  v_vat_amt     NUMERIC(18,2) := 0;
  v_fee_net     NUMERIC(18,2) := 0;
  v_total_debit NUMERIC(18,2);
  v_tfr_key     BIGINT;
  v_out_seq     BIGINT;   -- SEQ_NO of the TRFOUT (origin) leg; fee leg refers to it
  v_cur_bal     NUMERIC(18,2);   -- re-read on CAS miss to classify the failure
  v_cur_restr   NUMERIC(18,2);
  v_event_uuid  UUID;
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
    SELECT (v_existing.OBJECT_RESPONE_DATA::jsonb->>'tran_internal_id')::bigint,
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
  SELECT * INTO v_kyc_a       FROM FM_CLIENT_KYC WHERE CLIENT_NO = v_acct_a.CLIENT_NO;
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
    INTERNAL_KEY, TRAN_TYPE, POST_DATE, VALUE_DATE,
    TRAN_AMT, CR_DR_MAINT_IND, PREVIOUS_BAL_AMT, ACTUAL_BAL_AMT,
    TRAN_INTERNAL_ID, REFERENCE, CCY, SOURCE_TYPE, SOURCE_MODULE,
    TRAN_DESC, NARRATIVE, GROUP_ID, SHARD_INDEX, METADATA
  ) VALUES
    (v_acct_a.INTERNAL_KEY, p_tran_type, CURRENT_DATE, CURRENT_DATE,
     p_amount, 'DR', v_acct_a.ACTUAL_BAL + v_total_debit, v_acct_a.ACTUAL_BAL + v_fee_gross,
     v_tfr_key, p_reference, v_acct_a.CCY, p_channel, 'WLT',
     'Transfer out', left(p_metadata->>'narrative',250), v_acct_a.GROUP_ID, v_acct_a.SHARD_INDEX, p_metadata)
  RETURNING SEQ_NO INTO v_out_seq;

  INSERT INTO WLT_TRAN_HIST (
    INTERNAL_KEY, TRAN_TYPE, POST_DATE, VALUE_DATE,
    TRAN_AMT, CR_DR_MAINT_IND, PREVIOUS_BAL_AMT, ACTUAL_BAL_AMT,
    TRAN_INTERNAL_ID, TFR_SEQ_NO, REFERENCE, CCY, SOURCE_TYPE, SOURCE_MODULE,
    TRAN_DESC, NARRATIVE, GROUP_ID, SHARD_INDEX, METADATA
  ) VALUES
    (v_acct_b.INTERNAL_KEY, 'TRFIN',  CURRENT_DATE, CURRENT_DATE,
     p_amount, 'CR', v_acct_b.ACTUAL_BAL - p_amount, v_acct_b.ACTUAL_BAL,
     v_tfr_key, v_out_seq, p_reference, v_acct_b.CCY, p_channel, 'WLT',
     'Transfer in',  left(p_metadata->>'narrative',250), v_acct_b.GROUP_ID, v_acct_b.SHARD_INDEX, p_metadata);

  IF v_fee_gross > 0 THEN
    INSERT INTO WLT_TRAN_HIST (
      INTERNAL_KEY, TRAN_TYPE, POST_DATE, VALUE_DATE,
      TRAN_AMT, CR_DR_MAINT_IND, PREVIOUS_BAL_AMT, ACTUAL_BAL_AMT,
      TRAN_INTERNAL_ID, TFR_SEQ_NO, REFERENCE, CCY, SOURCE_MODULE,
      TRAN_DESC, NARRATIVE, GROUP_ID, SHARD_INDEX, METADATA
    ) VALUES
      (v_acct_a.INTERNAL_KEY, v_def.FEE_TRAN_TYPE, CURRENT_DATE, CURRENT_DATE,
       v_fee_gross, 'DR', v_acct_a.ACTUAL_BAL + v_fee_gross, v_acct_a.ACTUAL_BAL,
       v_tfr_key, v_out_seq, p_reference, v_acct_a.CCY, 'WLT',
       'Fee + VAT for transfer', left(p_metadata->>'narrative',250), v_acct_a.GROUP_ID, v_acct_a.SHARD_INDEX, p_metadata);
  END IF;

  -- BATCH (5 GL legs: 2 transfer + 3 fee/VAT if fee > 0)
  INSERT INTO WLT_GL_BATCH (TRAN_KEY, SEQ_NO, GL_CODE, CLIENT_NO, ACCT_INTERNAL_KEY,
                         AMOUNT, TRAN_NATURE, CCY, REFERENCE, POST_DATE, VALUE_DATE)
  VALUES
    (v_tfr_key, 1, v_acct_a_type.GL_CODE_LIAB, v_acct_a.CLIENT_NO, v_acct_a.INTERNAL_KEY,
       p_amount, 'DR', v_acct_a.CCY, p_reference, CURRENT_DATE, CURRENT_DATE),
    (v_tfr_key, 2, v_acct_b_type.GL_CODE_LIAB, v_acct_b.CLIENT_NO, v_acct_b.INTERNAL_KEY,
       p_amount, 'CR', v_acct_b.CCY, p_reference, CURRENT_DATE, CURRENT_DATE);
  IF v_fee_gross > 0 THEN
    INSERT INTO WLT_GL_BATCH (TRAN_KEY, SEQ_NO, GL_CODE, CLIENT_NO, ACCT_INTERNAL_KEY,
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
          jsonb_build_object('tran_internal_id', v_tfr_key,
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
           'tran_internal_id', v_tfr_key,
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


--
-- Name: post_transfer_reversal(character varying, character varying, character varying, character varying, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.post_transfer_reversal(p_orig_reference character varying, p_reason character varying, p_initiator character varying DEFAULT 'OPS_MANUAL'::character varying, p_channel character varying DEFAULT 'SYS'::character varying, p_actor character varying DEFAULT NULL::character varying) RETURNS TABLE(reversal_tfr_key bigint, was_already_reversed boolean, new_balance_from numeric, new_balance_to numeric, event_uuid uuid)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_catalog'
    AS $$
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
  v_orig_tfr := (v_orig.OBJECT_RESPONE_DATA::jsonb->>'tran_internal_id')::bigint;
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
  SELECT SEQ_NO INTO v_orig_seq FROM WLT_TRAN_HIST WHERE TRAN_INTERNAL_ID = v_orig_tfr AND TRAN_TYPE IN ('TRFOUT','TRFOUTF') LIMIT 1;

  -- Guard the refund (credit) leg into sender A. The original post_transfer
  -- blocks crediting a closed or credit-blocked (AML/court) wallet; the reversal
  -- must honour the same controls so it cannot push funds into a frozen account.
  -- Rows are already FOR UPDATE-locked above, so these reads are current; the
  -- whole reversal is atomic, so raising here aborts cleanly for ops to handle.
  -- (B's claw-back is a debit already covered by its inline fund guard below.)
  IF v_a.ACCT_STATUS <> 'A' THEN
    RAISE EXCEPTION 'ACCT_NOT_ACTIVE: refund target % status=%', v_from, v_a.ACCT_STATUS USING ERRCODE = 'P0022';
  END IF;
  IF v_a.CR_BLOCKED = 'Y' THEN
    RAISE EXCEPTION 'CR_RESTRAINT_ACTIVE: refund target % is credit-blocked', v_from USING ERRCODE = 'P0029';
  END IF;

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
  INSERT INTO WLT_TRAN_HIST (INTERNAL_KEY, TRAN_TYPE, POST_DATE, VALUE_DATE,
     TRAN_AMT, CR_DR_MAINT_IND, PREVIOUS_BAL_AMT, ACTUAL_BAL_AMT,
     TRAN_INTERNAL_ID, REFERENCE, ORIG_SEQ_NO, CCY, SOURCE_TYPE, SOURCE_MODULE, TRAN_DESC, GROUP_ID)
  VALUES (v_b.INTERNAL_KEY, 'RVTRF', CURRENT_DATE, CURRENT_DATE,
     v_amt, 'DR', v_b.ACTUAL_BAL + v_amt, v_b.ACTUAL_BAL,
     v_rev_tfr, v_rref, v_orig_seq, v_b.CCY, p_channel, 'WLT',
     'Reverse transfer (claw-back): '||COALESCE(p_reason,'?'), v_b.GROUP_ID)
  RETURNING SEQ_NO INTO v_seq_base;

  INSERT INTO WLT_TRAN_HIST (INTERNAL_KEY, TRAN_TYPE, POST_DATE, VALUE_DATE,
     TRAN_AMT, CR_DR_MAINT_IND, PREVIOUS_BAL_AMT, ACTUAL_BAL_AMT,
     TRAN_INTERNAL_ID, TFR_SEQ_NO, REFERENCE, ORIG_SEQ_NO, CCY, SOURCE_TYPE, SOURCE_MODULE, TRAN_DESC, GROUP_ID)
  VALUES (v_a.INTERNAL_KEY, 'RVTRF', CURRENT_DATE, CURRENT_DATE,
     v_amt, 'CR', v_a.ACTUAL_BAL - v_amt - v_fee, v_a.ACTUAL_BAL - v_fee,
     v_rev_tfr, v_seq_base, v_rref, v_orig_seq, v_a.CCY, p_channel, 'WLT',
     'Reverse transfer (refund)', v_a.GROUP_ID);

  IF v_fee > 0 THEN
    INSERT INTO WLT_TRAN_HIST (INTERNAL_KEY, TRAN_TYPE, POST_DATE, VALUE_DATE,
       TRAN_AMT, CR_DR_MAINT_IND, PREVIOUS_BAL_AMT, ACTUAL_BAL_AMT,
       TRAN_INTERNAL_ID, TFR_SEQ_NO, REFERENCE, ORIG_SEQ_NO, CCY, SOURCE_MODULE, TRAN_DESC, GROUP_ID)
    VALUES (v_a.INTERNAL_KEY, 'RVFEE', CURRENT_DATE, CURRENT_DATE,
       v_fee, 'CR', v_a.ACTUAL_BAL - v_fee, v_a.ACTUAL_BAL,
       v_rev_tfr, v_seq_base, v_rref, v_orig_seq, v_a.CCY, 'WLT',
       'Refund transfer fee + VAT', v_a.GROUP_ID);
  END IF;

  -- GL flip: CR A / DR B (principal); fee refund: DR 401.01 + DR 203.01 / CR A
  INSERT INTO WLT_GL_BATCH (TRAN_KEY, SEQ_NO, GL_CODE, CLIENT_NO, ACCT_INTERNAL_KEY, AMOUNT, TRAN_NATURE, CCY, REFERENCE, POST_DATE, VALUE_DATE)
  VALUES
    (v_rev_tfr, 1, v_a_gl, v_a.CLIENT_NO, v_a.INTERNAL_KEY, v_amt, 'CR', v_a.CCY, v_rref, CURRENT_DATE, CURRENT_DATE),
    (v_rev_tfr, 2, v_b_gl, v_b.CLIENT_NO, v_b.INTERNAL_KEY, v_amt, 'DR', v_b.CCY, v_rref, CURRENT_DATE, CURRENT_DATE);
  IF v_fee > 0 THEN
    INSERT INTO WLT_GL_BATCH (TRAN_KEY, SEQ_NO, GL_CODE, CLIENT_NO, ACCT_INTERNAL_KEY, AMOUNT, TRAN_NATURE, CCY, REFERENCE, POST_DATE, VALUE_DATE)
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


--
-- Name: post_withdraw(character varying, numeric, character varying, character varying, character varying, character varying, jsonb, character varying, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.post_withdraw(p_acct_no character varying, p_amount numeric, p_reference character varying, p_ext_payout_ref character varying, p_beneficiary_bank character varying, p_beneficiary_acct character varying, p_metadata jsonb DEFAULT '{}'::jsonb, p_channel character varying DEFAULT 'MOBILE'::character varying, p_actor character varying DEFAULT NULL::character varying) RETURNS TABLE(tran_internal_id bigint, status character varying, new_balance numeric, fee_gross numeric, vat_amount numeric, event_uuid uuid)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_catalog'
    AS $$
#variable_conflict use_column
DECLARE
  v_actor       VARCHAR(64) := COALESCE(p_actor, session_user);
  v_acct        WLT_ACCT%ROWTYPE;
  v_acct_type   WLT_ACCT_TYPE%ROWTYPE;
  v_def         WLT_TRAN_DEF%ROWTYPE;
  v_kyc         FM_CLIENT_KYC%ROWTYPE;
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
    SELECT (v_existing.OBJECT_RESPONE_DATA::jsonb->>'tran_internal_id')::bigint,
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
  SELECT * INTO v_kyc       FROM FM_CLIENT_KYC WHERE CLIENT_NO = v_acct.CLIENT_NO;
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
    INTERNAL_KEY, TRAN_TYPE, POST_DATE, VALUE_DATE,
    TRAN_AMT, CR_DR_MAINT_IND, PREVIOUS_BAL_AMT, ACTUAL_BAL_AMT,
    TRAN_INTERNAL_ID, REFERENCE, CCY, SOURCE_TYPE, SOURCE_MODULE,
    TRAN_DESC, NARRATIVE, GROUP_ID, SHARD_INDEX, METADATA
  ) VALUES
    (v_acct.INTERNAL_KEY, 'WDRAW', CURRENT_DATE, CURRENT_DATE,
     p_amount, 'DR', v_acct.ACTUAL_BAL + v_total_debit, v_acct.ACTUAL_BAL + v_fee_gross,
     v_tfr_key, p_reference, v_acct.CCY, p_channel, 'WLT',
     'Withdraw to bank', left(p_metadata->>'narrative',250), v_acct.GROUP_ID, v_acct.SHARD_INDEX, p_metadata)
  RETURNING SEQ_NO INTO v_out_seq;

  IF v_fee_gross > 0 THEN
    INSERT INTO WLT_TRAN_HIST (
      INTERNAL_KEY, TRAN_TYPE, POST_DATE, VALUE_DATE,
      TRAN_AMT, CR_DR_MAINT_IND, PREVIOUS_BAL_AMT, ACTUAL_BAL_AMT,
      TRAN_INTERNAL_ID, TFR_SEQ_NO, REFERENCE, CCY, SOURCE_MODULE,
      TRAN_DESC, NARRATIVE, GROUP_ID, SHARD_INDEX, METADATA
    ) VALUES
      (v_acct.INTERNAL_KEY, 'FEEWD', CURRENT_DATE, CURRENT_DATE,
       v_fee_gross, 'DR', v_acct.ACTUAL_BAL + v_fee_gross, v_acct.ACTUAL_BAL,
       v_tfr_key, v_out_seq, p_reference, v_acct.CCY, 'WLT',
       'Fee + VAT for withdraw', left(p_metadata->>'narrative',250), v_acct.GROUP_ID, v_acct.SHARD_INDEX, p_metadata);
  END IF;

  -- BATCH × 5
  INSERT INTO WLT_GL_BATCH (TRAN_KEY, SEQ_NO, GL_CODE, CLIENT_NO, ACCT_INTERNAL_KEY,
                         AMOUNT, TRAN_NATURE, CCY, REFERENCE, POST_DATE, VALUE_DATE)
  VALUES
    (v_tfr_key, 1, v_acct_type.GL_CODE_LIAB, v_acct.CLIENT_NO, v_acct.INTERNAL_KEY,
       p_amount, 'DR', v_acct.CCY, p_reference, CURRENT_DATE, CURRENT_DATE),
    (v_tfr_key, 2, v_def.CONTRA_GL_CODE,    v_acct.CLIENT_NO, v_acct.INTERNAL_KEY,
       p_amount, 'CR', v_acct.CCY, p_reference, CURRENT_DATE, CURRENT_DATE);
  IF v_fee_gross > 0 THEN
    INSERT INTO WLT_GL_BATCH (TRAN_KEY, SEQ_NO, GL_CODE, CLIENT_NO, ACCT_INTERNAL_KEY,
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
    TRAN_INTERNAL_ID, ACCT_NO, CLIENT_NO, AMOUNT, FEE_GROSS, CCY,
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
          jsonb_build_object('tran_internal_id', v_tfr_key,
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
           'tran_internal_id', v_tfr_key,
           'new_balance',      v_acct.ACTUAL_BAL,
           'fee_gross',        v_fee_gross,
           'vat_amount',       v_vat_amt,
           'event_uuid',       v_event_uuid)::text,
         PROCESSED_AT        = clock_timestamp()
   WHERE OBJECT_REF_ID = p_reference;

  RETURN QUERY SELECT v_tfr_key, 'SUCCESS'::varchar, v_acct.ACTUAL_BAL,
                      v_fee_gross, v_vat_amt, v_event_uuid;
END $$;


--
-- Name: post_withdraw_reversal(character varying, character varying, character varying, character varying, character varying, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.post_withdraw_reversal(p_ext_payout_ref character varying, p_fail_code character varying, p_fail_reason character varying, p_initiator character varying, p_channel character varying DEFAULT 'SYS'::character varying, p_actor character varying DEFAULT NULL::character varying) RETURNS TABLE(reversal_tfr_key bigint, was_already_reversed boolean, event_uuid uuid)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_catalog'
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
    INTERNAL_KEY, TRAN_TYPE, POST_DATE, VALUE_DATE,
    TRAN_AMT, CR_DR_MAINT_IND, PREVIOUS_BAL_AMT, ACTUAL_BAL_AMT,
    TRAN_INTERNAL_ID, REFERENCE, ORIG_SEQ_NO, CCY, SOURCE_TYPE, SOURCE_MODULE,
    TRAN_DESC, GROUP_ID, SHARD_INDEX
  ) VALUES (
    v_acct.INTERNAL_KEY, 'RVWD', CURRENT_DATE, CURRENT_DATE,
    v_track.AMOUNT, 'CR',
    v_acct.ACTUAL_BAL - v_track.AMOUNT - v_track.FEE_GROSS,
    v_acct.ACTUAL_BAL - v_track.FEE_GROSS,
    v_rev_tfr_key, 'RVWD-' || p_ext_payout_ref, v_track.TRAN_INTERNAL_ID,
    v_acct.CCY, p_channel, 'WLT',
    'Reverse withdraw: ' || COALESCE(p_fail_code, '?'),
    v_acct.GROUP_ID, v_acct.SHARD_INDEX);

  -- RVFEE leg (refund fee + VAT) if fee was collected
  IF v_track.FEE_GROSS > 0 THEN
    INSERT INTO WLT_TRAN_HIST (
      INTERNAL_KEY, TRAN_TYPE, POST_DATE, VALUE_DATE,
      TRAN_AMT, CR_DR_MAINT_IND, PREVIOUS_BAL_AMT, ACTUAL_BAL_AMT,
      TRAN_INTERNAL_ID, REFERENCE, ORIG_SEQ_NO, CCY, SOURCE_MODULE,
      TRAN_DESC, GROUP_ID, SHARD_INDEX
    ) VALUES (
      v_acct.INTERNAL_KEY, 'RVFEE', CURRENT_DATE, CURRENT_DATE,
      v_track.FEE_GROSS, 'CR',
      v_acct.ACTUAL_BAL - v_track.FEE_GROSS, v_acct.ACTUAL_BAL,
      v_rev_tfr_key, 'RVFEE-' || p_ext_payout_ref, v_track.TRAN_INTERNAL_ID,
      v_acct.CCY, 'WLT',
      'Refund fee + VAT', v_acct.GROUP_ID, v_acct.SHARD_INDEX);
  END IF;

  -- Mirror GL legs flipped
  INSERT INTO WLT_GL_BATCH (TRAN_KEY, SEQ_NO, GL_CODE, CLIENT_NO, ACCT_INTERNAL_KEY,
                         AMOUNT, TRAN_NATURE, CCY, REFERENCE, POST_DATE, VALUE_DATE)
  VALUES
    (v_rev_tfr_key, 1, v_orig_def.CONTRA_GL_CODE, v_acct.CLIENT_NO, v_acct.INTERNAL_KEY,
       v_track.AMOUNT, 'DR', v_acct.CCY, 'RVWD-' || p_ext_payout_ref, CURRENT_DATE, CURRENT_DATE),
    (v_rev_tfr_key, 2, v_acct_type.GL_CODE_LIAB, v_acct.CLIENT_NO, v_acct.INTERNAL_KEY,
       v_track.AMOUNT, 'CR', v_acct.CCY, 'RVWD-' || p_ext_payout_ref, CURRENT_DATE, CURRENT_DATE);
  IF v_track.FEE_GROSS > 0 THEN
    INSERT INTO WLT_GL_BATCH (TRAN_KEY, SEQ_NO, GL_CODE, CLIENT_NO, ACCT_INTERNAL_KEY,
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
   WHERE TRAN_INTERNAL_ID = v_track.TRAN_INTERNAL_ID;

  -- OUTBOX
  INSERT INTO WLT_OUTBOX (AGGREGATE_TYPE, AGGREGATE_ID, EVENT_TYPE,
                          PARTITION_KEY, TOPIC, PAYLOAD)
  VALUES ('TRANSACTION', v_rev_tfr_key::text,
          'wallet.withdraw.reversed.v1', v_track.ACCT_NO,
          'wallet.withdrawals',
          jsonb_build_object('ext_payout_ref', p_ext_payout_ref,
                             'reversal_tfr_key', v_rev_tfr_key,
                             'orig_tfr_key', v_track.TRAN_INTERNAL_ID,
                             'amount', v_track.AMOUNT + v_track.FEE_GROSS,
                             'fail_code', p_fail_code,
                             'reason', p_fail_reason,
                             'initiator', p_initiator))
  RETURNING EVENT_UUID INTO v_event_uuid;

  RETURN QUERY SELECT v_rev_tfr_key, FALSE, v_event_uuid;
END $$;


--
-- Name: release_restraint(bigint, character varying, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.release_restraint(p_restraint_id bigint, p_reason character varying DEFAULT NULL::character varying, p_actor character varying DEFAULT NULL::character varying) RETURNS TABLE(restraint_id bigint, status character varying, available_bal_after numeric, version integer)
    LANGUAGE plpgsql
    AS $$
#variable_conflict use_column
DECLARE
  v_r       WLT_RESTRAINTS%ROWTYPE;
  v_acct    WLT_ACCT%ROWTYPE;
  v_actor   VARCHAR(40)   := COALESCE(p_actor, session_user);
  v_restr   NUMERIC(18,2);
  v_crblk   VARCHAR(1);
  v_present VARCHAR(4);
  v_ver     INTEGER;
BEGIN
  SELECT * INTO v_r FROM WLT_RESTRAINTS WHERE seq_no = p_restraint_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'RESTRAINT_NOT_FOUND' USING ERRCODE = 'P0065';
  END IF;
  IF v_r.status <> 'A' THEN
    RAISE EXCEPTION 'RESTRAINT_ALREADY_REMOVED' USING ERRCODE = 'P0066';
  END IF;
  IF v_r.internal_key IS NULL THEN
    RAISE EXCEPTION 'RESTRAINT_NOT_FOUND: group-scoped not supported' USING ERRCODE = 'P0065';
  END IF;
  -- court/tax liens require a documented removal reason
  IF v_r.restraint_purpose IN ('COURT_ORDER','TAX_LIEN')
     AND (p_reason IS NULL OR length(btrim(p_reason)) = 0) THEN
    RAISE EXCEPTION 'COURT_ORDER_REMOVE_REQUIRES_DOC' USING ERRCODE = 'P0067';
  END IF;

  SELECT * INTO v_acct FROM WLT_ACCT WHERE internal_key = v_r.internal_key FOR UPDATE;

  UPDATE WLT_RESTRAINTS
     SET status = 'R', removed_at = NOW(), removed_by = v_actor, removed_reason = p_reason
   WHERE seq_no = p_restraint_id;

  -- recompute aggregates from the remaining ACTIVE (in-window) restraints
  SELECT
    COALESCE(SUM(CASE WHEN restraint_type IN ('DEBIT','ALL') THEN pledged_amt ELSE 0 END), 0),
    CASE WHEN bool_or(restraint_type IN ('CREDIT','ALL')) THEN 'Y' ELSE 'N' END,
    CASE WHEN count(*) > 0 THEN 'Y' ELSE 'N' END
    INTO v_restr, v_crblk, v_present
    FROM WLT_RESTRAINTS
   WHERE internal_key = v_r.internal_key
     AND status = 'A'
     AND CURRENT_DATE BETWEEN start_date AND COALESCE(end_date, DATE '9999-12-31');

  UPDATE WLT_ACCT
     SET total_restrained_amt = v_restr,
         cr_blocked           = COALESCE(v_crblk, 'N'),
         restraint_present    = v_present,
         version              = version + 1
   WHERE internal_key = v_r.internal_key
   RETURNING version INTO v_ver;

  RETURN QUERY SELECT p_restraint_id, 'R'::varchar,
                      (v_acct.actual_bal - v_restr)::numeric, v_ver;
END;
$$;


--
-- Name: run_eod(date); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.run_eod(IN p_biz_date date)
    LANGUAGE plpgsql
    AS $$
BEGIN
  CALL eod_snapshot(p_biz_date);          -- T1
  CALL eod_prev_day_roll(p_biz_date);     -- T2 (depends on T1)
  CALL eod_expire_restraints(p_biz_date); -- T5
  CALL eod_gl_feed_post(p_biz_date);      -- T3  WLT_GL_BATCH 'P' → 'S' (GL feed finalised)
  CALL eod_trial_balance(p_biz_date);     -- T6 (US-6.3)
  CALL eod_close_period(p_biz_date);      -- T7  seal D → engage write-freeze (US-6.1)
END;
$$;


--
-- Name: set_default_client_bank(character varying, bigint, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_default_client_bank(p_client_no character varying, p_link_id bigint, p_actor character varying DEFAULT NULL::character varying) RETURNS TABLE(link_id bigint, client_no character varying, is_default smallint, status character varying, updated_at timestamp with time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
#variable_conflict use_column
BEGIN
  IF NOT EXISTS (SELECT 1 FROM FM_CLIENT_BANKS
                  WHERE link_id = p_link_id AND client_no = p_client_no) THEN
    RAISE EXCEPTION 'BANK_LINK_NOT_FOUND' USING ERRCODE = 'P0074';
  END IF;

  -- Clear the current default first to respect uk_cb_one_default, then set.
  UPDATE FM_CLIENT_BANKS SET is_default = 0
   WHERE client_no = p_client_no AND is_default = 1 AND link_id <> p_link_id;

  RETURN QUERY
  UPDATE FM_CLIENT_BANKS SET is_default = 1, updated_at = NOW()
   WHERE link_id = p_link_id AND client_no = p_client_no
  RETURNING link_id, client_no, is_default, status, updated_at;
END;
$$;


--
-- Name: update_account_status(character varying, character varying, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_account_status(p_acct_no character varying, p_status character varying, p_actor character varying DEFAULT NULL::character varying) RETURNS TABLE(acct_no character varying, acct_status character varying, version integer)
    LANGUAGE plpgsql
    AS $$
#variable_conflict use_column
DECLARE
  v_acct WLT_ACCT%ROWTYPE;
  v_ver  INTEGER;
BEGIN
  IF p_status NOT IN ('A','B','C') THEN
    RAISE EXCEPTION 'INVALID_REQUEST: status must be A (active), B (blocked) or C (closed)'
      USING ERRCODE = 'P0071';
  END IF;

  SELECT * INTO v_acct FROM WLT_ACCT WHERE acct_no = p_acct_no FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ACCT_NOT_FOUND: %', p_acct_no USING ERRCODE = 'P0001';
  END IF;
  IF v_acct.acct_status = 'C' THEN
    RAISE EXCEPTION 'ACCT_NOT_ACTIVE: account closed (terminal state)' USING ERRCODE = 'P0004';
  END IF;
  -- close (→C) requires zero balance (§6.2 / AC-08)
  IF p_status = 'C' AND v_acct.actual_bal <> 0 THEN
    RAISE EXCEPTION 'ACCT_CLOSE_NONZERO_BAL' USING ERRCODE = 'P0082';
  END IF;

  UPDATE WLT_ACCT
     SET acct_status = p_status,
         version     = version + 1
   WHERE acct_no = p_acct_no
   RETURNING acct_status, version INTO v_acct.acct_status, v_ver;

  RETURN QUERY SELECT p_acct_no, v_acct.acct_status, v_ver;
END;
$$;


--
-- Name: update_client(character varying, character varying, character varying, character varying, character varying, character varying, character varying, date, character varying, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_client(p_client_no character varying, p_client_name character varying DEFAULT NULL::character varying, p_status character varying DEFAULT NULL::character varying, p_country_loc character varying DEFAULT NULL::character varying, p_country_citizen character varying DEFAULT NULL::character varying, p_surname character varying DEFAULT NULL::character varying, p_given_name character varying DEFAULT NULL::character varying, p_birth_date date DEFAULT NULL::date, p_sex character varying DEFAULT NULL::character varying, p_actor character varying DEFAULT NULL::character varying) RETURNS TABLE(client_no character varying, status character varying, updated_at timestamp with time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
#variable_conflict use_column
DECLARE
  v_type    VARCHAR(12);
  v_status  VARCHAR(4);
  v_updated TIMESTAMPTZ;
BEGIN
  SELECT client_type INTO v_type FROM FM_CLIENT WHERE client_no = p_client_no FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'CLIENT_NOT_FOUND' USING ERRCODE = 'P0073';
  END IF;

  UPDATE FM_CLIENT
     SET client_name     = COALESCE(p_client_name, client_name),
         status          = COALESCE(p_status, status),
         country_loc     = COALESCE(p_country_loc, country_loc),
         country_citizen = COALESCE(p_country_citizen, country_citizen),
         updated_at      = NOW()
   WHERE client_no = p_client_no
   RETURNING status, updated_at INTO v_status, v_updated;

  -- IND personal details live in FM_CLIENT_KYC.extra_data (US-1.15); merge the
  -- provided keys (jsonb_strip_nulls drops the absent ones so existing values stay).
  IF v_type = 'IND'
     AND (p_surname IS NOT NULL OR p_given_name IS NOT NULL
          OR p_birth_date IS NOT NULL OR p_sex IS NOT NULL) THEN
    UPDATE FM_CLIENT_KYC
       SET extra_data = extra_data || jsonb_strip_nulls(jsonb_build_object(
             'surname',    p_surname,
             'given_name', p_given_name,
             'birth_date', p_birth_date,
             'sex',        p_sex))
     WHERE client_no = p_client_no;
  END IF;

  RETURN QUERY SELECT p_client_no, v_status, v_updated;
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: fm_client; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.fm_client (
    client_no character varying(48) NOT NULL,
    global_id character varying(64),
    global_id_type character varying(12),
    client_name character varying(200) NOT NULL,
    client_short character varying(100),
    client_type character varying(12),
    client_grp character varying(48),
    acct_exec character varying(12),
    country_loc character varying(8),
    country_citizen character varying(8),
    country_risk character varying(8),
    state_loc character varying(8),
    registered_date date,
    non_resident_ctrl character varying(4),
    tax_file_no character varying(60),
    taxable_ind character varying(4),
    status character varying(4) DEFAULT 'A'::character varying NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    channel character varying(20),
    created_by character varying(64) DEFAULT 'SYSTEM'::character varying NOT NULL,
    updated_by character varying(64) DEFAULT 'SYSTEM'::character varying NOT NULL
);


--
-- Name: fm_client_banks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.fm_client_banks (
    link_id bigint NOT NULL,
    client_no character varying(48) NOT NULL,
    bank_code character varying(20) NOT NULL,
    bank_name character varying(120),
    acct_no_enc bytea NOT NULL,
    acct_holder_name character varying(200),
    is_default smallint DEFAULT 0 NOT NULL,
    status character varying(4) DEFAULT 'A'::character varying NOT NULL,
    verified_at timestamp with time zone,
    channel character varying(20),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by character varying(64) DEFAULT 'SYSTEM'::character varying NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by character varying(64) DEFAULT 'SYSTEM'::character varying NOT NULL,
    CONSTRAINT chk_cb_default CHECK ((is_default = ANY (ARRAY[0, 1])))
);


--
-- Name: fm_client_banks_link_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.fm_client_banks ALTER COLUMN link_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.fm_client_banks_link_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: fm_client_contact; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.fm_client_contact (
    client_no character varying(48) NOT NULL,
    contact_type character varying(12) NOT NULL,
    addr_line1 character varying(200),
    addr_line2 character varying(200),
    city character varying(80),
    country character varying(8),
    phone_no_enc bytea,
    email_enc bytea,
    channel character varying(20),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by character varying(64) DEFAULT 'SYSTEM'::character varying NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by character varying(64) DEFAULT 'SYSTEM'::character varying NOT NULL
);


--
-- fm_client_identifiers removed: the primary identity doc is flattened into real
-- FM_CLIENT_KYC columns (global_id/global_id_type/date_issue/expire_date/place_issue).
--

--
-- fm_client_indvl removed (US-1.15): individual personal details folded into
-- FM_CLIENT_KYC.extra_data JSONB. See create_client / update_client / fn_create_client.
--

--
-- Name: fm_currency; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.fm_currency (
    ccy character varying(4) NOT NULL,
    ccy_desc character varying(80) NOT NULL,
    deci_places smallint DEFAULT 2 NOT NULL,
    day_basis smallint DEFAULT 360 NOT NULL,
    round_trunc character varying(4),
    ccy_group character varying(4),
    status character varying(4) DEFAULT 'A'::character varying NOT NULL,
    channel character varying(20),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by character varying(64) DEFAULT 'SYSTEM'::character varying NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by character varying(64) DEFAULT 'SYSTEM'::character varying NOT NULL
);


--
-- Name: fm_gl_mast; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.fm_gl_mast (
    gl_code character varying(32) NOT NULL,
    gl_code_desc character varying(120) NOT NULL,
    gl_code_type character varying(4),
    control_gl_code character varying(32),
    bspl_type character varying(4),
    gl_type character varying(12),
    tfr_ind character varying(4),
    status character varying(4) DEFAULT 'A'::character varying NOT NULL,
    channel character varying(20),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by character varying(64) DEFAULT 'SYSTEM'::character varying NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by character varying(64) DEFAULT 'SYSTEM'::character varying NOT NULL
);


--
-- Name: fm_nos_vos; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.fm_nos_vos (
    nos_vos_no bigint NOT NULL,
    acct_type character varying(12) NOT NULL,
    ccy character varying(4) NOT NULL,
    client_no character varying(48),
    acct_desc character varying(120),
    gl_code character varying(32) NOT NULL,
    acct_no character varying(80) NOT NULL,
    internal_key bigint,
    status character varying(4) DEFAULT 'A'::character varying NOT NULL,
    channel character varying(20),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by character varying(64) DEFAULT 'SYSTEM'::character varying NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by character varying(64) DEFAULT 'SYSTEM'::character varying NOT NULL
);


--
-- Name: seq_acct_no; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.seq_acct_no
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 100;


--
-- Name: seq_client; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.seq_client
    START WITH 1000000000
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 100;


--
-- Name: seq_tfr; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.seq_tfr
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1000;


--
-- Name: fm_client_kyc; Type: TABLE; Schema: public; Owner: -
--
-- Centralized KYC for ALL client types (IND/CORP/MER) — US-9.16 rename
-- (WLT_CLIENT_KYC -> FM_CLIENT_KYC, it is client master-data) + US-1.15:
-- type-specific identity lives in extra_data JSONB (FM_CLIENT_INDVL folded in;
-- surname/given_name/resident_status + ORG legal_rep/ubo/business_reg_no);
-- the primary identity document + personal birth/sex are FLAT real columns
-- (global_id/global_id_type/date_issue/expire_date/place_issue/birthdate/sex —
-- flattened out of the old FM_CLIENT_IDENTIFIERS table);
-- related_docs JSONB replaces the old scalar doc_url. Phone is nullable: a client
-- can exist before the onboarding flow captures/verifies a phone (no OTP).
--

CREATE TABLE public.fm_client_kyc (
    kyc_id bigint NOT NULL,
    client_no character varying(48) NOT NULL,
    phone_no_enc bytea,
    phone_no_hash bytea,
    email_enc bytea,
    kyc_tier character varying(4) DEFAULT '1'::character varying NOT NULL,
    ekyc_provider character varying(40),
    ekyc_ref character varying(80),
    face_match_score numeric(5,3),
    liveness_result character varying(8),
    global_id character varying(64),
    global_id_type character varying(20),
    date_issue date,
    expire_date date,
    place_issue character varying(120),
    birthdate date,
    sex character varying(4),
    extra_data jsonb DEFAULT '{}'::jsonb NOT NULL,
    related_docs jsonb DEFAULT '[]'::jsonb NOT NULL,
    status character varying(4) DEFAULT 'A'::character varying NOT NULL,
    risk_level character varying(4) DEFAULT 'L'::character varying NOT NULL,
    verified_at timestamp with time zone,
    verified_by character varying(40),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    channel character varying(20),
    created_by character varying(64) DEFAULT 'SYSTEM'::character varying NOT NULL,
    updated_by character varying(64) DEFAULT 'SYSTEM'::character varying NOT NULL,
    CONSTRAINT chk_kyc_extra_obj CHECK ((jsonb_typeof(extra_data) = 'object'::text)),
    CONSTRAINT chk_kyc_reldocs_arr CHECK ((jsonb_typeof(related_docs) = 'array'::text)),
    CONSTRAINT chk_kyc_st CHECK (((status)::text = ANY (ARRAY[('A'::character varying)::text, ('B'::character varying)::text, ('C'::character varying)::text, ('P'::character varying)::text]))),
    CONSTRAINT chk_kyc_tier CHECK (((kyc_tier)::text = ANY (ARRAY[('0'::character varying)::text, ('1'::character varying)::text, ('2'::character varying)::text, ('3'::character varying)::text])))
);


--
-- Name: v_client_masked; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_client_masked AS
 SELECT c.client_no,
    regexp_replace((c.client_name)::text, '(^.).*(.$)'::text, '\1***\2'::text) AS client_name_masked,
    c.client_type,
    c.global_id_type,
        CASE
            WHEN (c.global_id IS NULL) THEN NULL::text
            ELSE ('****'::text || "right"((c.global_id)::text, 4))
        END AS global_id_masked,
    c.country_loc,
    c.country_citizen,
    c.client_grp,
    c.acct_exec,
    c.status,
    k.birthdate AS birth_date,
    k.sex,
    (k.extra_data ->> 'resident_status') AS resident_status,
    k.kyc_tier,
    k.status AS kyc_status,
    k.risk_level,
        CASE
            WHEN (k.phone_no_hash IS NULL) THEN NULL::text
            ELSE ('09xxxxx'::text || "right"(encode(k.phone_no_hash, 'hex'::text), 3))
        END AS phone_masked,
    k.verified_at
   FROM (public.fm_client c
     LEFT JOIN LATERAL ( SELECT k2.kyc_tier,
            k2.status,
            k2.risk_level,
            k2.phone_no_hash,
            k2.extra_data,
            k2.birthdate,
            k2.sex,
            k2.verified_at
           FROM public.fm_client_kyc k2
          WHERE ((k2.client_no)::text = (c.client_no)::text)
          ORDER BY k2.kyc_id DESC
         LIMIT 1) k ON (true));


--
-- Name: v_kyc_masked; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_kyc_masked AS
 SELECT kyc_id,
    client_no,
    ('09xxxxx'::text || "right"(encode(phone_no_hash, 'hex'::text), 3)) AS phone_masked,
    kyc_tier,
    status,
    risk_level,
    verified_at
   FROM public.fm_client_kyc;


--
-- Name: wlt_acct; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.wlt_acct (
    internal_key bigint NOT NULL,
    acct_no character varying(20) NOT NULL,
    client_no character varying(48) NOT NULL,
    acct_type character varying(12) NOT NULL,
    ccy character varying(4) DEFAULT 'VND'::character varying NOT NULL,
    acct_status character varying(4) DEFAULT 'A'::character varying NOT NULL,
    actual_bal numeric(18,2) DEFAULT 0 NOT NULL,
    total_restrained_amt numeric(18,2) DEFAULT 0 NOT NULL,
    calc_bal numeric(18,2) GENERATED ALWAYS AS ((actual_bal - total_restrained_amt)) STORED,
    prev_day_actual_bal numeric(18,2) DEFAULT 0 NOT NULL,
    acct_open_date date DEFAULT CURRENT_DATE NOT NULL,
    last_tran_date timestamp with time zone,
    restraint_present character varying(4) DEFAULT 'N'::character varying NOT NULL,
    cr_blocked character varying(1) DEFAULT 'N'::character varying NOT NULL,
    version integer DEFAULT 0 NOT NULL,
    group_id character varying(20),
    shard_index smallint,
    acct_role character varying(12) DEFAULT 'STANDALONE'::character varying NOT NULL,
    channel character varying(20),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by character varying(64) DEFAULT 'SYSTEM'::character varying NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by character varying(64) DEFAULT 'SYSTEM'::character varying NOT NULL,
    CONSTRAINT chk_acct_avail CHECK ((actual_bal >= total_restrained_amt)),
    CONSTRAINT chk_acct_bal CHECK ((actual_bal >= (0)::numeric)),
    CONSTRAINT chk_acct_restrained CHECK ((total_restrained_amt >= (0)::numeric)),
    CONSTRAINT chk_acct_role CHECK (((acct_role)::text = ANY (ARRAY[('STANDALONE'::character varying)::text, ('SHARD'::character varying)::text, ('SETTLEMENT'::character varying)::text]))),
    CONSTRAINT chk_acct_status CHECK (((acct_status)::text = ANY (ARRAY[('A'::character varying)::text, ('B'::character varying)::text, ('C'::character varying)::text, ('P'::character varying)::text, ('F'::character varying)::text]))),
    CONSTRAINT chk_shard_consistency CHECK (((((acct_role)::text = 'STANDALONE'::text) AND (group_id IS NULL) AND (shard_index IS NULL)) OR (((acct_role)::text = 'SHARD'::text) AND (group_id IS NOT NULL) AND (shard_index IS NOT NULL)) OR (((acct_role)::text = 'SETTLEMENT'::text) AND (group_id IS NOT NULL) AND (shard_index IS NULL))))
)
WITH (fillfactor='80', autovacuum_vacuum_scale_factor='0.02', autovacuum_vacuum_cost_limit='2000');


--
-- Name: wlt_restraints; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.wlt_restraints (
    seq_no bigint NOT NULL,
    internal_key bigint,
    group_id character varying(20),
    restraint_type character varying(8) NOT NULL,
    restraint_purpose character varying(16) NOT NULL,
    pledged_amt numeric(18,2) DEFAULT 0 NOT NULL,
    start_date date DEFAULT CURRENT_DATE NOT NULL,
    end_date date,
    status character varying(4) DEFAULT 'A'::character varying NOT NULL,
    narrative character varying(500),
    reference_doc character varying(500),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by character varying(40) NOT NULL,
    removed_at timestamp with time zone,
    removed_by character varying(40),
    removed_reason character varying(500),
    channel character varying(20),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by character varying(64) DEFAULT 'SYSTEM'::character varying NOT NULL,
    CONSTRAINT chk_rstr_dates CHECK (((end_date IS NULL) OR (end_date >= start_date))),
    CONSTRAINT chk_rstr_pledged CHECK ((pledged_amt >= (0)::numeric)),
    CONSTRAINT chk_rstr_scope CHECK ((((internal_key IS NOT NULL) AND (group_id IS NULL)) OR ((internal_key IS NULL) AND (group_id IS NOT NULL)))),
    CONSTRAINT chk_rstr_status CHECK (((status)::text = ANY (ARRAY[('A'::character varying)::text, ('R'::character varying)::text, ('E'::character varying)::text]))),
    CONSTRAINT chk_rstr_type CHECK (((restraint_type)::text = ANY (ARRAY[('DEBIT'::character varying)::text, ('CREDIT'::character varying)::text, ('ALL'::character varying)::text, ('INFO'::character varying)::text])))
);


--
-- Name: v_wlt_active_restraints_effective; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_wlt_active_restraints_effective AS
 SELECT COALESCE(r.internal_key, a.internal_key) AS internal_key,
    r.seq_no AS restraint_id,
    r.group_id,
    r.restraint_type,
    r.restraint_purpose,
    r.pledged_amt,
    r.status,
    r.start_date,
    r.end_date,
        CASE
            WHEN (r.group_id IS NOT NULL) THEN 'GROUP'::text
            ELSE 'ACCT'::text
        END AS scope
   FROM (public.wlt_restraints r
     LEFT JOIN public.wlt_acct a ON (((a.group_id)::text = (r.group_id)::text)))
  WHERE (((r.status)::text = 'A'::text) AND ((CURRENT_DATE >= r.start_date) AND (CURRENT_DATE <= COALESCE(r.end_date, '9999-12-31'::date))));


--
-- Name: wlt_acct_group; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.wlt_acct_group (
    group_id character varying(20) NOT NULL,
    client_no character varying(48) NOT NULL,
    group_type character varying(12) NOT NULL,
    shard_count smallint DEFAULT 0 NOT NULL,
    settlement_acct_no character varying(20) NOT NULL,
    shard_threshold numeric(18,2) DEFAULT 200000 NOT NULL,
    shard_buffer numeric(18,2) DEFAULT 50000 NOT NULL,
    sweep_interval_sec smallint DEFAULT 60 NOT NULL,
    group_status character varying(4) DEFAULT 'A'::character varying NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    channel character varying(20),
    created_by character varying(64) DEFAULT 'SYSTEM'::character varying NOT NULL,
    updated_by character varying(64) DEFAULT 'SYSTEM'::character varying NOT NULL,
    CONSTRAINT chk_group_type CHECK (((group_type)::text = ANY (ARRAY[('MERCHANT'::character varying)::text, ('AGENT'::character varying)::text, ('NOSTRO_HOT'::character varying)::text]))),
    CONSTRAINT chk_shard_count CHECK ((shard_count = ANY (ARRAY[0, 4, 8, 16])))
);


--
-- Name: v_wlt_group_balance; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_wlt_group_balance AS
 SELECT g.group_id,
    g.client_no,
    g.group_type,
    s.actual_bal AS settlement_bal,
    (s.actual_bal - s.total_restrained_amt) AS settlement_available,
    COALESCE(sum(sh.actual_bal), (0)::numeric) AS shards_total,
    (s.actual_bal + COALESCE(sum(sh.actual_bal), (0)::numeric)) AS total_balance,
    ((s.actual_bal - s.total_restrained_amt) + COALESCE(sum((sh.actual_bal - sh.total_restrained_amt)), (0)::numeric)) AS total_available,
    count(sh.internal_key) AS active_shards,
    GREATEST(s.last_tran_date, max(sh.last_tran_date)) AS last_tran_date
   FROM ((public.wlt_acct_group g
     JOIN public.wlt_acct s ON ((((s.group_id)::text = (g.group_id)::text) AND ((s.acct_role)::text = 'SETTLEMENT'::text))))
     LEFT JOIN public.wlt_acct sh ON ((((sh.group_id)::text = (g.group_id)::text) AND ((sh.acct_role)::text = 'SHARD'::text))))
  GROUP BY g.group_id, g.client_no, g.group_type, s.actual_bal, s.total_restrained_amt, s.last_tran_date;


--
-- Name: wlt_acct_bal; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.wlt_acct_bal (
    internal_key bigint NOT NULL,
    tran_date date NOT NULL,
    actual_bal numeric(18,2) NOT NULL,
    calc_bal numeric(18,2) NOT NULL,
    prev_actual_bal numeric(18,2),
    prev_calc_bal numeric(18,2),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    channel character varying(20),
    created_by character varying(64) DEFAULT 'SYSTEM'::character varying NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by character varying(64) DEFAULT 'SYSTEM'::character varying NOT NULL
)
PARTITION BY RANGE (tran_date);


--
-- Name: wlt_acct_internal_key_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.wlt_acct ALTER COLUMN internal_key ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.wlt_acct_internal_key_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: wlt_acct_type; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.wlt_acct_type (
    acct_type character varying(12) NOT NULL,
    acct_type_desc character varying(80) NOT NULL,
    gl_code_liab character varying(32) NOT NULL,
    prod_id character varying(16),
    daily_limit numeric(18,2) DEFAULT 20000000 NOT NULL,
    monthly_limit numeric(18,2) DEFAULT 100000000 NOT NULL,
    int_bearing character varying(1) DEFAULT 'N'::character varying NOT NULL,
    status character varying(4) DEFAULT 'A'::character varying NOT NULL,
    channel character varying(20),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by character varying(64) DEFAULT 'SYSTEM'::character varying NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by character varying(64) DEFAULT 'SYSTEM'::character varying NOT NULL
);


--
-- Name: wlt_api_message; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.wlt_api_message (
    seq_no bigint NOT NULL,
    object_ref_id character varying(64) NOT NULL,
    object_channel character varying(40),
    object_subject character varying(40),
    object_user character varying(64),
    object_request_data text,
    object_respone_data text,
    http_status smallint,
    process_status character varying(8) DEFAULT 'PENDING'::character varying NOT NULL,
    object_date timestamp with time zone DEFAULT now() NOT NULL,
    processed_at timestamp with time zone,
    channel character varying(20),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by character varying(64) DEFAULT 'SYSTEM'::character varying NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by character varying(64) DEFAULT 'SYSTEM'::character varying NOT NULL,
    CONSTRAINT chk_api_status CHECK (((process_status)::text = ANY (ARRAY[('PENDING'::character varying)::text, ('SUCCESS'::character varying)::text, ('FAILED'::character varying)::text])))
);
ALTER TABLE ONLY public.wlt_api_message ALTER COLUMN object_request_data SET COMPRESSION lz4;
ALTER TABLE ONLY public.wlt_api_message ALTER COLUMN object_respone_data SET COMPRESSION lz4;


--
-- Name: wlt_api_message_seq_no_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.wlt_api_message ALTER COLUMN seq_no ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.wlt_api_message_seq_no_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: wlt_client_audit_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.wlt_client_audit_log (
    audit_id bigint NOT NULL,
    client_no character varying(48) NOT NULL,
    table_name character varying(40) NOT NULL,
    row_pk jsonb NOT NULL,
    operation character varying(8) NOT NULL,
    changed_at timestamp with time zone DEFAULT now() NOT NULL,
    changed_by character varying(64) NOT NULL,
    change_source character varying(16) NOT NULL,
    change_reason character varying(500),
    old_values jsonb,
    new_values jsonb,
    changed_fields text[] NOT NULL,
    request_id character varying(64),
    ip_address inet,
    user_agent character varying(500),
    maker_id character varying(64),
    checker_id character varying(64),
    approval_ref character varying(64),
    channel character varying(20),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by character varying(64) DEFAULT 'SYSTEM'::character varying NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by character varying(64) DEFAULT 'SYSTEM'::character varying NOT NULL,
    CONSTRAINT chk_audit_op CHECK (((operation)::text = ANY (ARRAY[('INSERT'::character varying)::text, ('UPDATE'::character varying)::text, ('DELETE'::character varying)::text]))),
    CONSTRAINT chk_audit_src CHECK (((change_source)::text = ANY (ARRAY[('OPS_UI'::character varying)::text, ('API'::character varying)::text, ('EKYC'::character varying)::text, ('SYS_BATCH'::character varying)::text, ('COMPLIANCE'::character varying)::text, ('SP_BACKFILL'::character varying)::text])))
)
PARTITION BY RANGE (changed_at);
ALTER TABLE ONLY public.wlt_client_audit_log ALTER COLUMN old_values SET COMPRESSION lz4;
ALTER TABLE ONLY public.wlt_client_audit_log ALTER COLUMN new_values SET COMPRESSION lz4;


--
-- Name: wlt_client_audit_log_audit_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.wlt_client_audit_log ALTER COLUMN audit_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.wlt_client_audit_log_audit_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: fm_client_kyc_kyc_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.fm_client_kyc ALTER COLUMN kyc_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.fm_client_kyc_kyc_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: wlt_eod_audit_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.wlt_eod_audit_log (
    log_id bigint NOT NULL,
    biz_date date NOT NULL,
    task character varying(24) NOT NULL,
    status character varying(12) NOT NULL,
    rows_done bigint DEFAULT 0 NOT NULL,
    started_at timestamp with time zone NOT NULL,
    finished_at timestamp with time zone NOT NULL,
    duration interval GENERATED ALWAYS AS ((finished_at - started_at)) STORED,
    actor character varying(64) DEFAULT 'EOD'::character varying NOT NULL,
    message text,
    CONSTRAINT chk_eod_log_st CHECK (((status)::text = ANY (ARRAY[('DONE'::character varying)::text, ('FAILED'::character varying)::text])))
);


--
-- Name: wlt_eod_audit_log_log_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.wlt_eod_audit_log ALTER COLUMN log_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.wlt_eod_audit_log_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: wlt_eod_run; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.wlt_eod_run (
    biz_date date NOT NULL,
    task character varying(24) NOT NULL,
    status character varying(12) DEFAULT 'RUNNING'::character varying NOT NULL,
    last_key bigint DEFAULT 0 NOT NULL,
    rows_done bigint DEFAULT 0 NOT NULL,
    started_at timestamp with time zone DEFAULT now() NOT NULL,
    finished_at timestamp with time zone,
    message text,
    CONSTRAINT chk_eod_status CHECK (((status)::text = ANY (ARRAY[('RUNNING'::character varying)::text, ('DONE'::character varying)::text, ('FAILED'::character varying)::text])))
);


--
-- Name: wlt_gl_batch; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.wlt_gl_batch (
    tran_key bigint NOT NULL,
    seq_no bigint NOT NULL,
    gl_code character varying(32) NOT NULL,
    client_no character varying(48),
    acct_internal_key bigint,
    amount numeric(18,2) NOT NULL,
    tran_nature character varying(4) NOT NULL,
    ccy character varying(4) NOT NULL,
    reference character varying(64),
    narrative character varying(200),
    post_date date NOT NULL,
    value_date date NOT NULL,
    source_module character varying(8) DEFAULT 'WLT'::character varying NOT NULL,
    status character varying(4) DEFAULT 'P'::character varying NOT NULL,
    time_stamp timestamp with time zone DEFAULT now() NOT NULL,
    channel character varying(20),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by character varying(64) DEFAULT 'SYSTEM'::character varying NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by character varying(64) DEFAULT 'SYSTEM'::character varying NOT NULL,
    CONSTRAINT chk_gl_batch_amt CHECK ((amount >= (0)::numeric)),
    CONSTRAINT chk_gl_batch_nat CHECK (((tran_nature)::text = ANY (ARRAY[('DR'::character varying)::text, ('CR'::character varying)::text]))),
    CONSTRAINT chk_gl_batch_status CHECK (((status)::text = ANY (ARRAY[('P'::character varying)::text, ('S'::character varying)::text, ('F'::character varying)::text, ('R'::character varying)::text])))
)
WITH (autovacuum_vacuum_insert_scale_factor='0.01');


--
-- Name: wlt_gl_map; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.wlt_gl_map (
    acct_type character varying(12) NOT NULL,
    event_type character varying(16) NOT NULL,
    gl_code character varying(32) NOT NULL,
    gl_desc character varying(120),
    channel character varying(20),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by character varying(64) DEFAULT 'SYSTEM'::character varying NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by character varying(64) DEFAULT 'SYSTEM'::character varying NOT NULL
);


--
-- Name: wlt_nostro_bal; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.wlt_nostro_bal (
    nostro_id character varying(16) NOT NULL,
    bal_date date NOT NULL,
    bank_reported_bal numeric(18,2),
    ledger_bal numeric(18,2),
    diff_amt numeric(18,2) GENERATED ALWAYS AS ((bank_reported_bal - ledger_bal)) STORED,
    recon_status character varying(8) DEFAULT 'OPEN'::character varying NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    channel character varying(20),
    created_by character varying(64) DEFAULT 'SYSTEM'::character varying NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by character varying(64) DEFAULT 'SYSTEM'::character varying NOT NULL,
    CONSTRAINT chk_nb_st CHECK (((recon_status)::text = ANY (ARRAY[('OPEN'::character varying)::text, ('MATCH'::character varying)::text, ('BREAK'::character varying)::text, ('RESOLVED'::character varying)::text])))
);


--
-- Name: wlt_nostro_link; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.wlt_nostro_link (
    nostro_id character varying(16) NOT NULL,
    nos_vos_no bigint NOT NULL,
    gl_code character varying(32) NOT NULL,
    purpose character varying(16) DEFAULT 'TKDBTT'::character varying NOT NULL,
    reg_nhnn_code character varying(32),
    status character varying(4) DEFAULT 'A'::character varying NOT NULL,
    last_recon_date date,
    last_recon_bal numeric(18,2),
    channel character varying(20),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by character varying(64) DEFAULT 'SYSTEM'::character varying NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by character varying(64) DEFAULT 'SYSTEM'::character varying NOT NULL
);


--
-- Name: wlt_outbox; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.wlt_outbox (
    event_id bigint NOT NULL,
    event_uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    aggregate_type character varying(20) NOT NULL,
    aggregate_id character varying(64) NOT NULL,
    event_type character varying(40) NOT NULL,
    event_version character varying(8) DEFAULT 'v1'::character varying NOT NULL,
    partition_key character varying(64) NOT NULL,
    topic character varying(60) NOT NULL,
    payload jsonb NOT NULL,
    headers jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    status character varying(8) DEFAULT 'PENDING'::character varying NOT NULL,
    attempts smallint DEFAULT 0 NOT NULL,
    last_attempt_at timestamp with time zone,
    last_error character varying(500),
    sent_at timestamp with time zone,
    kafka_offset bigint,
    kafka_partition smallint,
    channel character varying(20),
    created_by character varying(64) DEFAULT 'SYSTEM'::character varying NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by character varying(64) DEFAULT 'SYSTEM'::character varying NOT NULL,
    CONSTRAINT chk_outbox_status CHECK (((status)::text = ANY (ARRAY[('PENDING'::character varying)::text, ('SENT'::character varying)::text, ('FAILED'::character varying)::text, ('DEAD'::character varying)::text])))
)
PARTITION BY RANGE (created_at);
ALTER TABLE ONLY public.wlt_outbox ALTER COLUMN payload SET COMPRESSION lz4;


--
-- Name: wlt_outbox_event_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.wlt_outbox ALTER COLUMN event_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.wlt_outbox_event_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: wlt_period; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.wlt_period (
    biz_date date NOT NULL,
    status character varying(8) DEFAULT 'CLOSED'::character varying NOT NULL,
    closed_at timestamp with time zone DEFAULT now() NOT NULL,
    closed_by character varying(64) DEFAULT 'EOD'::character varying NOT NULL,
    note text,
    CONSTRAINT chk_period_st CHECK (((status)::text = ANY (ARRAY[('OPEN'::character varying)::text, ('CLOSED'::character varying)::text])))
);


--
-- Name: wlt_restraints_seq_no_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.wlt_restraints ALTER COLUMN seq_no ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.wlt_restraints_seq_no_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: wlt_sweep_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.wlt_sweep_log (
    seq_no bigint NOT NULL,
    group_id character varying(20) NOT NULL,
    shard_acct_no character varying(20) NOT NULL,
    settlement_acct_no character varying(20) NOT NULL,
    swept_amount numeric(18,2) NOT NULL,
    shard_bal_before numeric(18,2) NOT NULL,
    shard_bal_after numeric(18,2) NOT NULL,
    settlement_bal_after numeric(18,2) NOT NULL,
    tran_internal_id bigint,
    trigger_type character varying(16) NOT NULL,
    triggered_by character varying(40),
    status character varying(8) DEFAULT 'SUCCESS'::character varying NOT NULL,
    error_message character varying(500),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    channel character varying(20),
    created_by character varying(64) DEFAULT 'SYSTEM'::character varying NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by character varying(64) DEFAULT 'SYSTEM'::character varying NOT NULL,
    CONSTRAINT chk_sweep_status CHECK (((status)::text = ANY (ARRAY[('SUCCESS'::character varying)::text, ('CONFLICT'::character varying)::text, ('SKIPPED'::character varying)::text, ('FAILED'::character varying)::text]))),
    CONSTRAINT chk_sweep_trigger CHECK (((trigger_type)::text = ANY (ARRAY[('PERIODIC'::character varying)::text, ('THRESHOLD'::character varying)::text, ('URGENT'::character varying)::text, ('EOD'::character varying)::text])))
);


--
-- Name: wlt_sweep_log_seq_no_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.wlt_sweep_log ALTER COLUMN seq_no ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.wlt_sweep_log_seq_no_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: wlt_tran_def; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.wlt_tran_def (
    tran_type character varying(10) NOT NULL,
    tran_desc character varying(120),
    cr_dr_maint_ind character varying(4) NOT NULL,
    reversal_tran_type character varying(10),
    check_fund_ind character varying(1) DEFAULT 'Y'::character varying NOT NULL,
    check_restraint_ind character varying(1) DEFAULT 'Y'::character varying NOT NULL,
    source_type character varying(8),
    contra_gl_code character varying(32),
    min_tran_amt numeric(18,2) DEFAULT 1000 NOT NULL,
    max_tran_amt numeric(18,2) DEFAULT 100000000 NOT NULL,
    max_future_date_days smallint DEFAULT 0 NOT NULL,
    auto_approval character varying(1) DEFAULT 'Y'::character varying NOT NULL,
    narrative character varying(160),
    status character varying(1) DEFAULT 'A'::character varying NOT NULL,
    fee_type character varying(8) DEFAULT 'NONE'::character varying NOT NULL,
    fee_amt numeric(18,2) DEFAULT 0 NOT NULL,
    fee_rate numeric(10,6) DEFAULT 0 NOT NULL,
    fee_min numeric(18,2) DEFAULT 0 NOT NULL,
    fee_max numeric(18,2) DEFAULT 0 NOT NULL,
    vat_rate numeric(6,4) DEFAULT 0.10 NOT NULL,
    fee_gl_code character varying(32),
    vat_gl_code character varying(32),
    fee_tran_type character varying(10),
    channel character varying(20),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by character varying(64) DEFAULT 'SYSTEM'::character varying NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by character varying(64) DEFAULT 'SYSTEM'::character varying NOT NULL,
    CONSTRAINT chk_def_cr_dr CHECK (((cr_dr_maint_ind)::text = ANY (ARRAY[('DR'::character varying)::text, ('CR'::character varying)::text, ('BOTH'::character varying)::text]))),
    CONSTRAINT chk_def_fee_type CHECK (((fee_type)::text = ANY (ARRAY[('NONE'::character varying)::text, ('FIXED'::character varying)::text, ('PERCENT'::character varying)::text])))
);


--
-- Name: wlt_tran_hist; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.wlt_tran_hist (
    internal_key bigint NOT NULL,
    seq_no bigint NOT NULL,
    tran_type character varying(10) NOT NULL,
    post_date date NOT NULL,
    value_date date NOT NULL,
    tran_amt numeric(18,2) NOT NULL,
    cr_dr_maint_ind character varying(2) NOT NULL,
    previous_bal_amt numeric(18,2) NOT NULL,
    actual_bal_amt numeric(18,2) NOT NULL,
    tran_internal_id bigint,
    tfr_seq_no bigint,
    reference character varying(64) NOT NULL,
    orig_seq_no bigint,
    ccy character varying(4) NOT NULL,
    source_type character varying(8),
    source_module character varying(8) DEFAULT 'WLT'::character varying NOT NULL,
    tran_desc character varying(200),
    narrative character varying(250),
    terminal_id character varying(40),
    officer_id character varying(40),
    group_id character varying(20),
    shard_index smallint,
    metadata jsonb,
    time_stamp timestamp with time zone DEFAULT now() NOT NULL,
    channel character varying(20),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by character varying(64) DEFAULT 'SYSTEM'::character varying NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by character varying(64) DEFAULT 'SYSTEM'::character varying NOT NULL,
    CONSTRAINT chk_hist_crdr CHECK (((cr_dr_maint_ind)::text = ANY (ARRAY[('DR'::character varying)::text, ('CR'::character varying)::text])))
)
PARTITION BY RANGE (post_date);
ALTER TABLE ONLY public.wlt_tran_hist ALTER COLUMN metadata SET COMPRESSION lz4;


--
-- Name: wlt_tran_hist_seq_no_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.wlt_tran_hist ALTER COLUMN seq_no ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.wlt_tran_hist_seq_no_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: wlt_trial_balance; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.wlt_trial_balance (
    biz_date date NOT NULL,
    gl_code character varying(32) NOT NULL,
    ccy character varying(4) NOT NULL,
    gl_desc character varying(120),
    opening_bal numeric(20,2) DEFAULT 0 NOT NULL,
    period_dr numeric(20,2) DEFAULT 0 NOT NULL,
    period_cr numeric(20,2) DEFAULT 0 NOT NULL,
    closing_bal numeric(20,2) NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by character varying(64) DEFAULT 'SYSTEM'::character varying NOT NULL
);


--
-- Name: wlt_trial_balance_proof; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.wlt_trial_balance_proof (
    biz_date date NOT NULL,
    ccy character varying(4) NOT NULL,
    gl_count integer NOT NULL,
    grand_dr numeric(24,2) NOT NULL,
    grand_cr numeric(24,2) NOT NULL,
    net_balance numeric(24,2) NOT NULL,
    is_balanced boolean NOT NULL,
    content_hash character varying(64) NOT NULL,
    prev_hash character varying(64) NOT NULL,
    chain_hash character varying(64) NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by character varying(64) DEFAULT 'SYSTEM'::character varying NOT NULL
);


--
-- Name: wlt_withdraw_track; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.wlt_withdraw_track (
    tran_internal_id bigint NOT NULL,
    acct_no character varying(20) NOT NULL,
    client_no character varying(48) NOT NULL,
    amount numeric(18,2) NOT NULL,
    fee_gross numeric(18,2) DEFAULT 0 NOT NULL,
    ccy character varying(4) DEFAULT 'VND'::character varying NOT NULL,
    ext_payout_ref character varying(64) NOT NULL,
    beneficiary_bank character varying(20) NOT NULL,
    beneficiary_acct_enc bytea NOT NULL,
    status character varying(12) DEFAULT 'SUBMITTED'::character varying NOT NULL,
    treasury_batch_id character varying(64),
    napas_ref character varying(64),
    treasury_ack_at timestamp with time zone,
    treasury_final_at timestamp with time zone,
    reversed_at timestamp with time zone,
    reversal_tfr_key bigint,
    fail_code character varying(40),
    fail_reason character varying(500),
    submitted_at timestamp with time zone DEFAULT now() NOT NULL,
    ack_deadline timestamp with time zone DEFAULT (now() + '00:01:00'::interval) NOT NULL,
    final_deadline timestamp with time zone DEFAULT (now() + '24:00:00'::interval) NOT NULL,
    version integer DEFAULT 0 NOT NULL,
    channel character varying(20),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by character varying(64) DEFAULT 'SYSTEM'::character varying NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by character varying(64) DEFAULT 'SYSTEM'::character varying NOT NULL,
    CONSTRAINT chk_wd_status CHECK (((status)::text = ANY (ARRAY[('SUBMITTED'::character varying)::text, ('ACKED'::character varying)::text, ('DISBURSING'::character varying)::text, ('COMPLETED'::character varying)::text, ('FAILED'::character varying)::text, ('REVERSED'::character varying)::text])))
)
WITH (fillfactor='80');


--
-- Name: fm_client_banks fm_client_banks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fm_client_banks
    ADD CONSTRAINT fm_client_banks_pkey PRIMARY KEY (link_id);


--
-- Name: fm_client_contact fm_client_contact_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fm_client_contact
    ADD CONSTRAINT fm_client_contact_pkey PRIMARY KEY (client_no, contact_type);





--
-- Name: fm_client fm_client_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fm_client
    ADD CONSTRAINT fm_client_pkey PRIMARY KEY (client_no);


--
-- Name: fm_currency fm_currency_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fm_currency
    ADD CONSTRAINT fm_currency_pkey PRIMARY KEY (ccy);


--
-- Name: fm_gl_mast fm_gl_mast_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fm_gl_mast
    ADD CONSTRAINT fm_gl_mast_pkey PRIMARY KEY (gl_code);


--
-- Name: fm_nos_vos fm_nos_vos_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fm_nos_vos
    ADD CONSTRAINT fm_nos_vos_pkey PRIMARY KEY (nos_vos_no);


--
-- Name: wlt_eod_audit_log pk_eod_log; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.wlt_eod_audit_log
    ADD CONSTRAINT pk_eod_log PRIMARY KEY (log_id);


--
-- Name: wlt_eod_run pk_eod_run; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.wlt_eod_run
    ADD CONSTRAINT pk_eod_run PRIMARY KEY (biz_date, task);


--
-- Name: wlt_tran_hist pk_hist; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.wlt_tran_hist
    ADD CONSTRAINT pk_hist PRIMARY KEY (internal_key, seq_no, post_date);


--
-- Name: wlt_period pk_period; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.wlt_period
    ADD CONSTRAINT pk_period PRIMARY KEY (biz_date);


--
-- Name: wlt_trial_balance pk_trial_balance; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.wlt_trial_balance
    ADD CONSTRAINT pk_trial_balance PRIMARY KEY (biz_date, gl_code, ccy);


--
-- Name: wlt_trial_balance_proof pk_trial_balance_proof; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.wlt_trial_balance_proof
    ADD CONSTRAINT pk_trial_balance_proof PRIMARY KEY (biz_date, ccy);


--
-- Name: fm_client uk_fm_client_gid; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fm_client
    ADD CONSTRAINT uk_fm_client_gid UNIQUE (global_id, global_id_type);


--
-- Name: wlt_outbox uk_outbox_uuid; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.wlt_outbox
    ADD CONSTRAINT uk_outbox_uuid UNIQUE (event_uuid, created_at);


--
-- Name: wlt_acct wlt_acct_acct_no_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.wlt_acct
    ADD CONSTRAINT wlt_acct_acct_no_key UNIQUE (acct_no);


--
-- Name: wlt_acct_bal wlt_acct_bal_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.wlt_acct_bal
    ADD CONSTRAINT wlt_acct_bal_pkey PRIMARY KEY (internal_key, tran_date);


--
-- Name: wlt_acct_group wlt_acct_group_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.wlt_acct_group
    ADD CONSTRAINT wlt_acct_group_pkey PRIMARY KEY (group_id);


--
-- Name: wlt_acct wlt_acct_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.wlt_acct
    ADD CONSTRAINT wlt_acct_pkey PRIMARY KEY (internal_key);


--
-- Name: wlt_acct_type wlt_acct_type_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.wlt_acct_type
    ADD CONSTRAINT wlt_acct_type_pkey PRIMARY KEY (acct_type);


--
-- Name: wlt_api_message wlt_api_message_object_ref_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.wlt_api_message
    ADD CONSTRAINT wlt_api_message_object_ref_id_key UNIQUE (object_ref_id);


--
-- Name: wlt_api_message wlt_api_message_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.wlt_api_message
    ADD CONSTRAINT wlt_api_message_pkey PRIMARY KEY (seq_no);


--
-- Name: wlt_client_audit_log wlt_client_audit_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.wlt_client_audit_log
    ADD CONSTRAINT wlt_client_audit_log_pkey PRIMARY KEY (audit_id, changed_at);


--
-- Name: fm_client_kyc fm_client_kyc_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fm_client_kyc
    ADD CONSTRAINT fm_client_kyc_pkey PRIMARY KEY (kyc_id);


--
-- Name: wlt_gl_batch wlt_gl_batch_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.wlt_gl_batch
    ADD CONSTRAINT wlt_gl_batch_pkey PRIMARY KEY (tran_key, seq_no);


--
-- Name: wlt_gl_map wlt_gl_map_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.wlt_gl_map
    ADD CONSTRAINT wlt_gl_map_pkey PRIMARY KEY (acct_type, event_type);


--
-- Name: wlt_nostro_bal wlt_nostro_bal_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.wlt_nostro_bal
    ADD CONSTRAINT wlt_nostro_bal_pkey PRIMARY KEY (nostro_id, bal_date);


--
-- Name: wlt_nostro_link wlt_nostro_link_nos_vos_no_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.wlt_nostro_link
    ADD CONSTRAINT wlt_nostro_link_nos_vos_no_key UNIQUE (nos_vos_no);


--
-- Name: wlt_nostro_link wlt_nostro_link_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.wlt_nostro_link
    ADD CONSTRAINT wlt_nostro_link_pkey PRIMARY KEY (nostro_id);


--
-- Name: wlt_outbox wlt_outbox_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.wlt_outbox
    ADD CONSTRAINT wlt_outbox_pkey PRIMARY KEY (event_id, created_at);


--
-- Name: wlt_restraints wlt_restraints_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.wlt_restraints
    ADD CONSTRAINT wlt_restraints_pkey PRIMARY KEY (seq_no);


--
-- Name: wlt_sweep_log wlt_sweep_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.wlt_sweep_log
    ADD CONSTRAINT wlt_sweep_log_pkey PRIMARY KEY (seq_no);


--
-- Name: wlt_tran_def wlt_tran_def_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.wlt_tran_def
    ADD CONSTRAINT wlt_tran_def_pkey PRIMARY KEY (tran_type);


--
-- Name: wlt_withdraw_track wlt_withdraw_track_ext_payout_ref_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.wlt_withdraw_track
    ADD CONSTRAINT wlt_withdraw_track_ext_payout_ref_key UNIQUE (ext_payout_ref);


--
-- Name: wlt_withdraw_track wlt_withdraw_track_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.wlt_withdraw_track
    ADD CONSTRAINT wlt_withdraw_track_pkey PRIMARY KEY (tran_internal_id);


--
-- Name: idx_acct_ccy; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_acct_ccy ON public.wlt_acct USING btree (ccy);


--
-- Name: idx_acct_client; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_acct_client ON public.wlt_acct USING btree (client_no);


--
-- Name: idx_acct_group_role; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_acct_group_role ON public.wlt_acct USING btree (group_id, acct_role) WHERE (group_id IS NOT NULL);


--
-- Name: idx_acct_status_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_acct_status_type ON public.wlt_acct USING btree (acct_status, acct_type);


--
-- Name: idx_api_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_api_date ON public.wlt_api_message USING btree (object_date);


--
-- Name: idx_api_subj; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_api_subj ON public.wlt_api_message USING btree (object_subject, process_status);


--
-- Name: idx_caudit_changed_fields; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_caudit_changed_fields ON ONLY public.wlt_client_audit_log USING gin (changed_fields);


--
-- Name: idx_caudit_client_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_caudit_client_time ON ONLY public.wlt_client_audit_log USING btree (client_no, changed_at DESC);


--
-- Name: idx_caudit_request; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_caudit_request ON ONLY public.wlt_client_audit_log USING btree (request_id) WHERE (request_id IS NOT NULL);


--
-- Name: idx_caudit_table_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_caudit_table_time ON ONLY public.wlt_client_audit_log USING btree (table_name, changed_at DESC);


--
-- Name: idx_cb_client; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_cb_client ON public.fm_client_banks USING btree (client_no);


--
-- Name: idx_eod_log_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_eod_log_date ON public.wlt_eod_audit_log USING btree (biz_date, task, started_at DESC);


--
-- Name: idx_fm_client_name; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_fm_client_name ON public.fm_client USING btree (client_name);


--
-- Name: idx_fm_client_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_fm_client_status ON public.fm_client USING btree (status) WHERE ((status)::text = 'A'::text);


--
-- Name: idx_fm_gl_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_fm_gl_type ON public.fm_gl_mast USING btree (gl_code_type, bspl_type);


--
-- Name: idx_gl_batch_acct; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_gl_batch_acct ON public.wlt_gl_batch USING btree (acct_internal_key, post_date);


--
-- Name: idx_gl_batch_gl_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_gl_batch_gl_date ON public.wlt_gl_batch USING btree (gl_code, post_date);


--
-- Name: idx_gl_batch_pending; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_gl_batch_pending ON public.wlt_gl_batch USING btree (post_date) WHERE ((status)::text = 'P'::text);


--
-- Name: idx_gl_batch_ref; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_gl_batch_ref ON public.wlt_gl_batch USING btree (reference);


--
-- Name: idx_group_client; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_group_client ON public.wlt_acct_group USING btree (client_no);


--
-- Name: idx_group_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_group_status ON public.wlt_acct_group USING btree (group_status) WHERE ((group_status)::text = 'A'::text);


--
-- Name: idx_hist_acct_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_hist_acct_date ON ONLY public.wlt_tran_hist USING btree (internal_key, post_date DESC);


--
-- Name: idx_hist_group_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_hist_group_date ON ONLY public.wlt_tran_hist USING btree (group_id, post_date DESC) WHERE (group_id IS NOT NULL);


--
-- Name: idx_hist_ref; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_hist_ref ON ONLY public.wlt_tran_hist USING btree (reference);


--
-- Name: idx_hist_tfr; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_hist_tfr ON ONLY public.wlt_tran_hist USING btree (tran_internal_id, tfr_seq_no);


--
-- Name: idx_kyc_client; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_kyc_client ON public.fm_client_kyc USING btree (client_no);


--
-- Name: idx_kyc_tier; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_kyc_tier ON public.fm_client_kyc USING btree (kyc_tier) WHERE ((status)::text = 'A'::text);


--
-- Name: idx_outbox_agg; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_outbox_agg ON ONLY public.wlt_outbox USING btree (aggregate_type, aggregate_id);


--
-- Name: idx_outbox_dead; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_outbox_dead ON ONLY public.wlt_outbox USING btree (created_at) WHERE ((status)::text = ANY (ARRAY[('FAILED'::character varying)::text, ('DEAD'::character varying)::text]));


--
-- Name: idx_outbox_pending; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_outbox_pending ON ONLY public.wlt_outbox USING btree (event_id) WHERE ((status)::text = 'PENDING'::text);


--
-- Name: idx_period_closed; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_period_closed ON public.wlt_period USING btree (biz_date DESC) WHERE ((status)::text = 'CLOSED'::text);


--
-- Name: idx_rstr_acct_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rstr_acct_active ON public.wlt_restraints USING btree (internal_key, status) WHERE ((internal_key IS NOT NULL) AND ((status)::text = 'A'::text));


--
-- Name: idx_rstr_end_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rstr_end_date ON public.wlt_restraints USING btree (end_date, status) WHERE (((status)::text = 'A'::text) AND (end_date IS NOT NULL));


--
-- Name: idx_rstr_group_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rstr_group_active ON public.wlt_restraints USING btree (group_id, status) WHERE ((group_id IS NOT NULL) AND ((status)::text = 'A'::text));


--
-- Name: idx_sweep_group_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sweep_group_time ON public.wlt_sweep_log USING btree (group_id, created_at DESC);


--
-- Name: idx_sweep_shard_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sweep_shard_time ON public.wlt_sweep_log USING btree (shard_acct_no, created_at DESC);


--
-- Name: idx_wd_acct; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_wd_acct ON public.wlt_withdraw_track USING btree (acct_no, submitted_at DESC);


--
-- Name: idx_wd_ack_overdue; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_wd_ack_overdue ON public.wlt_withdraw_track USING btree (ack_deadline) WHERE ((status)::text = 'SUBMITTED'::text);


--
-- Name: idx_wd_final_overdue; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_wd_final_overdue ON public.wlt_withdraw_track USING btree (final_deadline) WHERE ((status)::text = ANY (ARRAY[('ACKED'::character varying)::text, ('DISBURSING'::character varying)::text]));


--
-- Name: idx_wd_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_wd_status ON public.wlt_withdraw_track USING btree (status) WHERE ((status)::text = ANY (ARRAY[('SUBMITTED'::character varying)::text, ('ACKED'::character varying)::text, ('DISBURSING'::character varying)::text]));


--
-- Name: uk_acct_settlement; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uk_acct_settlement ON public.wlt_acct USING btree (group_id) WHERE ((acct_role)::text = 'SETTLEMENT'::text);


--
-- Name: uk_acct_shard; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uk_acct_shard ON public.wlt_acct USING btree (group_id, shard_index) WHERE ((acct_role)::text = 'SHARD'::text);


--
-- Name: uk_cb_one_default; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uk_cb_one_default ON public.fm_client_banks USING btree (client_no) WHERE (is_default = 1);


--
-- Name: uk_kyc_phone_hash; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uk_kyc_phone_hash ON public.fm_client_kyc USING btree (phone_no_hash) WHERE (phone_no_hash IS NOT NULL);


--
-- Name: fm_client trg_audit_cols; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_audit_cols BEFORE INSERT OR UPDATE ON public.fm_client FOR EACH ROW EXECUTE FUNCTION public.fn_set_audit_columns();


--
-- Name: fm_client_banks trg_audit_cols; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_audit_cols BEFORE INSERT OR UPDATE ON public.fm_client_banks FOR EACH ROW EXECUTE FUNCTION public.fn_set_audit_columns();


--
-- Name: fm_client_contact trg_audit_cols; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_audit_cols BEFORE INSERT OR UPDATE ON public.fm_client_contact FOR EACH ROW EXECUTE FUNCTION public.fn_set_audit_columns();


--
-- Name: fm_currency trg_audit_cols; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_audit_cols BEFORE INSERT OR UPDATE ON public.fm_currency FOR EACH ROW EXECUTE FUNCTION public.fn_set_audit_columns();


--
-- Name: fm_gl_mast trg_audit_cols; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_audit_cols BEFORE INSERT OR UPDATE ON public.fm_gl_mast FOR EACH ROW EXECUTE FUNCTION public.fn_set_audit_columns();


--
-- Name: fm_nos_vos trg_audit_cols; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_audit_cols BEFORE INSERT OR UPDATE ON public.fm_nos_vos FOR EACH ROW EXECUTE FUNCTION public.fn_set_audit_columns();


--
-- Name: wlt_acct trg_audit_cols; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_audit_cols BEFORE INSERT OR UPDATE ON public.wlt_acct FOR EACH ROW EXECUTE FUNCTION public.fn_set_audit_columns();


--
-- Name: wlt_acct_bal trg_audit_cols; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_audit_cols BEFORE INSERT OR UPDATE ON public.wlt_acct_bal FOR EACH ROW EXECUTE FUNCTION public.fn_set_audit_columns();


--
-- Name: wlt_acct_group trg_audit_cols; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_audit_cols BEFORE INSERT OR UPDATE ON public.wlt_acct_group FOR EACH ROW EXECUTE FUNCTION public.fn_set_audit_columns();


--
-- Name: wlt_acct_type trg_audit_cols; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_audit_cols BEFORE INSERT OR UPDATE ON public.wlt_acct_type FOR EACH ROW EXECUTE FUNCTION public.fn_set_audit_columns();


--
-- Name: wlt_api_message trg_audit_cols; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_audit_cols BEFORE INSERT OR UPDATE ON public.wlt_api_message FOR EACH ROW EXECUTE FUNCTION public.fn_set_audit_columns();


--
-- Name: wlt_client_audit_log trg_audit_cols; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_audit_cols BEFORE INSERT OR UPDATE ON public.wlt_client_audit_log FOR EACH ROW EXECUTE FUNCTION public.fn_set_audit_columns();


--
-- Name: fm_client_kyc trg_audit_cols; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_audit_cols BEFORE INSERT OR UPDATE ON public.fm_client_kyc FOR EACH ROW EXECUTE FUNCTION public.fn_set_audit_columns();


--
-- Name: wlt_gl_batch trg_audit_cols; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_audit_cols BEFORE INSERT OR UPDATE ON public.wlt_gl_batch FOR EACH ROW EXECUTE FUNCTION public.fn_set_audit_columns();


--
-- Name: wlt_gl_map trg_audit_cols; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_audit_cols BEFORE INSERT OR UPDATE ON public.wlt_gl_map FOR EACH ROW EXECUTE FUNCTION public.fn_set_audit_columns();


--
-- Name: wlt_nostro_bal trg_audit_cols; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_audit_cols BEFORE INSERT OR UPDATE ON public.wlt_nostro_bal FOR EACH ROW EXECUTE FUNCTION public.fn_set_audit_columns();


--
-- Name: wlt_nostro_link trg_audit_cols; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_audit_cols BEFORE INSERT OR UPDATE ON public.wlt_nostro_link FOR EACH ROW EXECUTE FUNCTION public.fn_set_audit_columns();


--
-- Name: wlt_outbox trg_audit_cols; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_audit_cols BEFORE INSERT OR UPDATE ON public.wlt_outbox FOR EACH ROW EXECUTE FUNCTION public.fn_set_audit_columns();


--
-- Name: wlt_restraints trg_audit_cols; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_audit_cols BEFORE INSERT OR UPDATE ON public.wlt_restraints FOR EACH ROW EXECUTE FUNCTION public.fn_set_audit_columns();


--
-- Name: wlt_sweep_log trg_audit_cols; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_audit_cols BEFORE INSERT OR UPDATE ON public.wlt_sweep_log FOR EACH ROW EXECUTE FUNCTION public.fn_set_audit_columns();


--
-- Name: wlt_tran_def trg_audit_cols; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_audit_cols BEFORE INSERT OR UPDATE ON public.wlt_tran_def FOR EACH ROW EXECUTE FUNCTION public.fn_set_audit_columns();


--
-- Name: wlt_tran_hist trg_audit_cols; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_audit_cols BEFORE INSERT OR UPDATE ON public.wlt_tran_hist FOR EACH ROW EXECUTE FUNCTION public.fn_set_audit_columns();


--
-- Name: wlt_withdraw_track trg_audit_cols; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_audit_cols BEFORE INSERT OR UPDATE ON public.wlt_withdraw_track FOR EACH ROW EXECUTE FUNCTION public.fn_set_audit_columns();


--
-- Name: fm_client_banks trg_audit_fm_client_bk; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_audit_fm_client_bk AFTER INSERT OR DELETE OR UPDATE ON public.fm_client_banks FOR EACH ROW EXECUTE FUNCTION public.fn_audit_client_change();


--
-- Name: fm_client_kyc trg_audit_fm_kyc; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_audit_fm_kyc AFTER INSERT OR DELETE OR UPDATE ON public.fm_client_kyc FOR EACH ROW EXECUTE FUNCTION public.fn_audit_client_change();


--
-- Name: wlt_gl_batch trg_batch_balanced; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER trg_batch_balanced AFTER INSERT ON public.wlt_gl_batch DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.fn_assert_batch_balanced();


--
-- Name: wlt_gl_batch trg_freeze_batch; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_freeze_batch BEFORE INSERT OR DELETE OR UPDATE ON public.wlt_gl_batch FOR EACH ROW EXECUTE FUNCTION public.fn_freeze_closed_period();


--
-- Name: wlt_tran_hist trg_freeze_hist; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_freeze_hist BEFORE INSERT OR DELETE OR UPDATE ON public.wlt_tran_hist FOR EACH ROW EXECUTE FUNCTION public.fn_freeze_closed_period();


--
-- Name: wlt_acct fk_acct_fm_ccy; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.wlt_acct
    ADD CONSTRAINT fk_acct_fm_ccy FOREIGN KEY (ccy) REFERENCES public.fm_currency(ccy);


--
-- Name: wlt_acct fk_acct_fm_client; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.wlt_acct
    ADD CONSTRAINT fk_acct_fm_client FOREIGN KEY (client_no) REFERENCES public.fm_client(client_no);


--
-- Name: wlt_acct fk_acct_group; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.wlt_acct
    ADD CONSTRAINT fk_acct_group FOREIGN KEY (group_id) REFERENCES public.wlt_acct_group(group_id);


--
-- Name: wlt_acct fk_acct_type; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.wlt_acct
    ADD CONSTRAINT fk_acct_type FOREIGN KEY (acct_type) REFERENCES public.wlt_acct_type(acct_type);


--
-- Name: wlt_acct_type fk_at_gl; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.wlt_acct_type
    ADD CONSTRAINT fk_at_gl FOREIGN KEY (gl_code_liab) REFERENCES public.fm_gl_mast(gl_code);


--
-- Name: wlt_acct_bal fk_bal_acct; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.wlt_acct_bal
    ADD CONSTRAINT fk_bal_acct FOREIGN KEY (internal_key) REFERENCES public.wlt_acct(internal_key);


--
-- Name: fm_client_banks fk_cb_client; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fm_client_banks
    ADD CONSTRAINT fk_cb_client FOREIGN KEY (client_no) REFERENCES public.fm_client(client_no);


--
-- Name: fm_client_contact fk_ct_client; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fm_client_contact
    ADD CONSTRAINT fk_ct_client FOREIGN KEY (client_no) REFERENCES public.fm_client(client_no);


--
-- Name: wlt_tran_def fk_def_fee_gl; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.wlt_tran_def
    ADD CONSTRAINT fk_def_fee_gl FOREIGN KEY (fee_gl_code) REFERENCES public.fm_gl_mast(gl_code);


--
-- Name: wlt_tran_def fk_def_vat_gl; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.wlt_tran_def
    ADD CONSTRAINT fk_def_vat_gl FOREIGN KEY (vat_gl_code) REFERENCES public.fm_gl_mast(gl_code);


--
-- Name: wlt_gl_batch fk_gl_batch_ccy; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.wlt_gl_batch
    ADD CONSTRAINT fk_gl_batch_ccy FOREIGN KEY (ccy) REFERENCES public.fm_currency(ccy);


--
-- Name: wlt_gl_batch fk_gl_batch_gl; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.wlt_gl_batch
    ADD CONSTRAINT fk_gl_batch_gl FOREIGN KEY (gl_code) REFERENCES public.fm_gl_mast(gl_code);


--
-- Name: fm_gl_mast fk_gl_parent; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fm_gl_mast
    ADD CONSTRAINT fk_gl_parent FOREIGN KEY (control_gl_code) REFERENCES public.fm_gl_mast(gl_code);


--
-- Name: wlt_gl_map fk_glmap_gl; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.wlt_gl_map
    ADD CONSTRAINT fk_glmap_gl FOREIGN KEY (gl_code) REFERENCES public.fm_gl_mast(gl_code);


--
-- Name: wlt_gl_map fk_glmap_type; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.wlt_gl_map
    ADD CONSTRAINT fk_glmap_type FOREIGN KEY (acct_type) REFERENCES public.wlt_acct_type(acct_type);


--
-- Name: wlt_acct_group fk_group_client; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.wlt_acct_group
    ADD CONSTRAINT fk_group_client FOREIGN KEY (client_no) REFERENCES public.fm_client(client_no);


--
-- Name: wlt_acct_group fk_group_settlement; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.wlt_acct_group
    ADD CONSTRAINT fk_group_settlement FOREIGN KEY (settlement_acct_no) REFERENCES public.wlt_acct(acct_no) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: fm_client_kyc fk_kyc_client; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fm_client_kyc
    ADD CONSTRAINT fk_kyc_client FOREIGN KEY (client_no) REFERENCES public.fm_client(client_no);


--
-- Name: wlt_nostro_bal fk_nb_link; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.wlt_nostro_bal
    ADD CONSTRAINT fk_nb_link FOREIGN KEY (nostro_id) REFERENCES public.wlt_nostro_link(nostro_id);


--
-- Name: wlt_nostro_link fk_nl_fm; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.wlt_nostro_link
    ADD CONSTRAINT fk_nl_fm FOREIGN KEY (nos_vos_no) REFERENCES public.fm_nos_vos(nos_vos_no);


--
-- Name: wlt_nostro_link fk_nl_gl; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.wlt_nostro_link
    ADD CONSTRAINT fk_nl_gl FOREIGN KEY (gl_code) REFERENCES public.fm_gl_mast(gl_code);


--
-- Name: fm_nos_vos fk_nos_ccy; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fm_nos_vos
    ADD CONSTRAINT fk_nos_ccy FOREIGN KEY (ccy) REFERENCES public.fm_currency(ccy);


--
-- Name: fm_nos_vos fk_nos_gl; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fm_nos_vos
    ADD CONSTRAINT fk_nos_gl FOREIGN KEY (gl_code) REFERENCES public.fm_gl_mast(gl_code);


--
-- Name: wlt_restraints fk_rstr_acct; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.wlt_restraints
    ADD CONSTRAINT fk_rstr_acct FOREIGN KEY (internal_key) REFERENCES public.wlt_acct(internal_key);


--
-- Name: wlt_restraints fk_rstr_group; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.wlt_restraints
    ADD CONSTRAINT fk_rstr_group FOREIGN KEY (group_id) REFERENCES public.wlt_acct_group(group_id);


--
-- Name: wlt_sweep_log fk_sweep_group; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.wlt_sweep_log
    ADD CONSTRAINT fk_sweep_group FOREIGN KEY (group_id) REFERENCES public.wlt_acct_group(group_id);


--
-- Name: SCHEMA public; Type: ACL; Schema: -; Owner: -
--

GRANT USAGE ON SCHEMA public TO wallet_app;
GRANT USAGE ON SCHEMA public TO wallet_pii_ro;


--
-- Name: FUNCTION activate_hot_wallet(p_group_id character varying, p_shard_count smallint, p_channel character varying, p_actor character varying); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.activate_hot_wallet(p_group_id character varying, p_shard_count smallint, p_channel character varying, p_actor character varying) TO wallet_app;


--
-- Name: FUNCTION add_restraint(p_acct_no character varying, p_type character varying, p_purpose character varying, p_pledged_amt numeric, p_start_date date, p_end_date date, p_narrative character varying, p_reference_doc character varying, p_actor character varying); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.add_restraint(p_acct_no character varying, p_type character varying, p_purpose character varying, p_pledged_amt numeric, p_start_date date, p_end_date date, p_narrative character varying, p_reference_doc character varying, p_actor character varying) TO wallet_app;


--
-- Name: FUNCTION create_client(p_client_name character varying, p_client_type character varying, p_global_id character varying, p_global_id_type character varying, p_country_loc character varying, p_country_citizen character varying, p_surname character varying, p_given_name character varying, p_birth_date date, p_sex character varying, p_actor character varying); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.create_client(p_client_name character varying, p_client_type character varying, p_global_id character varying, p_global_id_type character varying, p_country_loc character varying, p_country_citizen character varying, p_surname character varying, p_given_name character varying, p_birth_date date, p_sex character varying, p_actor character varying) TO wallet_app;


--
-- Name: FUNCTION onboard_client(...); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.onboard_client(p_client_name character varying, p_client_type character varying, p_phone character varying, p_global_id character varying, p_global_id_type character varying, p_email character varying, p_country_loc character varying, p_country_citizen character varying, p_acct_type character varying, p_ccy character varying, p_birth_date date, p_sex character varying, p_date_issue date, p_expire_date date, p_place_issue character varying, p_extra_data jsonb, p_actor character varying) TO wallet_app;


--
-- Name: FUNCTION update_kyc(...); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.update_kyc(p_client_no character varying, p_kyc_tier character varying, p_status character varying, p_risk_level character varying, p_ekyc_provider character varying, p_ekyc_ref character varying, p_face_match_score numeric, p_liveness_result character varying, p_extra_data jsonb, p_actor character varying) TO wallet_app;


--
-- Name: PROCEDURE eod_close_period(IN p_biz_date date); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON PROCEDURE public.eod_close_period(IN p_biz_date date) TO wallet_app;


--
-- Name: PROCEDURE eod_expire_restraints(IN p_biz_date date); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON PROCEDURE public.eod_expire_restraints(IN p_biz_date date) TO wallet_eod;


--
-- Name: PROCEDURE eod_gl_feed_post(IN p_biz_date date, IN p_step bigint); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON PROCEDURE public.eod_gl_feed_post(IN p_biz_date date, IN p_step bigint) TO wallet_app;


--
-- Name: FUNCTION eod_log(p_biz_date date, p_task character varying, p_status character varying, p_rows bigint, p_started timestamp with time zone, p_message text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.eod_log(p_biz_date date, p_task character varying, p_status character varying, p_rows bigint, p_started timestamp with time zone, p_message text) TO wallet_app;
GRANT ALL ON FUNCTION public.eod_log(p_biz_date date, p_task character varying, p_status character varying, p_rows bigint, p_started timestamp with time zone, p_message text) TO wallet_eod;


--
-- Name: PROCEDURE eod_mark_failed(IN p_biz_date date, IN p_task character varying, IN p_message text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON PROCEDURE public.eod_mark_failed(IN p_biz_date date, IN p_task character varying, IN p_message text) TO wallet_eod;


--
-- Name: PROCEDURE eod_prev_day_roll(IN p_biz_date date, IN p_step bigint); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON PROCEDURE public.eod_prev_day_roll(IN p_biz_date date, IN p_step bigint) TO wallet_eod;


--
-- Name: PROCEDURE eod_snapshot(IN p_biz_date date, IN p_step bigint); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON PROCEDURE public.eod_snapshot(IN p_biz_date date, IN p_step bigint) TO wallet_eod;


--
-- Name: PROCEDURE eod_trial_balance(IN p_biz_date date); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON PROCEDURE public.eod_trial_balance(IN p_biz_date date) TO wallet_eod;


--
-- Name: FUNCTION eod_verify_chain(p_ccy character varying, p_from date, p_to date); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.eod_verify_chain(p_ccy character varying, p_from date, p_to date) TO wallet_app;
GRANT ALL ON FUNCTION public.eod_verify_chain(p_ccy character varying, p_from date, p_to date) TO wallet_eod;


--
-- Name: FUNCTION fn_period_closed_through(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.fn_period_closed_through() TO wallet_app;


--
-- Name: FUNCTION fn_validate_metadata(p_metadata jsonb); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.fn_validate_metadata(p_metadata jsonb) TO wallet_app;


--
-- Name: FUNCTION link_client_bank(p_client_no character varying, p_bank_code character varying, p_acct_no character varying, p_bank_name character varying, p_acct_holder_name character varying, p_is_default boolean, p_actor character varying); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.link_client_bank(p_client_no character varying, p_bank_code character varying, p_acct_no character varying, p_bank_name character varying, p_acct_holder_name character varying, p_is_default boolean, p_actor character varying) TO wallet_app;


--
-- Name: FUNCTION mark_withdraw_acked(p_ext_payout_ref character varying, p_treasury_batch_id character varying, p_channel character varying, p_actor character varying); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.mark_withdraw_acked(p_ext_payout_ref character varying, p_treasury_batch_id character varying, p_channel character varying, p_actor character varying) TO wallet_app;


--
-- Name: FUNCTION mark_withdraw_completed(p_ext_payout_ref character varying, p_napas_ref character varying, p_channel character varying, p_actor character varying); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.mark_withdraw_completed(p_ext_payout_ref character varying, p_napas_ref character varying, p_channel character varying, p_actor character varying) TO wallet_app;


--
-- Name: FUNCTION mark_withdraw_disbursing(p_ext_payout_ref character varying, p_channel character varying, p_actor character varying); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.mark_withdraw_disbursing(p_ext_payout_ref character varying, p_channel character varying, p_actor character varying) TO wallet_app;


--
-- Name: FUNCTION open_account(p_client_no character varying, p_acct_type character varying, p_ccy character varying, p_actor character varying); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.open_account(p_client_no character varying, p_acct_type character varying, p_ccy character varying, p_actor character varying) TO wallet_app;


--
-- Name: FUNCTION post_topup(p_acct_no character varying, p_amount numeric, p_reference character varying, p_metadata jsonb, p_channel character varying, p_actor character varying); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.post_topup(p_acct_no character varying, p_amount numeric, p_reference character varying, p_metadata jsonb, p_channel character varying, p_actor character varying) TO wallet_app;


--
-- Name: FUNCTION post_transfer(p_from_acct_no character varying, p_to_acct_no character varying, p_amount numeric, p_reference character varying, p_tran_type character varying, p_metadata jsonb, p_channel character varying, p_actor character varying); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.post_transfer(p_from_acct_no character varying, p_to_acct_no character varying, p_amount numeric, p_reference character varying, p_tran_type character varying, p_metadata jsonb, p_channel character varying, p_actor character varying) TO wallet_app;


--
-- Name: FUNCTION post_withdraw(p_acct_no character varying, p_amount numeric, p_reference character varying, p_ext_payout_ref character varying, p_beneficiary_bank character varying, p_beneficiary_acct character varying, p_metadata jsonb, p_channel character varying, p_actor character varying); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.post_withdraw(p_acct_no character varying, p_amount numeric, p_reference character varying, p_ext_payout_ref character varying, p_beneficiary_bank character varying, p_beneficiary_acct character varying, p_metadata jsonb, p_channel character varying, p_actor character varying) TO wallet_app;


--
-- Name: FUNCTION post_withdraw_reversal(p_ext_payout_ref character varying, p_fail_code character varying, p_fail_reason character varying, p_initiator character varying, p_channel character varying, p_actor character varying); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.post_withdraw_reversal(p_ext_payout_ref character varying, p_fail_code character varying, p_fail_reason character varying, p_initiator character varying, p_channel character varying, p_actor character varying) TO wallet_app;


--
-- Name: FUNCTION release_restraint(p_restraint_id bigint, p_reason character varying, p_actor character varying); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.release_restraint(p_restraint_id bigint, p_reason character varying, p_actor character varying) TO wallet_app;


--
-- Name: PROCEDURE run_eod(IN p_biz_date date); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON PROCEDURE public.run_eod(IN p_biz_date date) TO wallet_eod;


--
-- Name: FUNCTION set_default_client_bank(p_client_no character varying, p_link_id bigint, p_actor character varying); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.set_default_client_bank(p_client_no character varying, p_link_id bigint, p_actor character varying) TO wallet_app;


--
-- Name: FUNCTION update_account_status(p_acct_no character varying, p_status character varying, p_actor character varying); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.update_account_status(p_acct_no character varying, p_status character varying, p_actor character varying) TO wallet_app;


--
-- Name: FUNCTION update_client(p_client_no character varying, p_client_name character varying, p_status character varying, p_country_loc character varying, p_country_citizen character varying, p_surname character varying, p_given_name character varying, p_birth_date date, p_sex character varying, p_actor character varying); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.update_client(p_client_no character varying, p_client_name character varying, p_status character varying, p_country_loc character varying, p_country_citizen character varying, p_surname character varying, p_given_name character varying, p_birth_date date, p_sex character varying, p_actor character varying) TO wallet_app;


--
-- Name: TABLE fm_client; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.fm_client TO wallet_pii_ro;


--
-- Name: COLUMN fm_client.client_no; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(client_no) ON TABLE public.fm_client TO wallet_app;


--
-- Name: COLUMN fm_client.client_type; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(client_type) ON TABLE public.fm_client TO wallet_app;


--
-- Name: COLUMN fm_client.client_grp; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(client_grp) ON TABLE public.fm_client TO wallet_app;


--
-- Name: COLUMN fm_client.acct_exec; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(acct_exec) ON TABLE public.fm_client TO wallet_app;


--
-- Name: COLUMN fm_client.country_loc; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(country_loc) ON TABLE public.fm_client TO wallet_app;


--
-- Name: COLUMN fm_client.country_citizen; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(country_citizen) ON TABLE public.fm_client TO wallet_app;


--
-- Name: COLUMN fm_client.status; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(status) ON TABLE public.fm_client TO wallet_app;


--
-- Name: TABLE fm_client_banks; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.fm_client_banks TO wallet_pii_ro;


--
-- Name: TABLE fm_client_contact; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.fm_client_contact TO wallet_pii_ro;


--
-- Name: TABLE fm_currency; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.fm_currency TO wallet_app;
GRANT SELECT ON TABLE public.fm_currency TO wallet_pii_ro;
GRANT SELECT ON TABLE public.fm_currency TO wallet_eod;


--
-- Name: TABLE fm_gl_mast; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.fm_gl_mast TO wallet_app;
GRANT SELECT ON TABLE public.fm_gl_mast TO wallet_pii_ro;
GRANT SELECT ON TABLE public.fm_gl_mast TO wallet_eod;


--
-- Name: TABLE fm_nos_vos; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.fm_nos_vos TO wallet_app;
GRANT SELECT ON TABLE public.fm_nos_vos TO wallet_pii_ro;


--
-- Name: SEQUENCE seq_acct_no; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.seq_acct_no TO wallet_app;


--
-- Name: SEQUENCE seq_tfr; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.seq_tfr TO wallet_app;


--
-- Name: TABLE fm_client_kyc; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.fm_client_kyc TO wallet_pii_ro;


--
-- Name: TABLE v_client_masked; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.v_client_masked TO wallet_app;
GRANT SELECT ON TABLE public.v_client_masked TO wallet_pii_ro;


--
-- Name: TABLE v_kyc_masked; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.v_kyc_masked TO wallet_app;
GRANT SELECT ON TABLE public.v_kyc_masked TO wallet_pii_ro;


--
-- Name: TABLE wlt_acct; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,UPDATE ON TABLE public.wlt_acct TO wallet_app;
GRANT SELECT ON TABLE public.wlt_acct TO wallet_pii_ro;
GRANT SELECT,UPDATE ON TABLE public.wlt_acct TO wallet_eod;


--
-- Name: TABLE wlt_restraints; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,UPDATE ON TABLE public.wlt_restraints TO wallet_app;
GRANT SELECT ON TABLE public.wlt_restraints TO wallet_pii_ro;
GRANT SELECT,UPDATE ON TABLE public.wlt_restraints TO wallet_eod;


--
-- Name: TABLE v_wlt_active_restraints_effective; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.v_wlt_active_restraints_effective TO wallet_app;
GRANT SELECT ON TABLE public.v_wlt_active_restraints_effective TO wallet_pii_ro;


--
-- Name: TABLE wlt_acct_group; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.wlt_acct_group TO wallet_app;
GRANT SELECT ON TABLE public.wlt_acct_group TO wallet_pii_ro;
GRANT SELECT ON TABLE public.wlt_acct_group TO wallet_eod;


--
-- Name: TABLE v_wlt_group_balance; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.v_wlt_group_balance TO wallet_app;
GRANT SELECT ON TABLE public.v_wlt_group_balance TO wallet_pii_ro;


--
-- Name: TABLE wlt_acct_bal; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,UPDATE ON TABLE public.wlt_acct_bal TO wallet_app;
GRANT SELECT ON TABLE public.wlt_acct_bal TO wallet_pii_ro;
GRANT SELECT,INSERT,UPDATE ON TABLE public.wlt_acct_bal TO wallet_eod;


--
-- Name: TABLE wlt_acct_type; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.wlt_acct_type TO wallet_app;
GRANT SELECT ON TABLE public.wlt_acct_type TO wallet_pii_ro;
GRANT SELECT ON TABLE public.wlt_acct_type TO wallet_eod;


--
-- Name: TABLE wlt_api_message; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,UPDATE ON TABLE public.wlt_api_message TO wallet_app;
GRANT SELECT ON TABLE public.wlt_api_message TO wallet_pii_ro;


--
-- Name: TABLE wlt_client_audit_log; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.wlt_client_audit_log TO wallet_pii_ro;


--
-- Name: TABLE wlt_eod_audit_log; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT ON TABLE public.wlt_eod_audit_log TO wallet_app;
GRANT SELECT,INSERT ON TABLE public.wlt_eod_audit_log TO wallet_eod;


--
-- Name: TABLE wlt_eod_run; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,UPDATE ON TABLE public.wlt_eod_run TO wallet_app;
GRANT SELECT,INSERT,UPDATE ON TABLE public.wlt_eod_run TO wallet_eod;


--
-- Name: TABLE wlt_gl_batch; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,UPDATE ON TABLE public.wlt_gl_batch TO wallet_app;
GRANT SELECT ON TABLE public.wlt_gl_batch TO wallet_pii_ro;
GRANT SELECT ON TABLE public.wlt_gl_batch TO wallet_eod;


--
-- Name: COLUMN wlt_gl_batch.status; Type: ACL; Schema: public; Owner: -
--

GRANT UPDATE(status) ON TABLE public.wlt_gl_batch TO wallet_app;


--
-- Name: COLUMN wlt_gl_batch.time_stamp; Type: ACL; Schema: public; Owner: -
--

GRANT UPDATE(time_stamp) ON TABLE public.wlt_gl_batch TO wallet_app;


--
-- Name: TABLE wlt_gl_map; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.wlt_gl_map TO wallet_app;
GRANT SELECT ON TABLE public.wlt_gl_map TO wallet_pii_ro;
GRANT SELECT ON TABLE public.wlt_gl_map TO wallet_eod;


--
-- Name: TABLE wlt_nostro_bal; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,UPDATE ON TABLE public.wlt_nostro_bal TO wallet_app;
GRANT SELECT ON TABLE public.wlt_nostro_bal TO wallet_pii_ro;


--
-- Name: TABLE wlt_nostro_link; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.wlt_nostro_link TO wallet_app;
GRANT SELECT ON TABLE public.wlt_nostro_link TO wallet_pii_ro;


--
-- Name: TABLE wlt_outbox; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,UPDATE ON TABLE public.wlt_outbox TO wallet_app;
GRANT SELECT ON TABLE public.wlt_outbox TO wallet_pii_ro;


--
-- Name: TABLE wlt_period; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,UPDATE ON TABLE public.wlt_period TO wallet_app;


--
-- Name: TABLE wlt_sweep_log; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,UPDATE ON TABLE public.wlt_sweep_log TO wallet_app;
GRANT SELECT ON TABLE public.wlt_sweep_log TO wallet_pii_ro;


--
-- Name: TABLE wlt_tran_def; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.wlt_tran_def TO wallet_app;
GRANT SELECT ON TABLE public.wlt_tran_def TO wallet_pii_ro;
GRANT SELECT ON TABLE public.wlt_tran_def TO wallet_eod;


--
-- Name: TABLE wlt_tran_hist; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,UPDATE ON TABLE public.wlt_tran_hist TO wallet_app;
GRANT SELECT ON TABLE public.wlt_tran_hist TO wallet_pii_ro;
GRANT SELECT ON TABLE public.wlt_tran_hist TO wallet_eod;


--
-- Name: TABLE wlt_trial_balance; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.wlt_trial_balance TO wallet_app;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.wlt_trial_balance TO wallet_eod;


--
-- Name: TABLE wlt_trial_balance_proof; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.wlt_trial_balance_proof TO wallet_app;
GRANT SELECT,INSERT,UPDATE ON TABLE public.wlt_trial_balance_proof TO wallet_eod;


--
-- Name: TABLE wlt_withdraw_track; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,UPDATE ON TABLE public.wlt_withdraw_track TO wallet_app;
GRANT SELECT ON TABLE public.wlt_withdraw_track TO wallet_pii_ro;


--
-- PostgreSQL database dump complete
--

\unrestrict eNeiC0gZxcJL2tzxYid3O3nPahNN9QsS0H8w26RB3m1uj8FlOR0wtmZSdw1NR1v

