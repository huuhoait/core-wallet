-- =============================================================================
-- wallet_sp_eod.sql — End-of-Day batch (write/primary DB, posting-safe)
-- =============================================================================
-- The wallet is 24/7 (no downtime window): EOD runs CONCURRENTLY with realtime
-- posting. Every task is therefore split into short transactions (COMMIT per
-- chunk) so it never:
--   * pins the xmin horizon for long (a long TX would starve autovacuum on the
--     hot WLT_ACCT and let it bloat), and
--   * holds row locks that block posting's Phase-2 balance UPDATE.
--
-- All procedures are RESTART-SAFE: progress is checkpointed to WLT_EOD_RUN
-- (last_key cursor) and writes are idempotent (ON CONFLICT / re-derivable), so a
-- crashed EOD resumes from the last committed chunk instead of redoing work.
--
--   eod_snapshot(D)          T1  WLT_ACCT_BAL[D] — sparse, ledger-derived close.
--                                Reads the FROZEN WLT_TRAN_HIST[D] (last leg per
--                                account), NOT the hot WLT_ACCT.actual_bal (which
--                                under 24/7 already holds D+1 intraday movement).
--   eod_prev_day_roll(D)     T2  WLT_ACCT.prev_day_actual_bal := close(D).
--                                Sparse (only accounts in the snapshot), chunked
--                                10k, HOT update (prev_day_actual_bal is in no
--                                index), depends on T1.
--   eod_expire_restraints(D) T5  Auto-expire WLT_RESTRAINTS past END_DATE and
--                                recompute the few affected WLT_ACCT aggregates.
--   run_eod(D)                   Orchestrator: T1 → T2 → T5 in dependency order.
--
-- These are PROCEDURES (not functions) because they COMMIT between chunks. Call
-- them at TOP LEVEL only (psql -c / external scheduler / pg_cron >= 1.4), never
-- inside an explicit transaction, and over a DIRECT primary connection — NOT via
-- PgBouncer transaction-mode, which cannot carry transaction control across the
-- pool. Schedule at the low-traffic trough; ops may add throttling between
-- chunks at the scheduler layer if posting QPS is still high.
--
-- In production, run under a dedicated batch role (e.g. wallet_eod) rather than
-- wallet_app; the GRANTs below target wallet_app so the existing local stack can
-- exercise it. Custom SQLSTATE class P009x (EOD).
-- =============================================================================

-- ── control / checkpoint table ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS WLT_EOD_RUN (
  biz_date    DATE         NOT NULL,
  task        VARCHAR(24)  NOT NULL,
  status      VARCHAR(12)  NOT NULL DEFAULT 'RUNNING',   -- RUNNING | DONE | FAILED
  last_key    BIGINT       NOT NULL DEFAULT 0,           -- resume cursor (internal_key)
  rows_done   BIGINT       NOT NULL DEFAULT 0,
  started_at  TIMESTAMPTZ  NOT NULL DEFAULT now(),
  finished_at TIMESTAMPTZ,
  message     TEXT,
  CONSTRAINT pk_eod_run    PRIMARY KEY (biz_date, task),
  CONSTRAINT chk_eod_status CHECK (status IN ('RUNNING','DONE','FAILED'))
);

-- ── append-only audit trail ─────────────────────────────────────────────────
-- WLT_EOD_RUN holds live state + the resume cursor (one mutable row per task).
-- WLT_EOD_AUDIT_LOG is the immutable history: one row appended per completed run
-- (DONE) or per failure (FAILED), so re-runs leave a trace instead of overwriting.
CREATE TABLE IF NOT EXISTS WLT_EOD_AUDIT_LOG (
  log_id      BIGINT      GENERATED ALWAYS AS IDENTITY,
  biz_date    DATE         NOT NULL,
  task        VARCHAR(24)  NOT NULL,
  status      VARCHAR(12)  NOT NULL,                    -- DONE | FAILED
  rows_done   BIGINT       NOT NULL DEFAULT 0,
  started_at  TIMESTAMPTZ  NOT NULL,
  finished_at TIMESTAMPTZ  NOT NULL,
  duration    INTERVAL     GENERATED ALWAYS AS (finished_at - started_at) STORED,
  actor       VARCHAR(64)  NOT NULL DEFAULT 'EOD',
  message     TEXT,
  CONSTRAINT pk_eod_log     PRIMARY KEY (log_id),
  CONSTRAINT chk_eod_log_st CHECK (status IN ('DONE','FAILED'))
);
CREATE INDEX IF NOT EXISTS idx_eod_log_date ON WLT_EOD_AUDIT_LOG (biz_date, task, started_at DESC);

