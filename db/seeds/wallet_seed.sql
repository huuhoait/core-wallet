-- =============================================================================
-- wallet_seed.sql — Seed data, helper procedures, and bulk test-data generator
-- =============================================================================
-- Target:  PostgreSQL 17+
-- Companion: wallet_DLD.md v1.6
-- Run order:
--   1. Apply wallet_DLD.md DDL (FM_*, WLT_*, sequences, partitions)
--   2. Run this file end-to-end (or sections as labeled)
--
-- Idempotency:
--   - DDL-side seeds use ON CONFLICT DO NOTHING (safe to re-run)
--   - Functions use CREATE OR REPLACE
--   - Bulk generator at §4 is destructive on retry; gate with WHERE NOT EXISTS
-- =============================================================================


-- =============================================================================
-- §1. Reference seed — WLT_ACCT_TYPE
-- =============================================================================
-- Placed in the seed file (not DDL) because the values can be tuned per product
-- policy without requiring a schema change.
INSERT INTO WLT_ACCT_TYPE
  (ACCT_TYPE, ACCT_TYPE_DESC,    GL_CODE_LIAB, PROD_ID, DAILY_LIMIT,  MONTHLY_LIMIT, INT_BEARING, STATUS)
VALUES
  ('CONSUMER','Consumer wallet','201.01.001','WLT_C',   20000000,  100000000, 'N','A'),
  ('MERCHANT','Merchant wallet','201.02.001','WLT_M',  500000000, 5000000000, 'N','A')
ON CONFLICT (ACCT_TYPE) DO NOTHING;


-- =============================================================================
-- §2. Sequences for procedures
-- =============================================================================
-- seq_client: generates CLIENT_NO (format C + 10 digits). High start value avoids
--             collisions with master data already imported from T24 / legacy.
CREATE SEQUENCE IF NOT EXISTS seq_client AS BIGINT START 1000000000 CACHE 100;

-- seq_acct_no: generates wallet number (format 9701 + 10 digits). 9701 is an example wallet BIN.
CREATE SEQUENCE IF NOT EXISTS seq_acct_no AS BIGINT START 1 CACHE 100;


-- =============================================================================
-- §3. Helper functions
-- =============================================================================

-- -----------------------------------------------------------------------------
-- fn_create_client: Create FM_CLIENT + FM_CLIENT_KYC (surname/given_name →
--                   extra_data; global_id/sex → flat columns — US-1.15) in a
--                   single transaction.
-- Returns: CLIENT_NO
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_create_client(
  p_client_name   VARCHAR,
  p_global_id     VARCHAR,
  p_phone         VARCHAR,
  p_email         VARCHAR DEFAULT NULL,
  p_client_type   VARCHAR DEFAULT 'IND',
  p_kyc_tier      VARCHAR DEFAULT '1'
) RETURNS VARCHAR
LANGUAGE plpgsql AS $$
DECLARE
  v_client_no VARCHAR(48);
  v_key       TEXT := 'wallet-test-key';
BEGIN
  v_client_no := 'C' || LPAD(nextval('seq_client')::text, 10, '0');

  INSERT INTO FM_CLIENT
    (CLIENT_NO, GLOBAL_ID, GLOBAL_ID_TYPE, CLIENT_NAME,
     CLIENT_TYPE, COUNTRY_LOC, COUNTRY_CITIZEN, STATUS)
  VALUES
    (v_client_no, p_global_id, 'CCCD', p_client_name,
     p_client_type, 'VN', 'VN', 'A');

  -- PII at rest: phone/email encrypted (pgp_sym_encrypt), phone also SHA-256
  -- hashed for the unique index uk_kyc_phone_hash. Test key is fixed — posting
  -- tests never decrypt phone, so this matches wallet_testdata_10.sql.
  -- surname/given_name/resident_status live in extra_data; identity doc + sex are
  -- flat real columns (global_id/global_id_type/sex — US-1.15 + identifiers flatten).
  INSERT INTO FM_CLIENT_KYC
    (CLIENT_NO, PHONE_NO_ENC, PHONE_NO_HASH, EMAIL_ENC, KYC_TIER, STATUS, EXTRA_DATA,
     GLOBAL_ID, GLOBAL_ID_TYPE, SEX)
  VALUES
    (v_client_no,
     pgp_sym_encrypt(p_phone, v_key),
     digest(p_phone, 'sha256'),
     CASE WHEN p_email IS NULL THEN NULL ELSE pgp_sym_encrypt(p_email, v_key) END,
     p_kyc_tier, 'A',
     CASE WHEN p_client_type = 'IND'
          THEN jsonb_build_object('surname', split_part(p_client_name, ' ', 1),
                                  'given_name', split_part(p_client_name, ' ', -1),
                                  'resident_status', 'R')
          ELSE '{}'::jsonb END,
     p_global_id, 'CCCD',
     CASE WHEN p_client_type = 'IND' THEN 'M' ELSE NULL END);

  RETURN v_client_no;
END $$;


-- -----------------------------------------------------------------------------
-- fn_open_wallet: Open a wallet with an optional initial fund balance.
-- Returns: (internal_key, acct_no)
--
-- Note: when p_initial_fund > 0 we do NOT create a full GL batch (WLT_GL_BATCH) —
-- we only set the balance + a single "OPEN" history row so the test data can
-- transact immediately. Production must go through the Posting Engine to
-- balance the GL against nostro funding.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_open_wallet(
  p_client_no    VARCHAR,
  p_acct_type    VARCHAR DEFAULT 'CONSUMER',
  p_initial_fund NUMERIC DEFAULT 0,
  p_ccy          VARCHAR DEFAULT 'VND'
) RETURNS TABLE (internal_key BIGINT, acct_no VARCHAR)
LANGUAGE plpgsql AS $$
DECLARE
  v_acct_no  VARCHAR(20);
  v_intkey   BIGINT;
