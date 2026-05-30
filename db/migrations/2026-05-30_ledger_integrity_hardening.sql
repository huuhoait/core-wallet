-- =============================================================================
-- 2026-05-30_ledger_integrity_hardening.sql — Incremental migration
-- (tracked incremental migrations live in db/migrations/)
-- =============================================================================
-- Closes four ledger-integrity gaps from the architecture review. Idempotent:
-- safe to re-run.
--
--   B#1  Structural double-entry enforcement — a DEFERRABLE constraint trigger
--        asserts Σ(DR) = Σ(CR) per (TRAN_KEY, CCY) on WLT_BATCH at COMMIT, so a
--        posting that omits/mis-sizes a leg can never commit (today it would
--        commit silently and surface, if ever, only at EOD).
--   B#2  Tamper-evidence immutability — a dedicated wallet_eod role owns the
--        EOD writes; wallet_app loses INSERT/UPDATE/DELETE on the trial-balance
--        and proof tables, so the online app role can no longer rewrite/reseal
--        the hash chain. EOD runs as wallet_eod on a direct connection (also
--        sidesteps the PgBouncer txn-mode COMMIT-loop hazard).
--   B#4  Partition cliff guard — a DEFAULT partition on each range-partitioned
--        parent so an out-of-range date can never raise no-partition-found
--        (write outage). Today the newest WLT_TRAN_HIST month ends 2026-11-01.
--        DEFAULT is the safety net; pg_partman still creates ahead-of-time
--        monthly partitions to keep it empty (native on RDS — see B#3 note).
--   B#3  EOD scheduling — pg_cron schedule (native on RDS/Aurora). Guarded:
--        applied only where pg_cron is installed; otherwise prints how to wire
--        an external scheduler as wallet_eod.
-- =============================================================================
\set ON_ERROR_STOP on
BEGIN;

-- ─────────────────────────────────────────────────────────────────────────
-- B#1 — balanced-posting constraint trigger on WLT_BATCH (the GL journal)
-- ─────────────────────────────────────────────────────────────────────────
-- Per (TRAN_KEY, CCY): Σ AMOUNT where DR must equal Σ where CR. Checked once at
-- COMMIT (DEFERRABLE INITIALLY DEFERRED) so it sees the COMPLETE leg set — legs
-- are inserted across multiple statements within one posting SP, so an immediate
-- trigger would false-fail mid-transaction. The SUM filters on the leading
-- column of PK (TRAN_KEY, SEQ_NO) → O(legs per txn), not a table scan.
CREATE OR REPLACE FUNCTION fn_assert_batch_balanced()
RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public, pg_catalog AS $fn$
DECLARE
  v_dr NUMERIC(20,2);
  v_cr NUMERIC(20,2);
BEGIN
  SELECT COALESCE(SUM(AMOUNT) FILTER (WHERE TRAN_NATURE = 'DR'), 0),
         COALESCE(SUM(AMOUNT) FILTER (WHERE TRAN_NATURE = 'CR'), 0)
    INTO v_dr, v_cr
    FROM WLT_BATCH
   WHERE TRAN_KEY = NEW.TRAN_KEY
     AND CCY      = NEW.CCY;

  IF v_dr <> v_cr THEN
    RAISE EXCEPTION 'BATCH_UNBALANCED: tran_key=% ccy=% DR=% CR=%',
      NEW.TRAN_KEY, NEW.CCY, v_dr, v_cr
      USING ERRCODE = 'P0091';
  END IF;
  RETURN NULL;  -- AFTER trigger: result ignored
END
$fn$;

DROP TRIGGER IF EXISTS trg_batch_balanced ON WLT_BATCH;
CREATE CONSTRAINT TRIGGER trg_batch_balanced
  AFTER INSERT ON WLT_BATCH
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW
  EXECUTE FUNCTION fn_assert_batch_balanced();

-- ─────────────────────────────────────────────────────────────────────────
-- B#4 — DEFAULT partition on every range-partitioned parent (cliff guard)
-- ─────────────────────────────────────────────────────────────────────────
-- A catch-all so an out-of-range date routes here instead of erroring. Keep it
-- EMPTY in production by pre-creating monthly partitions (pg_partman) — a DEFAULT
-- holding rows blocks creating a new partition over that range until the rows
-- are moved.
CREATE TABLE IF NOT EXISTS wlt_tran_hist_default        PARTITION OF wlt_tran_hist        DEFAULT;
CREATE TABLE IF NOT EXISTS wlt_outbox_default           PARTITION OF wlt_outbox           DEFAULT;
CREATE TABLE IF NOT EXISTS wlt_client_audit_log_default PARTITION OF wlt_client_audit_log DEFAULT;
CREATE TABLE IF NOT EXISTS wlt_acct_bal_default         PARTITION OF wlt_acct_bal         DEFAULT;

-- ─────────────────────────────────────────────────────────────────────────
-- B#2 — tamper-evidence immutability: dedicated wallet_eod role
-- ─────────────────────────────────────────────────────────────────────────
-- wallet_eod is the ONLY role that may write the trial-balance + proof. Deploy
-- it with LOGIN + password (or use as the pg_cron job role). NOLOGIN by default
-- so it cannot be used as an interactive identity.
DO $do$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'wallet_eod') THEN
    CREATE ROLE wallet_eod NOLOGIN;
  END IF;