-- eod_log — append one audit-trail row. Plain SQL (no transaction control), so
-- it is callable via PERFORM from inside the COMMIT-looping procedures.
CREATE OR REPLACE FUNCTION eod_log(
  p_biz_date DATE,
  p_task     VARCHAR,
  p_status   VARCHAR,
  p_rows     BIGINT,
  p_started  TIMESTAMPTZ,
  p_message  TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE sql
AS $$
  INSERT INTO WLT_EOD_AUDIT_LOG(biz_date, task, status, rows_done, started_at, finished_at, message)
  VALUES (p_biz_date, p_task, p_status, p_rows, p_started, clock_timestamp(), p_message);
$$;

-- =============================================================================
-- T1 — daily balance snapshot  →  WLT_ACCT_BAL[D]
-- =============================================================================
-- Sparse: only accounts that MOVED on D (a leg with post_date = D). The posting
-- SPs already maintain WLT_ACCT_BAL[D] intraday (INSERT..ON CONFLICT DO UPDATE on
-- every leg), so this task FINALISES that row at the cut rather than recreating it:
--   * actual_bal := the immutable-ledger close (last leg of D) — the only
--     24/7-correct close, and a reconciliation against any drift in the cache;
--   * calc_bal   := close - FINAL restraint overlay (posting's calc_bal is stale
--     if a restraint was added/released after the last leg);
--   * prev_actual_bal (day-open, captured by posting on the first leg) is kept.
-- Reads of WLT_ACCT here are plain SELECTs (MVCC: never block posting).
CREATE OR REPLACE PROCEDURE eod_snapshot(p_biz_date DATE, p_step BIGINT DEFAULT 50000)
LANGUAGE plpgsql
AS $$
DECLARE
  v_lo      BIGINT;
  v_max     BIGINT;
  v_n       BIGINT;
  v_tot     BIGINT := 0;
  v_started TIMESTAMPTZ := clock_timestamp();
BEGIN
  IF p_biz_date IS NULL OR p_biz_date > CURRENT_DATE THEN
    RAISE EXCEPTION 'EOD_INVALID_DATE: %', p_biz_date USING ERRCODE = 'P0090';
  END IF;
  PERFORM set_config('audit.actor', 'EOD', false);   -- session-scoped: survives COMMITs

  -- claim or resume the control row (does NOT reset last_key on resume)
  INSERT INTO WLT_EOD_RUN(biz_date, task, status, last_key, started_at)
       VALUES (p_biz_date, 'SNAPSHOT', 'RUNNING', 0, now())
  ON CONFLICT (biz_date, task)
       DO UPDATE SET status = 'RUNNING', started_at = now(), message = NULL;

  SELECT last_key, rows_done INTO v_lo, v_tot
    FROM WLT_EOD_RUN WHERE biz_date = p_biz_date AND task = 'SNAPSHOT';
  SELECT COALESCE(max(internal_key), 0) INTO v_max FROM WLT_ACCT;

  WHILE v_lo <= v_max LOOP
    WITH last_leg AS (
      SELECT DISTINCT ON (h.internal_key) h.internal_key, h.actual_bal_amt
        FROM WLT_TRAN_HIST h
       WHERE h.post_date = p_biz_date
         AND h.internal_key >  v_lo
         AND h.internal_key <= v_lo + p_step
       ORDER BY h.internal_key, h.seq_no DESC      -- last leg of the day
    )
    INSERT INTO WLT_ACCT_BAL(internal_key, tran_date, actual_bal, calc_bal,
                             prev_actual_bal, prev_calc_bal)
    SELECT l.internal_key,
           p_biz_date,
           l.actual_bal_amt,                                       -- close (ledger truth)
           l.actual_bal_amt - a.total_restrained_amt,              -- available (final overlay)
           a.prev_day_actual_bal,                                  -- INSERT-only: day-open
           a.prev_day_actual_bal                                   -- INSERT-only: prev available
      FROM last_leg l
      JOIN WLT_ACCT a ON a.internal_key = l.internal_key
    ON CONFLICT (internal_key, tran_date) DO UPDATE                -- finalise posting's row
       SET actual_bal    = EXCLUDED.actual_bal,
           calc_bal      = EXCLUDED.calc_bal,
           prev_calc_bal = COALESCE(WLT_ACCT_BAL.prev_calc_bal, WLT_ACCT_BAL.prev_actual_bal);
           -- prev_actual_bal NOT set: keep the day-open posting captured on leg 1

    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_tot := v_tot + v_n;
    v_lo  := v_lo + p_step;
    UPDATE WLT_EOD_RUN SET last_key = v_lo, rows_done = v_tot
      WHERE biz_date = p_biz_date AND task = 'SNAPSHOT';
    COMMIT;                                          -- short TX: release + advance xmin
  END LOOP;

  UPDATE WLT_EOD_RUN SET status = 'DONE', finished_at = now()
    WHERE biz_date = p_biz_date AND task = 'SNAPSHOT';
  PERFORM eod_log(p_biz_date, 'SNAPSHOT', 'DONE', v_tot, v_started);
  COMMIT;
END;
$$;

-- =============================================================================
-- T2 — roll WLT_ACCT.prev_day_actual_bal := close(D)
-- =============================================================================
-- The ONE task that writes the hot WLT_ACCT, so it is the most conservative:
-- chunk 10k, source = the snapshot just written by T1 (close of D), skip no-op
-- writes (IS DISTINCT FROM) to avoid dead tuples, and the column is in no index
-- so updates stay HOT (fillfactor 80 leaves in-page room). version is NOT bumped
-- — prev_day is a statistical field, not a balance change, and leaving it out
-- avoids contending with posting's optimistic-lock counter.
CREATE OR REPLACE PROCEDURE eod_prev_day_roll(p_biz_date DATE, p_step BIGINT DEFAULT 10000)
LANGUAGE plpgsql
AS $$
DECLARE
  v_lo      BIGINT;
  v_max     BIGINT;
  v_n       BIGINT;
  v_tot     BIGINT := 0;
  v_started TIMESTAMPTZ := clock_timestamp();
BEGIN
  IF p_biz_date IS NULL THEN
    RAISE EXCEPTION 'EOD_INVALID_DATE' USING ERRCODE = 'P0090';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM WLT_EOD_RUN
                  WHERE biz_date = p_biz_date AND task = 'SNAPSHOT' AND status = 'DONE') THEN
    RAISE EXCEPTION 'EOD_SNAPSHOT_NOT_DONE: run eod_snapshot(%) first', p_biz_date
      USING ERRCODE = 'P0091';
  END IF;
  PERFORM set_config('audit.actor', 'EOD', false);

  INSERT INTO WLT_EOD_RUN(biz_date, task, status, last_key, started_at)
       VALUES (p_biz_date, 'PREV_DAY_ROLL', 'RUNNING', 0, now())
  ON CONFLICT (biz_date, task)
       DO UPDATE SET status = 'RUNNING', started_at = now(), message = NULL;

  SELECT last_key, rows_done INTO v_lo, v_tot
    FROM WLT_EOD_RUN WHERE biz_date = p_biz_date AND task = 'PREV_DAY_ROLL';
  SELECT COALESCE(max(internal_key), 0) INTO v_max
    FROM WLT_ACCT_BAL WHERE tran_date = p_biz_date;

  WHILE v_lo <= v_max LOOP
    UPDATE WLT_ACCT a
       SET prev_day_actual_bal = b.actual_bal
      FROM WLT_ACCT_BAL b
     WHERE b.tran_date    = p_biz_date
       AND b.internal_key = a.internal_key
       AND b.internal_key >  v_lo
       AND b.internal_key <= v_lo + p_step
       AND a.prev_day_actual_bal IS DISTINCT FROM b.actual_bal;   -- skip no-op writes
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_tot := v_tot + v_n;
    v_lo  := v_lo + p_step;
    UPDATE WLT_EOD_RUN SET last_key = v_lo, rows_done = v_tot
      WHERE biz_date = p_biz_date AND task = 'PREV_DAY_ROLL';
    COMMIT;
  END LOOP;

  UPDATE WLT_EOD_RUN SET status = 'DONE', finished_at = now()
    WHERE biz_date = p_biz_date AND task = 'PREV_DAY_ROLL';
  PERFORM eod_log(p_biz_date, 'PREV_DAY_ROLL', 'DONE', v_tot, v_started);
  COMMIT;
