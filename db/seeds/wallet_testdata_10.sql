-- =============================================================================
-- wallet_testdata_10.sql — Create 10 client/wallet sets for transaction testing
-- =============================================================================
-- Schema-correct as of live DB (2026-05): FM_CLIENT_KYC encrypts phone (pgcrypto),
-- WLT_ACCT.internal_key & FM_CLIENT_KYC.kyc_id are IDENTITY, WLT_ACCT.calc_bal is
-- GENERATED. Test key is fixed ('wallet-test-key') — transactions do not decrypt
-- phone, so this is sufficient for posting tests.
-- Re-running creates ANOTHER 10 (sequences advance; phone hashes stay unique
-- because phone numbers differ per run only if you edit them — see note at end).
-- =============================================================================

CREATE SEQUENCE IF NOT EXISTS seq_client  AS BIGINT START 1000000000 CACHE 100;
CREATE SEQUENCE IF NOT EXISTS seq_acct_no AS BIGINT START 5000000000 CACHE 100;

-- ---- fn_create_client : FM_CLIENT + IDENTIFIERS + KYC (IND in extra_data) ----
CREATE OR REPLACE FUNCTION fn_create_client(
  p_client_name VARCHAR, p_global_id VARCHAR, p_phone VARCHAR,
  p_email VARCHAR DEFAULT NULL, p_client_type VARCHAR DEFAULT 'IND',
  p_kyc_tier VARCHAR DEFAULT '1'
) RETURNS VARCHAR LANGUAGE plpgsql AS $$
DECLARE
  v_client_no VARCHAR(48);
  v_key       TEXT := 'wallet-test-key';
BEGIN
  v_client_no := 'C' || LPAD(nextval('seq_client')::text, 10, '0');

  INSERT INTO FM_CLIENT (CLIENT_NO, GLOBAL_ID, GLOBAL_ID_TYPE, CLIENT_NAME,
     CLIENT_TYPE, COUNTRY_LOC, COUNTRY_CITIZEN, STATUS)
  VALUES (v_client_no, p_global_id, 'CCCD', p_client_name,
     p_client_type, 'VN', 'VN', 'A');

  INSERT INTO FM_CLIENT_IDENTIFIERS (CLIENT_NO, GLOBAL_ID, GLOBAL_ID_TYPE, IS_CURRENT, NATIONALITY)
  VALUES (v_client_no, p_global_id, 'CCCD', 1, 'VN');

  -- IND personal details fold into extra_data JSONB (US-1.15)
  INSERT INTO FM_CLIENT_KYC (CLIENT_NO, PHONE_NO_ENC, PHONE_NO_HASH, EMAIL_ENC, KYC_TIER, STATUS, EXTRA_DATA)
  VALUES (
    v_client_no,
    pgp_sym_encrypt(p_phone, v_key),
    digest(p_phone, 'sha256'),
    CASE WHEN p_email IS NULL THEN NULL ELSE pgp_sym_encrypt(p_email, v_key) END,
    p_kyc_tier, 'A',
    CASE WHEN p_client_type = 'IND'
         THEN jsonb_build_object('surname', split_part(p_client_name,' ',1),
                                 'given_name', split_part(p_client_name,' ',-1),
                                 'sex','M','resident_status','R')
         ELSE '{}'::jsonb END);

  RETURN v_client_no;
END $$;

-- ---- fn_open_wallet : WLT_ACCT (+balance row) -------------------------------
CREATE OR REPLACE FUNCTION fn_open_wallet(
  p_client_no VARCHAR, p_acct_type VARCHAR DEFAULT 'CONSUMER',
  p_initial_fund NUMERIC DEFAULT 0, p_ccy VARCHAR DEFAULT 'VND'
) RETURNS TABLE (internal_key BIGINT, acct_no VARCHAR) LANGUAGE plpgsql AS $$
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

-- ---- create 10 client/wallet sets -------------------------------------------
DO $$
DECLARE
  v_cn VARCHAR(48);
  v_data TEXT[][] := ARRAY[  -- name, CCCD, phone, email, wallet_type, kyc_tier, fund
    ['Nguyễn Văn An',       '034090001234','0901000001','an.nguyen@test.local',    'CONSUMER','2','5000000'],
    ['Trần Thị Bình',       '034090001235','0901000002','binh.tran@test.local',    'CONSUMER','2','2500000'],
    ['Lê Hoàng Cường',      '034090001236','0901000003','cuong.le@test.local',     'CONSUMER','2','10000000'],
    ['Phạm Thị Dung',       '034090001237','0901000004','dung.pham@test.local',    'CONSUMER','2','800000'],
    ['Vũ Minh Đức',         '034090001238','0901000005','duc.vu@test.local',       'CONSUMER','2','15000000'],
    ['Hoàng Thị Em',        '034090001239','0901000006','em.hoang@test.local',     'CONSUMER','1','3200000'],
    ['Đặng Văn Phúc',       '034090001240','0901000007','phuc.dang@test.local',    'CONSUMER','2','500000'],
    ['Cửa hàng Minh Anh',   '031090009001','0902000001','minhanh@merchant.local',  'MERCHANT','3','50000000'],
    ['Nhà hàng Hương Việt', '031090009002','0902000002','huongviet@merchant.local','MERCHANT','3','120000000'],
    ['Siêu thị Hồng Phát',  '031090009003','0902000003','hongphat@merchant.local', 'MERCHANT','3','200000000']
  ];
  i INT;
BEGIN
  FOR i IN 1 .. array_length(v_data,1) LOOP
    v_cn := fn_create_client(
      v_data[i][1], v_data[i][2], v_data[i][3], v_data[i][4],
      CASE WHEN v_data[i][5]='MERCHANT' THEN 'MER' ELSE 'IND' END,
      v_data[i][6]);
    PERFORM fn_open_wallet(v_cn, v_data[i][5], v_data[i][7]::NUMERIC);
    RAISE NOTICE 'Created % (%) % fund=%', v_data[i][1], v_cn, v_data[i][5], v_data[i][7];
  END LOOP;
END $$;