END
$do$;

-- Reads EOD needs (no raw PII — EOD only touches WLT_* aggregates + GL refs).
GRANT SELECT ON
  WLT_ACCT, WLT_ACCT_BAL, WLT_TRAN_HIST, WLT_BATCH, WLT_RESTRAINTS,
  WLT_ACCT_TYPE, WLT_ACCT_GROUP, WLT_TRAN_DEF, WLT_GL_MAP,
  FM_CURRENCY, FM_GL_MAST,
  WLT_TRIAL_BALANCE, WLT_TRIAL_BALANCE_PROOF, WLT_EOD_RUN, WLT_EOD_AUDIT_LOG
TO wallet_eod;
-- Writes EOD performs.
GRANT INSERT, UPDATE         ON WLT_ACCT_BAL            TO wallet_eod;
GRANT UPDATE                 ON WLT_ACCT                TO wallet_eod;
GRANT UPDATE                 ON WLT_RESTRAINTS          TO wallet_eod;
GRANT INSERT, UPDATE, DELETE ON WLT_TRIAL_BALANCE       TO wallet_eod;
GRANT INSERT, UPDATE         ON WLT_TRIAL_BALANCE_PROOF TO wallet_eod;
GRANT INSERT, UPDATE         ON WLT_EOD_RUN             TO wallet_eod;
GRANT INSERT                 ON WLT_EOD_AUDIT_LOG       TO wallet_eod;
GRANT EXECUTE ON FUNCTION  eod_log(DATE, VARCHAR, VARCHAR, BIGINT, TIMESTAMPTZ, TEXT) TO wallet_eod;
GRANT EXECUTE ON FUNCTION  eod_verify_chain(VARCHAR, DATE, DATE)        TO wallet_eod;
GRANT EXECUTE ON PROCEDURE eod_snapshot(DATE, BIGINT)                   TO wallet_eod;
GRANT EXECUTE ON PROCEDURE eod_prev_day_roll(DATE, BIGINT)              TO wallet_eod;
GRANT EXECUTE ON PROCEDURE eod_expire_restraints(DATE)                  TO wallet_eod;
GRANT EXECUTE ON PROCEDURE eod_trial_balance(DATE)                      TO wallet_eod;
GRANT EXECUTE ON PROCEDURE eod_mark_failed(DATE, VARCHAR, TEXT)         TO wallet_eod;
GRANT EXECUTE ON PROCEDURE run_eod(DATE)                                TO wallet_eod;

-- Make the proof immutable to the online app role: it keeps SELECT (and
-- eod_verify_chain, read-only) but can no longer write or re-run EOD.
REVOKE INSERT, UPDATE, DELETE ON WLT_TRIAL_BALANCE       FROM wallet_app;
REVOKE INSERT, UPDATE, DELETE ON WLT_TRIAL_BALANCE_PROOF FROM wallet_app;
REVOKE EXECUTE ON PROCEDURE run_eod(DATE)                     FROM wallet_app;
REVOKE EXECUTE ON PROCEDURE eod_snapshot(DATE, BIGINT)        FROM wallet_app;
REVOKE EXECUTE ON PROCEDURE eod_prev_day_roll(DATE, BIGINT)   FROM wallet_app;
REVOKE EXECUTE ON PROCEDURE eod_expire_restraints(DATE)       FROM wallet_app;
REVOKE EXECUTE ON PROCEDURE eod_trial_balance(DATE)           FROM wallet_app;
REVOKE EXECUTE ON PROCEDURE eod_mark_failed(DATE, VARCHAR, TEXT) FROM wallet_app;

-- ─────────────────────────────────────────────────────────────────────────
-- B#3 — schedule EOD via pg_cron (native on RDS/Aurora; guarded)
-- ─────────────────────────────────────────────────────────────────────────
-- DB tz is Asia/Ho_Chi_Minh (UTC+7). pg_cron schedules in UTC, so 17:05 UTC ≈
-- 00:05 local — runs run_eod for the just-closed business day, then verifies the
-- chain. On RDS: add pg_cron to shared_preload_libraries, set cron.database_name
-- = 'wallet', and run the job as wallet_eod (cron.schedule_in_database / job
-- role). Where pg_cron is absent (e.g. local docker), wire an external scheduler:
--     psql "host=primary user=wallet_eod dbname=wallet" -c "CALL run_eod((now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date - 1)"
-- EOD MUST run on a DIRECT primary connection (bypass PgBouncer): its procedures
-- COMMIT between chunks and set a session GUC, which txn-mode pooling breaks.
DO $do$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule('wallet-eod-daily', '5 17 * * *',
      $cmd$ CALL run_eod((now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date - 1) $cmd$);
    PERFORM cron.schedule('wallet-eod-verify-vnd', '20 17 * * *',
      $cmd$ SELECT * FROM eod_verify_chain('VND', NULL, NULL) $cmd$);
    RAISE NOTICE 'B#3: pg_cron schedules wallet-eod-daily / wallet-eod-verify-vnd created';
  ELSE
    RAISE NOTICE 'B#3: pg_cron not installed — schedule run_eod externally as role wallet_eod on a direct primary connection (see comment above)';
  END IF;
END
$do$;

COMMIT;
