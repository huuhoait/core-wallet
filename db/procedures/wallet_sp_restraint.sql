-- =============================================================================
-- wallet_sp_restraint.sql — Restraint (hold/lien) management
-- =============================================================================
-- add_restraint     : validate + insert WLT_RESTRAINTS + roll up onto WLT_ACCT
-- release_restraint : mark released + recompute account aggregates
--
-- Account-scoped only (INTERNAL_KEY). Group-scoped restraints are out of scope
-- for this phase. Posting enforcement (DR_RESTRAINT_ACTIVE / CR_BLOCKED) lives
-- in wallet_sp.sql; these SPs keep WLT_ACCT.{TOTAL_RESTRAINED_AMT, CR_BLOCKED,
-- RESTRAINT_PRESENT} consistent so that enforcement stays correct.
--
--   Semantics (finance_transaction.md §8.2):
--     DEBIT/ALL + PLEDGED_AMT = 0  → full debit block (posting raises on it)
--     DEBIT/ALL + PLEDGED_AMT > 0  → locks that amount into TOTAL_RESTRAINED_AMT
--     CREDIT/ALL                   → CR_BLOCKED = 'Y'
--     INFO                         → never blocks (PLEDGED_AMT forced 0)
--
-- Error codes (error_management.md §4.9). Custom SQLSTATE class P006x (free).
-- =============================================================================

CREATE OR REPLACE FUNCTION add_restraint(
  p_acct_no       VARCHAR(20),
  p_type          VARCHAR(8),
  p_purpose       VARCHAR(16),
  p_pledged_amt   NUMERIC(18,2) DEFAULT 0,
  p_start_date    DATE          DEFAULT CURRENT_DATE,
  p_end_date      DATE          DEFAULT NULL,
  p_narrative     VARCHAR(500)  DEFAULT NULL,
  p_reference_doc VARCHAR(500)  DEFAULT NULL,
  p_actor         VARCHAR(40)   DEFAULT NULL
)
RETURNS TABLE (
  restraint_id        BIGINT,
  status              VARCHAR,
  pledged_amt         NUMERIC,
  available_bal_after NUMERIC,
  version             INTEGER
)
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

CREATE OR REPLACE FUNCTION release_restraint(
  p_restraint_id BIGINT,
  p_reason       VARCHAR(500) DEFAULT NULL,
  p_actor        VARCHAR(40)  DEFAULT NULL
)
RETURNS TABLE (
  restraint_id        BIGINT,
  status              VARCHAR,
  available_bal_after NUMERIC,
  version             INTEGER
)
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

GRANT EXECUTE ON FUNCTION add_restraint(VARCHAR, VARCHAR, VARCHAR, NUMERIC, DATE, DATE, VARCHAR, VARCHAR, VARCHAR) TO wallet_app;
GRANT EXECUTE ON FUNCTION release_restraint(BIGINT, VARCHAR, VARCHAR) TO wallet_app;
