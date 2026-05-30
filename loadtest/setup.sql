-- =============================================================================
-- loadtest/setup.sql — seed load-test data (all 'LT*' prefixed for easy teardown)
-- =============================================================================
-- 10,000 consumer wallets (LT0000000001..LT0000010000), tier 2, funded 1e12.
-- 20 merchant groups (LTG01..LTG20): settlement + 8 shards each, funded large.
-- Idempotent (NOT EXISTS guards + post_topup reference idempotency).
-- Committed — load test needs persistent data.
--
-- Funding goes through post_topup (DR 101.02.001 nostro / CR wallet liability)
-- so every seeded balance has a matching ledger + GL entry — wlt_acct.actual_bal
-- always reconciles to Σ(wlt_tran_hist). Do NOT set actual_bal directly here.
-- =============================================================================
\set ON_ERROR_STOP on
SET statement_timeout = 0;
BEGIN;
DO $$
DECLARE
  i int; j int; v_c text; v_g text; v_key text := 'loadtest-key';
BEGIN
  PERFORM set_config('audit.actor','loadtest',true);
  PERFORM set_config('audit.channel','LOADTEST',true);

  -- ── 10,000 consumer wallets ──
  FOR i IN 1..10000 LOOP
    v_c := 'LTC'||lpad(i::text,9,'0');
    CONTINUE WHEN EXISTS (SELECT 1 FROM FM_CLIENT WHERE client_no = v_c);
    INSERT INTO FM_CLIENT(client_no,global_id,global_id_type,client_name,client_type,country_loc,country_citizen,status)
      VALUES(v_c,'LTID'||lpad(i::text,9,'0'),'CCCD','LoadUser '||i,'IND','VN','VN','A');
    INSERT INTO FM_CLIENT_INDVL(client_no,surname,given_name_1,sex,resident_status)
      VALUES(v_c,'Load','User'||i,'M','R');
    INSERT INTO WLT_CLIENT_KYC(client_no,phone_no_enc,phone_no_hash,kyc_tier,status)
      VALUES(v_c, convert_to('03'||lpad(i::text,8,'0'),'UTF8'),
             digest('LTU03'||lpad(i::text,8,'0'),'sha256'),'2','A');
    INSERT INTO WLT_ACCT(acct_no,client_no,acct_type,ccy,acct_status,acct_role)
      VALUES('LT'||lpad(i::text,10,'0'), v_c,'CONSUMER','VND','A','STANDALONE');
    PERFORM post_topup('LT'||lpad(i::text,10,'0'), 1000000000000,
                       'LT-OPEN-'||lpad(i::text,10,'0'), '{}'::jsonb, 'LOADTEST', 'loadtest');
  END LOOP;

  -- ── 20 merchant groups: settlement + 8 shards ──
  FOR i IN 1..20 LOOP
    v_g := 'LTG'||lpad(i::text,2,'0');
    v_c := 'LTGC'||lpad(i::text,8,'0');
    CONTINUE WHEN EXISTS (SELECT 1 FROM WLT_ACCT_GROUP WHERE group_id = v_g);
    INSERT INTO FM_CLIENT(client_no,global_id,global_id_type,client_name,client_type,country_loc,country_citizen,status)
      VALUES(v_c,'LTGID'||lpad(i::text,8,'0'),'CCCD','LoadMerchant '||i,'ORG','VN','VN','A');
    INSERT INTO WLT_CLIENT_KYC(client_no,phone_no_enc,phone_no_hash,kyc_tier,status)
      VALUES(v_c, convert_to('09'||lpad(i::text,8,'0'),'UTF8'),
             digest('LTM09'||lpad(i::text,8,'0'),'sha256'),'3','A');
    INSERT INTO WLT_ACCT_GROUP(group_id,client_no,group_type,shard_count,settlement_acct_no,shard_threshold,shard_buffer,sweep_interval_sec,group_status)
      VALUES(v_g,v_c,'MERCHANT',8,'LTGS'||lpad(i::text,2,'0'),50000000,0,60,'A');
    INSERT INTO WLT_ACCT(acct_no,client_no,acct_type,ccy,acct_status,acct_role,group_id)
      VALUES('LTGS'||lpad(i::text,2,'0'), v_c,'MERCHANT','VND','A','SETTLEMENT',v_g);
    PERFORM post_topup('LTGS'||lpad(i::text,2,'0'), 1000000000000,
                       'LT-OPEN-LTGS'||lpad(i::text,2,'0'), '{}'::jsonb, 'LOADTEST', 'loadtest');
    FOR j IN 0..7 LOOP
      INSERT INTO WLT_ACCT(acct_no,client_no,acct_type,ccy,acct_status,acct_role,group_id,shard_index)
        VALUES('LTGH'||lpad(i::text,2,'0')||j, v_c,'MERCHANT','VND','A','SHARD',v_g,j);
      PERFORM post_topup('LTGH'||lpad(i::text,2,'0')||j, 10000000000,
                         'LT-OPEN-LTGH'||lpad(i::text,2,'0')||j, '{}'::jsonb, 'LOADTEST', 'loadtest');
    END LOOP;
  END LOOP;
END $$;
COMMIT;

SELECT
  (SELECT count(*) FROM WLT_ACCT WHERE acct_no LIKE 'LT%' AND acct_role='STANDALONE') AS consumer_wallets,
  (SELECT count(*) FROM WLT_ACCT_GROUP WHERE group_id LIKE 'LTG%')                     AS merchant_groups,
  (SELECT count(*) FROM WLT_ACCT WHERE acct_role='SHARD' AND group_id LIKE 'LTG%')     AS shards;
