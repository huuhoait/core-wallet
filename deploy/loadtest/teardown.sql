-- =============================================================================
-- loadtest/teardown.sql — remove ONLY load-test-generated data.
--
-- Load-test data is created by setup.sql + the run scripts and is uniquely
-- marked:  accounts 'LT%' / 'LTGS%' / 'LTGH%',  groups 'LTG%',
-- clients 'LTC%' / 'LTGC%',  ledger refs 'LT-OPEN-%' / 'PB-%' / 'PBEXT-%'.
-- Everything else (baseline C* clients, master/reference tables) is preserved.
--
-- Idempotent and safe to re-run. Invoked by run.sh / stress.sh with TEARDOWN=1,
-- or manually:  psql -U postgres -d wallet -f teardown.sql
-- =============================================================================
\set ON_ERROR_STOP on
SET statement_timeout = 0;

\echo '--- load-test rows BEFORE teardown ---'
SELECT 'wlt_acct (LT)'   AS scope, count(*) AS rows FROM wlt_acct      WHERE acct_no  LIKE 'LT%'
UNION ALL SELECT 'fm_client (LT)',         count(*) FROM fm_client     WHERE client_no LIKE 'LTC%' OR client_no LIKE 'LTGC%'
UNION ALL SELECT 'wlt_tran_hist (PB/LT)',  count(*) FROM wlt_tran_hist WHERE reference LIKE 'PB-%' OR reference LIKE 'PBEXT-%' OR reference LIKE 'LT-%'
UNION ALL SELECT 'wlt_gl_batch (PB/LT)',      count(*) FROM wlt_gl_batch     WHERE reference LIKE 'PB-%' OR reference LIKE 'PBEXT-%' OR reference LIKE 'LT-%';

BEGIN;
/*
-- Snapshot the load-test entity keys before deleting their parent rows.
CREATE TEMP TABLE _lt_acct ON COMMIT DROP AS
  SELECT internal_key FROM wlt_acct  WHERE acct_no  LIKE 'LT%';
CREATE TEMP TABLE _lt_client ON COMMIT DROP AS
  SELECT client_no   FROM fm_client WHERE client_no LIKE 'LTC%' OR client_no LIKE 'LTGC%';

-- 1) Ledger / event / tracking rows (no FK to accounts → free order).
--    Matched by load-test account/client linkage AND by unambiguous LT/PB
--    references — the GL/nostro legs of a posting carry the reference but are
--    not tied to an LT account, so the reference filter is required to catch them.
DELETE FROM wlt_tran_hist
 WHERE internal_key IN (SELECT internal_key FROM _lt_acct)
    OR reference LIKE 'PB-%' OR reference LIKE 'PBEXT-%' OR reference LIKE 'LT-%';

DELETE FROM wlt_gl_batch
 WHERE acct_internal_key IN (SELECT internal_key FROM _lt_acct)
    OR client_no IN (SELECT client_no FROM _lt_client)
    OR reference LIKE 'PB-%' OR reference LIKE 'PBEXT-%' OR reference LIKE 'LT-%';

DELETE FROM wlt_outbox       WHERE partition_key LIKE 'LT%';

DELETE FROM wlt_api_message
 WHERE object_ref_id LIKE 'PB-%' OR object_ref_id LIKE 'PBEXT-%' OR object_ref_id LIKE 'LT-%';

DELETE FROM fm_client_audit_log
 WHERE client_no IN (SELECT client_no FROM _lt_client)
    OR client_no LIKE 'LT%'
    OR change_source = 'LOADTEST' OR changed_by = 'loadtest';

DELETE FROM wlt_withdraw_track
 WHERE acct_no LIKE 'LT%'
    OR client_no IN (SELECT client_no FROM _lt_client)
    OR ext_payout_ref LIKE 'PBEXT-%';

-- 2) Account graph, in FK order. fk_group_settlement (group→acct) is
--    DEFERRABLE INITIALLY DEFERRED, so deleting accounts before groups is OK
--    (validated at COMMIT, by which point both sides are gone).
DELETE FROM wlt_sweep_log    WHERE group_id LIKE 'LTG%';
DELETE FROM wlt_restraints   WHERE internal_key IN (SELECT internal_key FROM _lt_acct);
DELETE FROM wlt_acct_bal     WHERE internal_key IN (SELECT internal_key FROM _lt_acct);
DELETE FROM wlt_acct         WHERE acct_no  LIKE 'LT%';
DELETE FROM wlt_acct_group   WHERE group_id LIKE 'LTG%';

-- 3) Client master & its child tables.
DELETE FROM fm_client_kyc         WHERE client_no IN (SELECT client_no FROM _lt_client);
DELETE FROM fm_client_contact     WHERE client_no IN (SELECT client_no FROM _lt_client);
DELETE FROM fm_client_banks       WHERE client_no IN (SELECT client_no FROM _lt_client);
DELETE FROM fm_client             WHERE client_no IN (SELECT client_no FROM _lt_client);

COMMIT;

-- NOTE: wlt_nostro_bal is intentionally NOT touched — it holds system nostro
-- reconciliation snapshots, not load-test-generated rows.
*/
\echo '--- remaining load-test rows AFTER teardown (expect all 0) ---'
SELECT 'wlt_acct (LT)'   AS scope, count(*) AS rows FROM wlt_acct      WHERE acct_no  LIKE 'LT%'
UNION ALL SELECT 'fm_client (LT)',         count(*) FROM fm_client     WHERE client_no LIKE 'LTC%' OR client_no LIKE 'LTGC%'
UNION ALL SELECT 'wlt_tran_hist (PB/LT)',  count(*) FROM wlt_tran_hist WHERE reference LIKE 'PB-%' OR reference LIKE 'PBEXT-%' OR reference LIKE 'LT-%'
UNION ALL SELECT 'wlt_gl_batch (PB/LT)',      count(*) FROM wlt_gl_batch     WHERE reference LIKE 'PB-%' OR reference LIKE 'PBEXT-%' OR reference LIKE 'LT-%';
SELECT 'baseline fm_client (C*) preserved' AS check, count(*) AS rows FROM fm_client WHERE client_no NOT LIKE 'LT%';
