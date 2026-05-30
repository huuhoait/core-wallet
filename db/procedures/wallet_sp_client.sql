-- =============================================================================
-- wallet_sp_client.sql — Client master CRUD (no onboarding/KYC flow)
-- =============================================================================
-- create_client : insert FM_CLIENT (+ FM_CLIENT_INDVL for individuals)
-- update_client : patch mutable identity fields
--
-- SECURITY DEFINER: wallet_app is REVOKE'd on FM_CLIENT/FM_CLIENT_INDVL (PII),
-- so these run as the function owner. Audit attribution still flows through the
-- audit.* GUCs the app sets per-TX (trg_audit_cols / fn_audit_client_change).
--
-- Out of scope here: WLT_CLIENT_KYC (phone/eKYC/tier), wallet opening, OTP.
-- CLIENT_NO format: 'C' + 10 digits (seq_client). Custom SQLSTATE class P007x.
-- =============================================================================

CREATE SEQUENCE IF NOT EXISTS seq_client AS BIGINT START 1000000000 CACHE 100;

CREATE OR REPLACE FUNCTION create_client(
  p_client_name     VARCHAR(200),
  p_client_type     VARCHAR(12),                 -- 'IND' | 'CORP'
  p_global_id       VARCHAR(64)  DEFAULT NULL,   -- CCCD / passport / tax id
  p_global_id_type  VARCHAR(12)  DEFAULT NULL,
  p_country_loc     VARCHAR(8)   DEFAULT 'VN',
  p_country_citizen VARCHAR(8)   DEFAULT 'VN',
  -- individual sub-fields (CLIENT_TYPE = 'IND')
  p_surname         VARCHAR(80)  DEFAULT NULL,
  p_given_name      VARCHAR(80)  DEFAULT NULL,
  p_birth_date      DATE         DEFAULT NULL,
  p_sex             VARCHAR(4)   DEFAULT NULL,
  p_actor           VARCHAR(40)  DEFAULT NULL
)
RETURNS TABLE (client_no VARCHAR, status VARCHAR, created_at TIMESTAMPTZ)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
#variable_conflict use_column
DECLARE
  v_no      VARCHAR(48);
  v_created TIMESTAMPTZ;
BEGIN
  IF p_client_type IS NULL OR p_client_type NOT IN ('IND','CORP') THEN
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

  IF p_client_type = 'IND' THEN
    INSERT INTO FM_CLIENT_INDVL(client_no, surname, given_name_1, birth_date, sex, resident_status)
    VALUES (v_no, p_surname, p_given_name, p_birth_date, p_sex, 'R');
  END IF;

  RETURN QUERY SELECT v_no, 'A'::varchar, v_created;
END;
$$;

CREATE OR REPLACE FUNCTION update_client(
  p_client_no       VARCHAR(48),
  p_client_name     VARCHAR(200) DEFAULT NULL,
  p_status          VARCHAR(4)   DEFAULT NULL,
  p_country_loc     VARCHAR(8)   DEFAULT NULL,
  p_country_citizen VARCHAR(8)   DEFAULT NULL,
  p_surname         VARCHAR(80)  DEFAULT NULL,
  p_given_name      VARCHAR(80)  DEFAULT NULL,
  p_birth_date      DATE         DEFAULT NULL,
  p_sex             VARCHAR(4)   DEFAULT NULL,
  p_actor           VARCHAR(40)  DEFAULT NULL
)
RETURNS TABLE (client_no VARCHAR, status VARCHAR, updated_at TIMESTAMPTZ)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
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

  IF v_type = 'IND'
     AND (p_surname IS NOT NULL OR p_given_name IS NOT NULL
          OR p_birth_date IS NOT NULL OR p_sex IS NOT NULL) THEN
    UPDATE FM_CLIENT_INDVL
       SET surname      = COALESCE(p_surname, surname),
           given_name_1 = COALESCE(p_given_name, given_name_1),
           birth_date   = COALESCE(p_birth_date, birth_date),
           sex          = COALESCE(p_sex, sex)
     WHERE client_no = p_client_no;
  END IF;

  RETURN QUERY SELECT p_client_no, v_status, v_updated;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- link_client_bank : link a bank account to a client (FM_CLIENT_BANKS).
--   p_acct_no is plaintext in → encrypted to ACCT_NO_ENC via pgp_sym_encrypt
--   (same DEK mechanism as withdraw — app.pii_dek GUC).
--   p_is_default = TRUE makes this the client's sole default (clears any prior
--   default first; also guarded by partial-unique uk_cb_one_default).
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION link_client_bank(
  p_client_no        VARCHAR(48),
  p_bank_code        VARCHAR(20),
  p_acct_no          VARCHAR(40),                 -- plaintext; SP encrypts
  p_bank_name        VARCHAR(120) DEFAULT NULL,
  p_acct_holder_name VARCHAR(200) DEFAULT NULL,
  p_is_default       BOOLEAN      DEFAULT FALSE,
  p_actor            VARCHAR(40)  DEFAULT NULL
)
RETURNS TABLE (link_id BIGINT, client_no VARCHAR, is_default SMALLINT, status VARCHAR, created_at TIMESTAMPTZ)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
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

-- ─────────────────────────────────────────────────────────────────────────────
-- set_default_client_bank : make an existing link the client's sole default.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION set_default_client_bank(
  p_client_no VARCHAR(48),
  p_link_id   BIGINT,
  p_actor     VARCHAR(40) DEFAULT NULL
)
RETURNS TABLE (link_id BIGINT, client_no VARCHAR, is_default SMALLINT, status VARCHAR, updated_at TIMESTAMPTZ)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
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

GRANT EXECUTE ON FUNCTION create_client(VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, DATE, VARCHAR, VARCHAR) TO wallet_app;
GRANT EXECUTE ON FUNCTION update_client(VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, DATE, VARCHAR, VARCHAR) TO wallet_app;
GRANT EXECUTE ON FUNCTION link_client_bank(VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, BOOLEAN, VARCHAR) TO wallet_app;
GRANT EXECUTE ON FUNCTION set_default_client_bank(VARCHAR, BIGINT, VARCHAR) TO wallet_app;
