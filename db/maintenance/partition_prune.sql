-- =============================================================================
-- partition_prune.sql — registry-driven, dry-run-default partition pruning
-- =============================================================================
-- Drops time-range partitions older than a per-table retention window, for the
-- 4 partitioned parents (wlt_outbox, wlt_acct_bal, wlt_tran_hist,
-- fm_client_audit_log). Counterpart to fn_ensure_wallet_partitions (partitions.sql).
--
-- 🔴 SAFETY (financial ledger):
--   * A table is pruned ONLY if it is registered AND enabled=true AND protected=false.
--   * protected=true is a HARD STOP — used for compliance tables that hold legal
--     records (wlt_tran_hist = the ledger; fm_client_audit_log = KYC/identity audit,
--     US-8.1). These must NEVER be auto-dropped (regulatory retention, years).
--   * fn_prune_wallet_partitions(p_dry_run) defaults to DRY RUN — it lists what it
--     WOULD drop and writes a DRY_RUN log row, but drops nothing. You must call it
--     with p_dry_run => false to actually DROP.
--   * The DEFAULT catch-all partition is never touched.
--   * Every action (DRY_RUN / DROPPED) is logged to WLT_PARTITION_PRUNE_LOG.
--
-- Idempotent: safe to re-run (CREATE IF NOT EXISTS / CREATE OR REPLACE / ON CONFLICT).
-- Run as a role that owns (can DROP) the partitions — e.g. the DB owner / a
-- dedicated maintenance role; schedule monthly after fn_ensure_wallet_partitions.
-- =============================================================================
\set ON_ERROR_STOP on

-- ── retention registry (one row per partitioned parent) ──────────────────────
CREATE TABLE IF NOT EXISTS WLT_RETENTION_POLICY (
  parent_table     text        PRIMARY KEY,
  retention_months int         NOT NULL CHECK (retention_months >= 1),
  enabled          boolean     NOT NULL DEFAULT false,  -- opt-in to be pruned at all
  protected        boolean     NOT NULL DEFAULT false,  -- compliance HARD STOP: never prune
  note             text,
  updated_at       timestamptz NOT NULL DEFAULT now()
);

-- ── append-only audit of what was pruned (or would be, on dry run) ───────────
CREATE TABLE IF NOT EXISTS WLT_PARTITION_PRUNE_LOG (
  log_id       bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  parent_table text        NOT NULL,
  partition    text        NOT NULL,
  upper_bound  date,
  action       text        NOT NULL CHECK (action IN ('DRY_RUN','DROPPED')),
  pruned_at    timestamptz NOT NULL DEFAULT now(),
  pruned_by    text        NOT NULL DEFAULT current_user
);
CREATE INDEX IF NOT EXISTS idx_prune_log_time ON WLT_PARTITION_PRUNE_LOG (pruned_at DESC);

-- ── safe default policy ──────────────────────────────────────────────────────
-- Only the transient outbox is enabled. The ledger + KYC audit are PROTECTED.
-- Balance snapshots are registered but DISABLED (turn on once a retention is agreed).
INSERT INTO WLT_RETENTION_POLICY (parent_table, retention_months, enabled, protected, note) VALUES
  ('wlt_outbox',          2,   true,  false, 'transient delivery: drop once relayed + aged out of dedup/replay window'),
  ('wlt_acct_bal',        24,  false, false, 'derived daily snapshots: enable after retention sign-off'),
  ('wlt_tran_hist',       120, false, true,  'LEDGER — regulatory retention; PROTECTED, never auto-drop'),
  ('fm_client_audit_log', 120, false, true,  'KYC/identity change audit (US-8.1) — PROTECTED, never auto-drop')
ON CONFLICT (parent_table) DO NOTHING;

-- ── the prune function ───────────────────────────────────────────────────────
-- HOW IT WORKS (step by step):
--
--   1. Loop over the registry, taking ONLY rows that are opted in to pruning:
--      enabled = true AND protected = false. (So a compliance table — protected —
--      or a not-yet-approved one — disabled — is never even looked at.)
--
--   2. For each such parent, compute a CUTOFF date:
--          cutoff = first-day-of-this-month  −  retention_months
--      A partition is prunable only if its WHOLE range sits strictly before the
--      cutoff. Using first-of-month (not "now") makes the result stable within a
--      month and keeps `retention_months` whole calendar months of data.
--      e.g. now = 2026-06-04, retention = 2  →  cutoff = 2026-04-01
--           ⇒ keep Apr/May/Jun; anything ending on/before Apr-01 is prunable.
--
--   3. Enumerate that parent's child partitions from the catalog (pg_inherits →
--      pg_class). For each child read its bound text via pg_get_expr(relpartbound):
--          range  : FOR VALUES FROM ('2026-05-01') TO ('2026-06-01')
--          default: DEFAULT
--      - Skip the DEFAULT catch-all (never dropped).
--      - Parse the partition's UPPER bound (the YYYY-MM-DD after "TO") — this is
--        exclusive, i.e. the first instant NOT in the partition. Works for both a
--        DATE key and a TIMESTAMPTZ key (we capture only the date prefix).
--
--   4. Decide: if upper_bound <= cutoff the entire partition is older than the
--      retention window ⇒ it is a candidate. (upper_bound > cutoff ⇒ still within
--      retention ⇒ skip.)
--
--   5. Act on the candidate:
--      - DRY RUN (default): record action 'DRY_RUN', drop NOTHING.
--      - real run (p_dry_run=false): DROP TABLE the partition. For wlt_tran_hist
--        a monthly partition is itself HASH-subpartitioned, so dropping the month
--        cascades to its _h00.._h07 children automatically.
--      Either way, append a row to WLT_PARTITION_PRUNE_LOG and RETURN NEXT so the
--      caller sees exactly what happened.
--
-- Net effect: a safe, auditable "drop whole months that aged out", driven entirely
-- by the registry — no table name is hard-coded in the logic.
--
-- Returns one row per partition it dropped (or would drop, on dry run).
CREATE OR REPLACE FUNCTION fn_prune_wallet_partitions(p_dry_run boolean DEFAULT true)
RETURNS TABLE(parent_table text, partition text, upper_bound date, action text)
LANGUAGE plpgsql AS $fn$
DECLARE
  pol   record;
  part  record;
  v_cut date;
  v_up  date;
  v_act text;
