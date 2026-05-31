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
--   wlt_client_audit_log   RANGE (changed_at)   → monthly
--   wlt_tran_hist          RANGE (post_date)    → monthly, EACH month sub-
--                          partitioned HASH (internal_key) modulus 32
--   + a DEFAULT catch-all on each parent (out-of-range cliff guard)
--
-- fn_ensure_wallet_partitions(from, to) is idempotent (CREATE … IF NOT EXISTS) and
-- re-runnable: call it from a scheduler to roll partitions forward each month.
-- Date-string bounds cast cleanly to both DATE and TIMESTAMPTZ partition keys.
-- =============================================================================
\set ON_ERROR_STOP on

CREATE OR REPLACE FUNCTION fn_ensure_wallet_partitions(p_from date, p_to date)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  c_hash_modulus constant int := 32;   -- hash sub-partitions per wlt_tran_hist month
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
      'CREATE TABLE IF NOT EXISTS public.wlt_client_audit_log_%s PARTITION OF public.wlt_client_audit_log FOR VALUES FROM (%L) TO (%L)',
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

-- DEFAULT (catch-all) partitions — one per parent, created once. Keep them EMPTY
-- in production by pre-creating monthly partitions ahead of time (call the
-- function below on a schedule); a DEFAULT holding rows blocks adding a new
-- partition over that range until the rows are moved.
CREATE TABLE IF NOT EXISTS public.wlt_acct_bal_default         PARTITION OF public.wlt_acct_bal         DEFAULT;
CREATE TABLE IF NOT EXISTS public.wlt_outbox_default           PARTITION OF public.wlt_outbox           DEFAULT;
CREATE TABLE IF NOT EXISTS public.wlt_client_audit_log_default PARTITION OF public.wlt_client_audit_log DEFAULT;
CREATE TABLE IF NOT EXISTS public.wlt_tran_hist_default        PARTITION OF public.wlt_tran_hist        DEFAULT;

-- Initial window: 2026-05 .. 2026-10 inclusive (matches the prior baked schema).
-- Adjust / re-run as time rolls forward (e.g. monthly: SELECT
-- fn_ensure_wallet_partitions(date_trunc('month', now())::date,
--                             (date_trunc('month', now()) + interval '3 months')::date);)
SELECT fn_ensure_wallet_partitions('2026-05-01', '2026-11-01');