END;
$$;

-- =============================================================================
-- T5 — auto-expire restraints past their END_DATE + recompute account aggregates
-- =============================================================================
-- A restraint with end_date = X is active THROUGH X (posting uses
-- CURRENT_DATE BETWEEN start_date AND end_date), so it expires once the business
-- date moves past it: end_date < D. The affected-account set is tiny (restraints
-- are rare), so we materialise the keys into an array and process one account per
-- TX (short lock on the hot row). Recompute mirrors release_restraint exactly so
-- WLT_ACCT.{total_restrained_amt, cr_blocked, restraint_present} stay correct.
CREATE OR REPLACE PROCEDURE eod_expire_restraints(p_biz_date DATE)
LANGUAGE plpgsql
AS $$
DECLARE
  v_keys    BIGINT[];
  v_key     BIGINT;
  v_n       BIGINT := 0;
  v_started TIMESTAMPTZ := clock_timestamp();
BEGIN
  IF p_biz_date IS NULL THEN
    RAISE EXCEPTION 'EOD_INVALID_DATE' USING ERRCODE = 'P0090';
  END IF;
  PERFORM set_config('audit.actor', 'EOD', false);

  INSERT INTO WLT_EOD_RUN(biz_date, task, status, last_key, started_at)
       VALUES (p_biz_date, 'EXPIRE_RESTRAINTS', 'RUNNING', 0, now())
  ON CONFLICT (biz_date, task)
       DO UPDATE SET status = 'RUNNING', started_at = now(), message = NULL;

  -- account-scoped restraints whose window closed before the business date
  SELECT array_agg(DISTINCT internal_key) INTO v_keys
    FROM WLT_RESTRAINTS
   WHERE status = 'A' AND internal_key IS NOT NULL
     AND end_date IS NOT NULL AND end_date < p_biz_date;

  IF v_keys IS NOT NULL THEN
    FOREACH v_key IN ARRAY v_keys LOOP          -- array iteration: COMMIT-safe (no portal)
      UPDATE WLT_RESTRAINTS
         SET status = 'E', removed_at = now(), removed_by = 'EOD',
             removed_reason = 'auto-expired: end_date < ' || p_biz_date::text
       WHERE internal_key = v_key AND status = 'A'
         AND end_date IS NOT NULL AND end_date < p_biz_date;

      UPDATE WLT_ACCT a
         SET total_restrained_amt = agg.restr,
             cr_blocked           = agg.crblk,
             restraint_present    = agg.present,
             version              = a.version + 1
        FROM (
          SELECT
            COALESCE(SUM(CASE WHEN restraint_type IN ('DEBIT','ALL')
                              THEN pledged_amt ELSE 0 END), 0)                 AS restr,
            CASE WHEN bool_or(restraint_type IN ('CREDIT','ALL'))
                 THEN 'Y' ELSE 'N' END                                        AS crblk,
            CASE WHEN count(*) > 0 THEN 'Y' ELSE 'N' END                      AS present
          FROM WLT_RESTRAINTS
           WHERE internal_key = v_key AND status = 'A'
             AND p_biz_date BETWEEN start_date AND COALESCE(end_date, DATE '9999-12-31')
        ) agg
       WHERE a.internal_key = v_key;

      v_n := v_n + 1;
      COMMIT;
    END LOOP;
  END IF;

  UPDATE WLT_EOD_RUN SET status = 'DONE', finished_at = now(), rows_done = v_n
    WHERE biz_date = p_biz_date AND task = 'EXPIRE_RESTRAINTS';
  PERFORM eod_log(p_biz_date, 'EXPIRE_RESTRAINTS', 'DONE', v_n, v_started);
  COMMIT;
