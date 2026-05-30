-- =============================================================================
-- wallet_sp_account.sql — Account (wallet) lifecycle (US-1.3 / 1.4 / 1.5)
-- =============================================================================
-- open_account          : ACCT_NO gen + WLT_ACCT insert (zero balance), with
--                         per-client wallet-count limit (§4.3)
-- update_account_status : block (B) / close (C) / re-activate (A), close needs bal=0
--
-- No SECURITY DEFINER: wallet_app has DML on WLT_ACCT + column-SELECT on
-- FM_CLIENT.status. KYC-tier gating (Tier-2) is intentionally NOT enforced here
-- (onboarding flow out of scope). Funding is via post_topup (keeps GL balanced) —
-- opening always starts at ACTUAL_BAL = 0. Custom SQLSTATE class P008x.
--
-- Count limits (§4.3): CONSUMER = 3 (same CCY), MERCHANT = 10. Closed wallets
-- (status 'C') do not count. State machine (§6.2): A↔B, A/B→C (terminal);
-- A→C only when ACTUAL_BAL = 0.
-- =============================================================================

CREATE SEQUENCE IF NOT EXISTS seq_acct_no AS BIGINT START 1 CACHE 100;

CREATE OR REPLACE FUNCTION open_account(
  p_client_no VARCHAR(48),
  p_acct_type VARCHAR(12) DEFAULT 'CONSUMER',
  p_ccy       VARCHAR(4)  DEFAULT 'VND',
  p_actor     VARCHAR(40) DEFAULT NULL
)
RETURNS TABLE (acct_no VARCHAR, internal_key BIGINT, acct_status VARCHAR)
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

CREATE OR REPLACE FUNCTION update_account_status(
  p_acct_no VARCHAR(20),
  p_status  VARCHAR(4),
  p_actor   VARCHAR(40) DEFAULT NULL
)
RETURNS TABLE (acct_no VARCHAR, acct_status VARCHAR, version INTEGER)
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

-- open_account runs as the caller (SECURITY INVOKER) → wallet_app needs the seq.
GRANT USAGE, SELECT ON SEQUENCE seq_acct_no TO wallet_app;
GRANT EXECUTE ON FUNCTION open_account(VARCHAR, VARCHAR, VARCHAR, VARCHAR) TO wallet_app;
GRANT EXECUTE ON FUNCTION update_account_status(VARCHAR, VARCHAR, VARCHAR) TO wallet_app;