BEGIN
  FOR pol IN
    SELECT p.parent_table, p.retention_months
      FROM wlt_retention_policy p
     WHERE p.enabled AND NOT p.protected
     ORDER BY p.parent_table
  LOOP
    -- cutoff: a partition whose ENTIRE range is strictly before this date is prunable.
    v_cut := (date_trunc('month', now()) - make_interval(months => pol.retention_months))::date;

    FOR part IN
      SELECT c.relname AS name, pg_get_expr(c.relpartbound, c.oid) AS bound
        FROM pg_inherits i
        JOIN pg_class c ON c.oid = i.inhrelid
        JOIN pg_class p ON p.oid = i.inhparent
       WHERE p.relname = pol.parent_table
       ORDER BY c.relname
    LOOP
      CONTINUE WHEN part.bound = 'DEFAULT';                 -- never drop the catch-all
      -- RANGE bound looks like  FOR VALUES FROM ('2026-05-01') TO ('2026-06-01')
      -- (DATE key) or  … TO ('2026-06-01 00:00:00+07')  (TIMESTAMPTZ key). Capture
      -- the YYYY-MM-DD prefix of the upper bound in both cases.
      v_up := substring(part.bound from 'TO \(''([0-9]{4}-[0-9]{2}-[0-9]{2})')::date;
      CONTINUE WHEN v_up IS NULL OR v_up > v_cut;           -- still within retention

      IF p_dry_run THEN
        v_act := 'DRY_RUN';
      ELSE
        EXECUTE format('DROP TABLE IF EXISTS public.%I', part.name);
        v_act := 'DROPPED';
      END IF;

      INSERT INTO wlt_partition_prune_log(parent_table, partition, upper_bound, action)
        VALUES (pol.parent_table, part.name, v_up, v_act);

      parent_table := pol.parent_table;
      partition    := part.name;
      upper_bound  := v_up;
      action       := v_act;
      RETURN NEXT;
    END LOOP;
  END LOOP;
END
$fn$;

-- ── in-DB documentation (visible via \df+ / \d+) ─────────────────────────────
COMMENT ON FUNCTION fn_prune_wallet_partitions(boolean) IS
  'Registry-driven partition pruning. For each WLT_RETENTION_POLICY row with '
  'enabled=true AND protected=false: drops child partitions whose upper bound is '
  '<= (first-of-month - retention_months). DEFAULT partition never touched; every '
  'action logged to WLT_PARTITION_PRUNE_LOG. p_dry_run=true (default) previews '
  'only; pass false to DROP. Run as a role that can DROP the partitions.';
COMMENT ON TABLE  WLT_RETENTION_POLICY IS
  'Retention registry: one row per partitioned parent. A table is pruned ONLY if '
  'enabled AND NOT protected.';
COMMENT ON COLUMN WLT_RETENTION_POLICY.enabled   IS 'Opt-in: false = never pruned (looked at).';
COMMENT ON COLUMN WLT_RETENTION_POLICY.protected IS 'Compliance HARD STOP: true = never pruned, even if enabled (ledger / KYC audit).';
COMMENT ON COLUMN WLT_RETENTION_POLICY.retention_months IS 'Whole calendar months of data to keep; cutoff = first-of-month - this.';
COMMENT ON TABLE  WLT_PARTITION_PRUNE_LOG IS 'Append-only audit of every prune (DRY_RUN preview or real DROPPED).';

-- ── usage ────────────────────────────────────────────────────────────────────
--   SELECT * FROM fn_prune_wallet_partitions();        -- DRY RUN (default): preview
--   SELECT * FROM fn_prune_wallet_partitions(false);   -- actually DROP
--   -- enable balance pruning once a retention is agreed:
--   UPDATE wlt_retention_policy SET enabled = true, retention_months = 24,
--          updated_at = now() WHERE parent_table = 'wlt_acct_bal';
--   -- schedule monthly (after rolling partitions forward), e.g. pg_cron:
--   --   SELECT fn_ensure_wallet_partitions(...);  then  fn_prune_wallet_partitions(false);