END;
$$;

-- =============================================================================
-- eod_mark_failed — record a failure (scheduler error path)
-- =============================================================================
-- A COMMIT-looping procedure cannot wrap its work in a BEGIN..EXCEPTION block
-- (the subtransaction would forbid COMMIT), so it cannot self-log failure. The
-- external scheduler instead calls this in its error handler:
--     CALL eod_snapshot('2026-05-30');     -- on SQLSTATE error →
--     CALL eod_mark_failed('2026-05-30', 'SNAPSHOT', SQLERRM);
-- WLT_EOD_RUN keeps the resume cursor intact (status → FAILED) so a retry of the
-- same task resumes from the last committed chunk.
CREATE OR REPLACE PROCEDURE eod_mark_failed(p_biz_date DATE, p_task VARCHAR, p_message TEXT DEFAULT NULL)
LANGUAGE plpgsql
AS $$
DECLARE
  v_started TIMESTAMPTZ;
BEGIN
  UPDATE WLT_EOD_RUN SET status = 'FAILED', finished_at = now(), message = p_message
    WHERE biz_date = p_biz_date AND task = p_task
    RETURNING started_at INTO v_started;
  PERFORM eod_log(p_biz_date, p_task, 'FAILED', 0, COALESCE(v_started, clock_timestamp()), p_message);
  COMMIT;
