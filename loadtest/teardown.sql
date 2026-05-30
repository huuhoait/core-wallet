-- =============================================================================
-- loadtest/teardown.sql — remove all load-test data (LT*/PB* prefixed)
-- =============================================================================
\set ON_ERROR_STOP on
BEGIN;
-- ledger rows: run traffic (PB-*), seed funding (LT-OPEN-*), sweeps (SWEEP-*),
-- reversals (RV*). MUST also clear the LT-OPEN-* idempotency keys, else a re-seed
-- post_topup returns DUPLICATE and wallets stay at 0.
/*
DELETE FROM WLT_BATCH      WHERE reference LIKE 'PB-%' OR reference LIKE 'LT-%' OR reference LIKE 'SWEEP-%' OR reference LIKE 'RV%';
DELETE FROM WLT_TRAN_HIST  WHERE reference LIKE 'PB-%' OR reference LIKE 'LT-%' OR reference LIKE 'SWEEP-%' OR reference LIKE 'RV%';
DELETE FROM WLT_OUTBOX     WHERE partition_key LIKE 'LT%';
DELETE FROM WLT_API_MESSAGE WHERE object_ref_id LIKE 'PB-%' OR object_ref_id LIKE 'LT-%' OR object_ref_id LIKE 'RV%';
DELETE FROM WLT_SWEEP_LOG  WHERE group_id LIKE 'LTG%';
-- accounts → groups → clients (FK order)
DELETE FROM WLT_ACCT_BAL   WHERE internal_key IN (SELECT internal_key FROM WLT_ACCT WHERE acct_no LIKE 'LT%');
DELETE FROM WLT_ACCT       WHERE acct_no LIKE 'LT%';
DELETE FROM WLT_ACCT_GROUP WHERE group_id LIKE 'LTG%';
DELETE FROM WLT_CLIENT_KYC        WHERE client_no LIKE 'LTC%'  OR client_no LIKE 'LTGC%';
DELETE FROM FM_CLIENT_INDVL       WHERE client_no LIKE 'LTC%'  OR client_no LIKE 'LTGC%';
DELETE FROM FM_CLIENT_IDENTIFIERS WHERE client_no LIKE 'LTC%'  OR client_no LIKE 'LTGC%';
DELETE FROM FM_CLIENT             WHERE client_no LIKE 'LTC%'  OR client_no LIKE 'LTGC%';
*/
COMMIT;
SELECT 'teardown done' AS status,
  (SELECT count(*) FROM WLT_ACCT WHERE acct_no LIKE 'LT%') AS remaining_lt_accts;
