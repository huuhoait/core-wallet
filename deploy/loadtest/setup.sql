-- =============================================================================
-- loadtest/setup.sql — seed load-test data (all 'LT*' prefixed for easy teardown)
-- =============================================================================
-- 10,000 consumer wallets (LT0000000001..LT0000010000), tier 2, funded 1e12.
-- 20 merchant groups (LTG01..LTG20): settlement funded 500M, 8 shards each at 0.
-- Idempotent (NOT EXISTS guards + post_topup/post_transfer reference idempotency).
-- Committed — load test needs persistent data.
--
-- Consumer funding goes through post_topup (DR 101.02.001 nostro / CR wallet
-- liability). Merchant SETTLEMENT wallets are funded by customer→merchant
-- TRANSFERS (post_topup is STANDALONE-only; post_transfer permits a SETTLEMENT
-- receiver), and SHARD wallets are NEVER funded directly — they fill via sweep
-- only (crediting a shard directly corrupts the group's aggregation invariants).
-- So every seeded balance has a matching ledger + GL entry — wlt_acct.actual_bal
-- always reconciles to Σ(wlt_tran_hist). Do NOT set actual_bal directly here.
-- =============================================================================
\set ON_ERROR_STOP on
SET statement_timeout = 0;

-- Sequence feeding onboard.sql (US-1.1 load script): unique phone + global_id per
-- onboard call. Persisted so onboard never collides on uk_kyc_phone_hash.
CREATE SEQUENCE IF NOT EXISTS lt_onboard_seq START 1;

BEGIN;
DO $$
DECLARE
  i int; j int; k int; v_c text; v_g text; v_key text := 'loadtest-key';
BEGIN
  PERFORM set_config('audit.actor','loadtest',true);
  PERFORM set_config('audit.channel','LOADTEST',true);

  -- ── 50,000 consumer wallets ──
  FOR i IN 1..50000 LOOP
    v_c := 'LTC'||lpad(i::text,9,'0');
    CONTINUE WHEN EXISTS (SELECT 1 FROM FM_CLIENT WHERE client_no = v_c);
    INSERT INTO FM_CLIENT(client_no,global_id,global_id_type,client_name,client_type,country_loc,country_citizen,status)
      VALUES(v_c,'LTID'||lpad(i::text,9,'0'),'CCCD','LoadUser '||i,'IND','VN','VN','A');
    INSERT INTO FM_CLIENT_KYC(client_no,phone_no_enc,phone_no_hash,kyc_tier,status,extra_data)
      VALUES(v_c, convert_to('03'||lpad(i::text,8,'0'),'UTF8'),
             digest('LTU03'||lpad(i::text,8,'0'),'sha256'),'2','A',
             jsonb_build_object('surname','Load','given_name','User'||i,'sex','M','resident_status','R'));
    INSERT INTO WLT_ACCT(acct_no,client_no,acct_type,ccy,acct_status,acct_role)
      VALUES('LT'||lpad(i::text,10,'0'), v_c,'CONSUMER','VND','A','STANDALONE');
    PERFORM post_topup('LT'||lpad(i::text,10,'0'), 1000000000000,
                       'LT-OPEN-'||lpad(i::text,10,'0'), '{}'::jsonb, 'LOADTEST', 'loadtest');
  END LOOP;

  -- ── 50 merchant groups: settlement + 8 shards ──
  FOR i IN 1..50 LOOP
    v_g := 'LTG'||lpad(i::text,2,'0');
    v_c := 'LTGC'||lpad(i::text,8,'0');
    CONTINUE WHEN EXISTS (SELECT 1 FROM WLT_ACCT_GROUP WHERE group_id = v_g);
    INSERT INTO FM_CLIENT(client_no,global_id,global_id_type,client_name,client_type,country_loc,country_citizen,status)
      VALUES(v_c,'LTGID'||lpad(i::text,8,'0'),'CCCD','LoadMerchant '||i,'MER','VN','VN','A');
    INSERT INTO FM_CLIENT_KYC(client_no,phone_no_enc,phone_no_hash,kyc_tier,status)
      VALUES(v_c, convert_to('09'||lpad(i::text,8,'0'),'UTF8'),
             digest('LTM09'||lpad(i::text,8,'0'),'sha256'),'3','A');
    INSERT INTO WLT_ACCT_GROUP(group_id,client_no,group_type,shard_count,settlement_acct_no,shard_threshold,shard_buffer,sweep_interval_sec,group_status)
      VALUES(v_g,v_c,'MERCHANT',8,'LTGS'||lpad(i::text,4,'0'),50000000,0,60,'A');
    INSERT INTO WLT_ACCT(acct_no,client_no,acct_type,ccy,acct_status,acct_role,group_id)
      VALUES('LTGS'||lpad(i::text,4,'0'), v_c,'MERCHANT','VND','A','SETTLEMENT',v_g);
    -- Fund SETTLEMENT via customer→merchant transfers: TRFOUT caps at 100M/tx and
    -- post_transfer has no monthly cap, so 5×100M = 500M per group (covers the k6
    -- merchant-withdraw draw of ≤2M at peak rate with headroom). Funder = consumer
    -- i (tier 2, funded 1e12 above). SHARDS are created at 0 and fill via sweep.
    FOR k IN 1..5 LOOP
      PERFORM post_transfer('LT'||lpad(i::text,10,'0'), 'LTGS'||lpad(i::text,4,'0'),
                            100000000, 'LT-FUND-LTGS'||lpad(i::text,2,'0')||'-'||k,
                            'TRFOUT', '{}'::jsonb, 'LOADTEST', 'loadtest');
    END LOOP;
    FOR j IN 0..7 LOOP
      INSERT INTO WLT_ACCT(acct_no,client_no,acct_type,ccy,acct_status,acct_role,group_id,shard_index)
        VALUES('LTGH'||lpad(i::text,2,'0')||j, v_c,'MERCHANT','VND','A','SHARD',v_g,j);
    END LOOP;
  END LOOP;
END $$;
COMMIT;

SELECT
  (SELECT count(*) FROM WLT_ACCT WHERE acct_no LIKE 'LT%' AND acct_role='STANDALONE') AS consumer_wallets,
  (SELECT count(*) FROM WLT_ACCT_GROUP WHERE group_id LIKE 'LTG%')                     AS merchant_groups,
  (SELECT count(*) FROM WLT_ACCT WHERE acct_role='SHARD' AND group_id LIKE 'LTG%')     AS shards;
