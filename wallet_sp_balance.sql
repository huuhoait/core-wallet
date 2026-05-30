-- =============================================================================
-- wallet_sp_balance.sql — Balance-query stored functions (Get Balance §9)
-- =============================================================================
-- Target:    PostgreSQL 17+
-- Spec:      finance_transaction.md §9 (Get Balance)
-- Depends:   WLT_ACCT, WLT_ACCT_BAL, WLT_RESTRAINTS
-- Read-only: STABLE functions, no writes (BAL-05: no OLTP audit row).
--
-- Functions:
--   get_balance(acct_no)              — customer realtime view (§9.3.1)
--   get_balance_ops(acct_no)          — ops/internal full view (§9.3.2)
--   get_balance_asof(acct_no, date)   — historical snapshot (§9.3.3)
--   get_balance_batch(acct_no[])      — batch, max 100 (§9.3.4)
--
-- Field notes (live schema, finance_transaction.md §9.2):
--   available_bal = GREATEST(CALC_BAL, 0)         -- BAL-03 clamp ≥ 0
--   CALC_BAL      = ACTUAL_BAL - TOTAL_RESTRAINED_AMT  (generated column)
--   ledger_bal    = ACTUAL_BAL (no separate LEDGER_BAL column; = actual)
-- Not-found → empty result set (Go layer maps to 404 ACCT_NOT_FOUND).
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- get_balance — customer realtime view (§9.3.1) with AML masking (BAL-02)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_balance(p_acct_no VARCHAR)
RETURNS TABLE (
  acct_no         VARCHAR,
  ccy             VARCHAR,
  acct_status     VARCHAR,
  actual_bal      NUMERIC,
  available_bal   NUMERIC,
  restrained_amt  NUMERIC,
  masked          BOOLEAN,
  message         TEXT,
  last_tran_date  TIMESTAMPTZ,
  as_of           TIMESTAMPTZ
)
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

-- -----------------------------------------------------------------------------
-- get_balance_ops — ops/internal full view (§9.3.2)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_balance_ops(p_acct_no VARCHAR)
RETURNS TABLE (
  acct_no            VARCHAR,
  client_no          VARCHAR,
  ccy                VARCHAR,
  acct_status        VARCHAR,
  actual_bal         NUMERIC,
  ledger_bal         NUMERIC,
  calc_bal           NUMERIC,
  available_bal      NUMERIC,
  restrained_amt     NUMERIC,
  restraint_present  VARCHAR,
  cr_blocked         VARCHAR,
  active_restraints  JSONB,
  version            INTEGER,
  previous_day_bal   NUMERIC,
  last_tran_date     TIMESTAMPTZ,
  as_of              TIMESTAMPTZ
)
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

-- -----------------------------------------------------------------------------
-- get_balance_asof — historical end-of-day snapshot (§9.3.3)
--   BAL-04: as_of_date must be < CURRENT_DATE (today → use realtime endpoint)
--   raises INVALID_DATE / GONE_ONLINE per spec; empty set if no snapshot
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_balance_asof(p_acct_no VARCHAR, p_as_of_date DATE)
RETURNS TABLE (
  acct_no     VARCHAR,
  ccy         VARCHAR,
  actual_bal  NUMERIC,
  tran_date   DATE,
  source      TEXT
)
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

-- -----------------------------------------------------------------------------
-- get_balance_batch — batch query, max 100 (§9.3.4)
--   Returns one row per FOUND account; missing accts simply absent (Go marks
--   them ACCT_NOT_FOUND). BAL-07: > 100 → BATCH_SIZE_EXCEEDED.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_balance_batch(p_acct_nos VARCHAR[])
RETURNS TABLE (
  acct_no         VARCHAR,
  ccy             VARCHAR,
  actual_bal      NUMERIC,
  available_bal   NUMERIC,
  restrained_amt  NUMERIC
)
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

COMMIT;