BEGIN
  v_acct_no := '9701' || LPAD(nextval('seq_acct_no')::text, 10, '0');

  -- CALC_BAL is a generated stored column (= ACTUAL_BAL - TOTAL_RESTRAINED_AMT) → not in target list.
  -- Open with zero balance; fund through post_topup so the opening balance carries a full
  -- double-entry (ledger TOPUP + GL DR 101.02.001 / CR wallet liability) and reconciles.
  -- Never set ACTUAL_BAL directly — that injects off-ledger balance with no contra GL.
  INSERT INTO WLT_ACCT
    (ACCT_NO, CLIENT_NO, ACCT_TYPE, CCY, ACCT_STATUS, ACTUAL_BAL)
  VALUES
    (v_acct_no, p_client_no, p_acct_type, p_ccy, 'A', 0)
  RETURNING WLT_ACCT.INTERNAL_KEY INTO v_intkey;

  IF p_initial_fund > 0 THEN
    PERFORM post_topup(v_acct_no, p_initial_fund,
                       'SEED-OPEN-' || v_acct_no, '{}'::jsonb, 'TREASURY', 'seed');
  END IF;

  RETURN QUERY SELECT v_intkey, v_acct_no;
END $$;


-- =============================================================================
-- §4. Bulk generator for load testing
-- =============================================================================
-- Create N consumer wallets with tiered balances. Default N=100_000.
-- Run manually when test data needs to be re-seeded.
--
-- Estimated performance: ~30s for 100K wallets on a PG17 single node (batched commits).
-- =============================================================================

-- Wrapped in a DO block to scope the v_n variable
DO $$
DECLARE
  v_n             INT := 100000;
  v_client_no     VARCHAR(48);
  v_fund          NUMERIC;
  i               INT;
BEGIN
  FOR i IN 1..v_n LOOP
    v_client_no := fn_create_client(
      'TestUser_' || i,
      LPAD(i::text, 12, '0'),
      '0' || LPAD((900000000 + i)::text, 9, '0'),
      'test' || i || '@loadtest.local'
    );

    v_fund := CASE
      WHEN random() < 0.70 THEN (random() *  9000000 +   1000000)::NUMERIC(18,2)
      WHEN random() < 0.95 THEN (random() * 90000000 +  10000000)::NUMERIC(18,2)
      ELSE                       (random() *900000000 + 100000000)::NUMERIC(18,2)
    END;

    PERFORM fn_open_wallet(v_client_no, 'CONSUMER', v_fund);

    IF i % 10000 = 0 THEN
      RAISE NOTICE 'Created % / % wallets', i, v_n;
    END IF;
  END LOOP;
END $$;


-- =============================================================================
-- §5. Verification queries
-- =============================================================================
-- Run after bulk-gen to verify the dataset before load testing.

-- Wallet count + total balance per ACCT_TYPE
SELECT ACCT_TYPE, COUNT(*) AS wallet_count, SUM(ACTUAL_BAL) AS total_balance
FROM WLT_ACCT
GROUP BY ACCT_TYPE;

-- Balance tiers to verify the 70/25/5 distribution
SELECT
  CASE
    WHEN ACTUAL_BAL <  10000000 THEN 'tier1_small (1M-10M)'
    WHEN ACTUAL_BAL < 100000000 THEN 'tier2_mid   (10M-100M)'
    ELSE                              'tier3_large (>100M)'
  END AS tier,
  COUNT(*) AS cnt
FROM WLT_ACCT
GROUP BY tier
ORDER BY tier;

-- Verify partition distribution for WLT_ACCT_BAL (hash spread)
SELECT relname, n_live_tup
FROM pg_stat_user_tables
WHERE relname LIKE 'wlt_acct_bal_%'
ORDER BY relname;

-- Verify FK integrity (each query must return 0 rows)
SELECT 'orphan WLT_ACCT.CLIENT_NO' AS check, COUNT(*) FROM WLT_ACCT a
WHERE NOT EXISTS (SELECT 1 FROM FM_CLIENT c WHERE c.CLIENT_NO = a.CLIENT_NO)
UNION ALL
SELECT 'orphan FM_CLIENT_KYC.CLIENT_NO', COUNT(*) FROM FM_CLIENT_KYC k
WHERE NOT EXISTS (SELECT 1 FROM FM_CLIENT c WHERE c.CLIENT_NO = k.CLIENT_NO);


-- =============================================================================
-- §6. Reset helpers (DESTRUCTIVE — test environments only)
-- =============================================================================
-- DO NOT run in production. Wrapped in a function to avoid accidental execution.

CREATE OR REPLACE FUNCTION fn_reset_test_data() RETURNS VOID
LANGUAGE plpgsql AS $$
BEGIN
  IF current_database() NOT LIKE '%test%' AND current_database() NOT LIKE '%dev%' THEN
    RAISE EXCEPTION 'Refuse to reset: DB name does not match *test* or *dev* (current=%)', current_database();
  END IF;

  TRUNCATE
    WLT_GL_BATCH,
    WLT_TRAN_HIST,
    WLT_MEMO_TRAN,
    WLT_API_MESSAGE,
    WLT_ACCT_BAL,
    WLT_ACCT,
    FM_CLIENT_KYC,
    FM_CLIENT
  CASCADE;

  -- Reset sequences back to their start value
  ALTER SEQUENCE seq_client    RESTART WITH 1000000000;
  ALTER SEQUENCE seq_acct_no   RESTART WITH 1;
  ALTER SEQUENCE seq_tfr       RESTART WITH 1;

  RAISE NOTICE 'Test data reset complete';
END $$;

-- To run: SELECT fn_reset_test_data();