END;
$$;

-- =============================================================================
-- run_eod — orchestrator (T1 → T2 → T5), invoked at top level
-- =============================================================================
CREATE OR REPLACE PROCEDURE run_eod(p_biz_date DATE)
LANGUAGE plpgsql
AS $$
BEGIN
  CALL eod_snapshot(p_biz_date);          -- T1
  CALL eod_prev_day_roll(p_biz_date);     -- T2 (depends on T1)
  CALL eod_expire_restraints(p_biz_date); -- T5
END;
$$;

-- ── grants (local stack runs EOD as wallet_app; prod: dedicated batch role) ───
GRANT SELECT, INSERT, UPDATE ON WLT_EOD_RUN       TO wallet_app;
GRANT SELECT, INSERT         ON WLT_EOD_AUDIT_LOG TO wallet_app;
GRANT EXECUTE ON FUNCTION  eod_log(DATE, VARCHAR, VARCHAR, BIGINT, TIMESTAMPTZ, TEXT) TO wallet_app;
GRANT EXECUTE ON PROCEDURE eod_snapshot(DATE, BIGINT)        TO wallet_app;
GRANT EXECUTE ON PROCEDURE eod_prev_day_roll(DATE, BIGINT)   TO wallet_app;
GRANT EXECUTE ON PROCEDURE eod_expire_restraints(DATE)       TO wallet_app;
GRANT EXECUTE ON PROCEDURE eod_mark_failed(DATE, VARCHAR, TEXT) TO wallet_app;
GRANT EXECUTE ON PROCEDURE run_eod(DATE)                     TO wallet_app;
