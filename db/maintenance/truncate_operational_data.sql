-- =============================================================================
-- truncate_operational_data.sql
--
-- Resets the wallet DB to its "seeded master-data" baseline: removes ALL
-- customer, account, posting, transaction-history, outbox, audit and
-- operational-balance data, while PRESERVING reference/master/config data.
--
--   PRESERVED (NOT truncated):
--     fm_currency, fm_gl_mast (GL chart of accounts), fm_nos_vos,
--     wlt_acct_type, wlt_tran_def (tran types), wlt_gl_map, wlt_nostro_link
--
--   TRUNCATED (16 tables, partitions cascade automatically):
--     customers : fm_client, fm_client_contact, fm_client_banks, fm_client_kyc
--     accounts  : wlt_acct, wlt_acct_group, wlt_acct_bal*, wlt_restraints
--     postings  : wlt_gl_batch
--     tran hist : wlt_tran_hist*        (* = partitioned)
--     outbox    : wlt_outbox*
--     ops/other : wlt_api_message, wlt_withdraw_track,
--                 fm_client_audit_log*, wlt_sweep_log, wlt_nostro_bal
--
-- ⚠ DESTRUCTIVE & IRREVERSIBLE — for DEV / pre-prod reset only.
--
-- Usage (direct):
--   psql "<conn>" -v confirm=YES                       -f truncate_operational_data.sql
--   psql "<conn>" -v confirm=YES -v reset_sequences=1  -f truncate_operational_data.sql
-- Or use the wrapper (recommended): db/maintenance/truncate_operational_data.sh
-- =============================================================================
\set ON_ERROR_STOP on

-- ---- Safety guard: refuse to run without -v confirm=YES ---------------------
\if :{?confirm}
\else
  \set confirm no
\endif
SELECT CASE WHEN lower(:'confirm') = 'yes' THEN 'true' ELSE 'false' END AS _proceed \gset
\if :_proceed
\else
  \warn '############################################################'
  \warn '# ABORTED — this truncates customer & transactional data.  #'
  \warn '# Re-run with:  -v confirm=YES                              #'
  \warn '############################################################'
  \quit
\endif

-- default reset_sequences to 0 when not supplied
\if :{?reset_sequences}
\else
  \set reset_sequences 0
\endif

\timing on
\echo '>> Truncating operational data (master/reference data preserved) ...'

BEGIN;

-- Single atomic statement.
--  * RESTART IDENTITY resets each table's own identity-backed sequence
--    (wlt_acct.internal_key, wlt_outbox.event_id, wlt_tran_hist.seq_no, ...).
--  * CASCADE is required for the circular FK wlt_acct <-> wlt_acct_group and to
--    cover all partitions. Verified safe: no PRESERVED table has a foreign key
--    into this set, so CASCADE cannot reach master/reference tables.
TRUNCATE TABLE
    -- Customer master & KYC
    fm_client,
    fm_client_contact,
    fm_client_banks,
    fm_client_kyc,
    -- Accounts, balances, groups, restraints
    wlt_acct,
    wlt_acct_group,
    wlt_acct_bal,            -- partitioned (monthly)
    wlt_restraints,
    -- Posting / GL movements
    wlt_gl_batch,
    -- Transaction history (partitioned: month -> hour)
    wlt_tran_hist,
    -- Outbox events (partitioned)
    wlt_outbox,
    -- API messages / idempotency store
    wlt_api_message,
    -- Withdrawal tracking
    wlt_withdraw_track,
    -- Client audit log (partitioned)
    fm_client_audit_log,
    -- Sweep log
    wlt_sweep_log,
    -- Nostro reconciliation balances (operational state)
    wlt_nostro_bal
RESTART IDENTITY CASCADE;

-- ---- Optional: reset app-level sequences (NOT column-owned) ------------------
-- These drive generated business numbers from the stored procedures. Resetting
-- them makes new clients/accounts/transfer-refs restart from their START value.
-- Enable ONLY on a full reset where you will NOT re-insert seed rows that used
-- these same ranges (otherwise future generated keys may collide with re-seeded
-- rows). Off by default.
\if :reset_sequences
  \echo '>> Resetting app sequences: seq_client, seq_acct_no, seq_tran ...'
  ALTER SEQUENCE seq_client  RESTART;
  ALTER SEQUENCE seq_acct_no RESTART;
  ALTER SEQUENCE seq_tran     RESTART;
\endif

COMMIT;

\echo '>> Done. Preserved master/reference: fm_currency, fm_gl_mast, fm_nos_vos,'
\echo '   wlt_acct_type, wlt_tran_def, wlt_gl_map, wlt_nostro_link.'
