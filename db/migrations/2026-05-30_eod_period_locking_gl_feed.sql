-- =============================================================================
-- 2026-05-30_eod_period_locking_gl_feed.sql — Incremental migration
-- (tracked incremental migrations live in db/migrations/)
-- =============================================================================
-- EOD period locking + GL-feed post (US-6.1 / US-6.2; unblocks US-3.7). Idempotent:
-- safe to re-run. Depends on 2026-05-30_ledger_integrity_hardening.sql (the
-- wallet_eod role + the trial-balance tables it hardens).
--
--   1. WLT_PERIOD — one row per CLOSED business date (the accounting-period
--      high-water mark).
--   2. Write-freeze — BEFORE INSERT triggers on WLT_BATCH + WLT_TRAN_HIST that
--      reject any ledger/GL row dated into a closed period (POST_DATE <= the
--      latest closed date). This is the period lock: a sealed day's trial balance
--      + hash chain (US-6.3) become immutable, and a cross-period reversal
--      (US-3.7) provably lands in the OPEN period (reversals post POST_DATE =
--      CURRENT_DATE, always > the high-water mark once a day is closed AFTER its
--      midnight roll). Normal postings (POST_DATE = CURRENT_DATE) never trip it.
--   3. GL-feed post — wallet_eod gains column-scoped UPDATE on WLT_BATCH so the
--      EOD GL feed can mark a day's legs 'P' → 'S' (eod_gl_feed_post, T3).
--   4. Hardening — the close batch (eod_gl_feed_post / eod_close_period) and the
--      ability to mutate WLT_PERIOD move to wallet_eod; wallet_app keeps only the
--      SELECT + EXECUTE the freeze trigger needs on its (online) posting path.
--
-- The procedure bodies (eod_gl_feed_post, eod_close_period, the reordered
-- run_eod) live in db/procedures/wallet_sp_eod.sql — re-apply that file as part
-- of this deploy. WLT_PERIOD + the freeze functions/triggers are mirrored here so
-- the freeze is active even before the SP file is reloaded; keep both in sync.
-- =============================================================================
\set ON_ERROR_STOP on
BEGIN;

-- ─────────────────────────────────────────────────────────────────────────
-- 1 — period control table + high-water mark
-- ─────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS WLT_PERIOD (
  biz_date   DATE         NOT NULL,
  status     VARCHAR(8)   NOT NULL DEFAULT 'CLOSED',   -- OPEN | CLOSED
  closed_at  TIMESTAMPTZ  NOT NULL DEFAULT now(),
  closed_by  VARCHAR(64)  NOT NULL DEFAULT 'EOD',
  note       TEXT,
  CONSTRAINT pk_period     PRIMARY KEY (biz_date),
  CONSTRAINT chk_period_st CHECK (status IN ('OPEN','CLOSED'))
);
CREATE INDEX IF NOT EXISTS idx_period_closed ON WLT_PERIOD (biz_date DESC) WHERE status = 'CLOSED';

-- ─────────────────────────────────────────────────────────────────────────
-- 2 — write-freeze functions + triggers (mirror of wallet_sp_eod.sql)
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_period_closed_through()
RETURNS DATE
LANGUAGE sql STABLE AS $$
  SELECT max(biz_date) FROM WLT_PERIOD WHERE status = 'CLOSED';
$$;

-- Full-immutability guard: a sealed day's rows can no longer be INSERTed,
-- UPDATEd, or DELETEd. The EOD GL-feed post (P→S) UPDATEs while the day is still
-- OPEN (T3 before the T7 close), so it is not blocked. TRUNCATE bypasses row
-- triggers (test-data reset); a row-level DELETE of a sealed day is blocked.
CREATE OR REPLACE FUNCTION fn_freeze_closed_period()
RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public, pg_catalog AS $fn$
DECLARE
  v_through DATE := fn_period_closed_through();
BEGIN
  IF v_through IS NULL THEN
    RETURN COALESCE(NEW, OLD);
  END IF;
  IF TG_OP IN ('UPDATE','DELETE') AND OLD.POST_DATE <= v_through THEN
    RAISE EXCEPTION 'PERIOD_CLOSED: % blocked — row is in a closed period (post_date %, closed through %)',
      TG_OP, OLD.POST_DATE, v_through USING ERRCODE = 'P0092';
  END IF;
  IF TG_OP IN ('INSERT','UPDATE') AND NEW.POST_DATE <= v_through THEN
    RAISE EXCEPTION 'PERIOD_CLOSED: post_date % is in a closed period (closed through %)',
      NEW.POST_DATE, v_through USING ERRCODE = 'P0092';
  END IF;
  RETURN COALESCE(NEW, OLD);
END
$fn$;

DROP TRIGGER IF EXISTS trg_freeze_batch ON WLT_BATCH;
CREATE TRIGGER trg_freeze_batch
  BEFORE INSERT OR UPDATE OR DELETE ON WLT_BATCH
  FOR EACH ROW EXECUTE FUNCTION fn_freeze_closed_period();

DROP TRIGGER IF EXISTS trg_freeze_hist ON WLT_TRAN_HIST;
CREATE TRIGGER trg_freeze_hist
  BEFORE INSERT OR UPDATE OR DELETE ON WLT_TRAN_HIST
  FOR EACH ROW EXECUTE FUNCTION fn_freeze_closed_period();

-- ─────────────────────────────────────────────────────────────────────────
-- 3 + 4 — role hardening (only where the wallet_eod role exists)
-- ─────────────────────────────────────────────────────────────────────────
DO $do$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'wallet_eod') THEN
    -- EOD reads + seals periods, and finalises the GL feed (column-scoped UPDATE
    -- so it can flip STATUS but never rewrite an amount).
    GRANT SELECT, INSERT, UPDATE        ON WLT_PERIOD            TO wallet_eod;
    GRANT UPDATE (STATUS, TIME_STAMP)   ON WLT_BATCH             TO wallet_eod;
    GRANT EXECUTE ON FUNCTION fn_period_closed_through()         TO wallet_eod;
  END IF;
END
$do$;

-- The online app role only needs to READ the high-water mark (the freeze trigger
-- evaluates on its posting path); it must NOT be able to seal/reopen periods.
GRANT SELECT ON WLT_PERIOD                          TO wallet_app;
GRANT EXECUTE ON FUNCTION fn_period_closed_through() TO wallet_app;
REVOKE INSERT, UPDATE, DELETE ON WLT_PERIOD         FROM wallet_app;

-- Procedure grants/revokes are guarded: the bodies arrive with the SP-file
-- reload, which may run before or after this migration.
DO $do$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'eod_gl_feed_post') THEN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'wallet_eod') THEN
      GRANT EXECUTE ON PROCEDURE eod_gl_feed_post(DATE, BIGINT) TO wallet_eod;
    END IF;
    REVOKE EXECUTE ON PROCEDURE eod_gl_feed_post(DATE, BIGINT)  FROM wallet_app;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'eod_close_period') THEN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'wallet_eod') THEN
      GRANT EXECUTE ON PROCEDURE eod_close_period(DATE) TO wallet_eod;
    END IF;
    REVOKE EXECUTE ON PROCEDURE eod_close_period(DATE)  FROM wallet_app;
  END IF;
  RAISE NOTICE 'period-locking + GL-feed migration applied; re-apply db/procedures/wallet_sp_eod.sql for the procedure bodies (eod_gl_feed_post, eod_close_period, reordered run_eod)';
END
$do$;

COMMIT;
