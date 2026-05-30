-- =============================================================================
-- 2026-05-30_set_db_timezone.sql — Pin the database timezone to GMT+7
-- =============================================================================
-- Purpose:  Make CURRENT_DATE / now() / accounting dates (POST_DATE, VALUE_DATE,
--           …) depend on a FIXED business timezone — Asia/Ho_Chi_Minh (GMT+7,
--           no DST) — instead of the host/container OS timezone.
--
-- Why DB-level (not just container TZ env):
--   - Survives migrating to a cluster whose OS runs UTC (would otherwise shift
--     entries booked 00:00–07:00 local to the previous accounting day).
--   - Inherited by every backend on connect → safe under PgBouncer transaction
--     -mode pooling (unlike a per-session `SET TimeZone`, which is unreliable
--     when a connection is handed to another client after COMMIT).
--   - pg_dump (single DB) does NOT carry ALTER DATABASE settings, so this must
--     be applied explicitly on every target.
--
-- Effect:   Applies to NEW sessions only. Reconnect (or bounce PgBouncer's
--           server pool) for existing connections to pick it up.
-- Idempotent: safe to re-run. DB-name-agnostic (uses current_database()).
-- Target:   PostgreSQL 17+
-- =============================================================================

\set ON_ERROR_STOP on

DO $$
BEGIN
  EXECUTE format('ALTER DATABASE %I SET timezone = %L',
                 current_database(), 'Asia/Ho_Chi_Minh');
END $$;

-- Verify (run in a NEW psql session after applying):
--   SHOW timezone;                       -- expect Asia/Ho_Chi_Minh
--   SELECT now(), current_date;          -- expect +07 offset / VN calendar date
