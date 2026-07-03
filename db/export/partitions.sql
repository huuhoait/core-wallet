-- =============================================================================
-- partitions.sql — create the time-based partitions for the 4 partitioned parents
-- =============================================================================
-- Run AFTER schema.sql (which defines the parents + their partitioned indexes and
-- row triggers — both propagate to partitions automatically, so this file only
-- creates the partition tables themselves).
--
-- Layout (matches the design captured by the former hardcoded partitions):
--   wlt_acct_bal           RANGE (tran_date)    → monthly
--   wlt_outbox             RANGE (created_at)   → monthly
--   fm_client_audit_log   RANGE (changed_at)   → monthly
--   wlt_tran_hist          RANGE (post_date)    → monthly, EACH month sub-
--                          partitioned HASH (internal_key) modulus 8
--   + a DEFAULT catch-all on each parent (out-of-range cliff guard)
--
-- fn_ensure_wallet_partitions(from, to) is idempotent (CREATE … IF NOT EXISTS) and
-- re-runnable: call it from a scheduler to roll partitions forward each month.
-- Date-string bounds cast cleanly to both DATE and TIMESTAMPTZ partition keys.
-- =============================================================================
\set ON_ERROR_STOP on

-- SECURITY DEFINER: creating a child partition requires ownership of the parent
-- table, which wallet_app does not hold (it has only DML grants). The function is
-- owned by the superuser that restores this file (which owns the parents), so as
-- DEFINER it can CREATE the partitions while the caller needs only EXECUTE. This
-- lets the in-process partition roll-forward janitor call it as wallet_app on the
-- ordinary app pool — no DDL privilege is granted to wallet_app itself. Pin
-- search_path (mirrors every other SECURITY DEFINER function in schema.sql) so a
-- caller-controlled path cannot hijack an unqualified name inside the body.
CREATE OR REPLACE FUNCTION fn_ensure_wallet_partitions(p_from date, p_to date)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $$
DECLARE
  c_hash_modulus constant int := 8;    -- hash sub-partitions per wlt_tran_hist month
                                        -- (was 32: cut to 8 to reduce the partition
                                        -- count → less plan/catalog overhead per posting
                                        -- and smaller Append fan-out on any query that
                                        -- can't prune by internal_key)
  m  date := date_trunc('month', p_from)::date;
  nm date;
  sfx text;
  h  int;
BEGIN
  WHILE m < p_to LOOP
    nm  := (m + interval '1 month')::date;
    sfx := to_char(m, 'YYYY_MM');

    -- plain monthly RANGE partitions (indexes/triggers inherit from the parent)
    EXECUTE format(
      'CREATE TABLE IF NOT EXISTS public.wlt_acct_bal_%s PARTITION OF public.wlt_acct_bal FOR VALUES FROM (%L) TO (%L)',
      sfx, m, nm);
    EXECUTE format(
      'CREATE TABLE IF NOT EXISTS public.wlt_outbox_%s PARTITION OF public.wlt_outbox FOR VALUES FROM (%L) TO (%L)',
      sfx, m, nm);
    EXECUTE format(
      'CREATE TABLE IF NOT EXISTS public.fm_client_audit_log_%s PARTITION OF public.fm_client_audit_log FOR VALUES FROM (%L) TO (%L)',
      sfx, m, nm);

    -- wlt_tran_hist month: itself HASH-subpartitioned by internal_key
    EXECUTE format(
      'CREATE TABLE IF NOT EXISTS public.wlt_tran_hist_%s PARTITION OF public.wlt_tran_hist FOR VALUES FROM (%L) TO (%L) PARTITION BY HASH (internal_key)',
      sfx, m, nm);
    FOR h IN 0 .. c_hash_modulus - 1 LOOP
      EXECUTE format(
        'CREATE TABLE IF NOT EXISTS public.wlt_tran_hist_%s_h%s PARTITION OF public.wlt_tran_hist_%s FOR VALUES WITH (modulus %s, remainder %s)',
        sfx, lpad(h::text, 2, '0'), sfx, c_hash_modulus, h);
    END LOOP;

    m := nm;
  END LOOP;
END $$;

-- Let wallet_app EXECUTE the roller (it runs as DEFINER, above). This GRANT lives
-- HERE, not in schema.sql's ACL block, because docker-init loads schema.sql FIRST
-- (01-schema) — the function does not exist until this file (02-partitions) runs,
-- so a GRANT in schema.sql would fail with "function does not exist". Being
-- explicit also survives a future `REVOKE EXECUTE ON ALL FUNCTIONS ... FROM PUBLIC`
-- hardening pass (the roller keeps working; PUBLIC loses the implicit grant).
GRANT EXECUTE ON FUNCTION public.fn_ensure_wallet_partitions(p_from date, p_to date) TO wallet_app;

-- DEFAULT (catch-all) partitions — one per parent, created once. Keep them EMPTY
-- in production by pre-creating monthly partitions ahead of time (call the
-- function below on a schedule); a DEFAULT holding rows blocks adding a new
-- partition over that range until the rows are moved.
CREATE TABLE IF NOT EXISTS public.wlt_acct_bal_default         PARTITION OF public.wlt_acct_bal         DEFAULT;
CREATE TABLE IF NOT EXISTS public.wlt_outbox_default           PARTITION OF public.wlt_outbox           DEFAULT;
CREATE TABLE IF NOT EXISTS public.fm_client_audit_log_default PARTITION OF public.fm_client_audit_log DEFAULT;
CREATE TABLE IF NOT EXISTS public.wlt_tran_hist_default        PARTITION OF public.wlt_tran_hist        DEFAULT;

-- Initial window: 2026-05 .. 2027-04 inclusive (12 months). Widened from the
-- former 6-month baseline (…2026-10) so a fresh restore ships a full year of
-- runway even before the roller ticks — the old window put the DEFAULT-partition
-- cliff at 2026-11-01. The DURABLE fix is the recurring roll-forward: the
-- in-process partition janitor (janitor.NewPartition) re-runs this every day to
-- keep >= PARTITION_LOOKAHEAD_MONTHS months of partitions ahead, e.g.:
--   SELECT fn_ensure_wallet_partitions(date_trunc('month', now())::date,
--          (date_trunc('month', now()) + interval '3 months')::date);
-- It is idempotent (CREATE … IF NOT EXISTS), so many replicas may run it safely.
SELECT fn_ensure_wallet_partitions('2026-05-01', '2027-05-01');
