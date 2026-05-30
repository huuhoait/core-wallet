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
--   eod_gl_feed_post(D)      T3  Finalise the GL feed: WLT_BATCH 'P' → 'S' for D,
--                                chunked + restart-safe. Hand-off-ready journal.
--   eod_trial_balance(D)     T6  Daily GL trial balance + tamper-evident hash
--                                chain proof (US-6.3).
--   eod_close_period(D)      T7  Seal D in WLT_PERIOD (D < CURRENT_DATE only),
--                                advancing the high-water mark the freeze
--                                triggers enforce — the write-freeze (US-6.1).
--   run_eod(D)                   Orchestrator: T1 → T2 → T5 → T3 → T6 → T7.
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

-- ── period control + write-freeze (US-6.1) ───────────────────────────────────
-- One row per CLOSED business date — the accounting-period high-water mark. The
-- freeze triggers below reject any ledger/GL row whose POST_DATE falls on or
-- before the latest closed date, so a sealed day's trial balance + hash chain
-- (US-6.3) stay immutable and a cross-period reversal (US-3.7) provably lands in
-- the OPEN period (reversals use POST_DATE = CURRENT_DATE, always > the
-- high-water mark once a day is closed AFTER its midnight roll).
--   NOTE: the freeze triggers attach to base-schema tables (WLT_BATCH,
--   WLT_TRAN_HIST). They are mirrored — byte-identical — in the tracked migration
--   db/migrations/2026-05-30_eod_period_locking_gl_feed.sql (the prod artifact,
--   which also hardens grants onto wallet_eod). Keep both copies in sync.
CREATE TABLE IF NOT EXISTS WLT_PERIOD (
  biz_date   DATE         NOT NULL,
  status     VARCHAR(8)   NOT NULL DEFAULT 'CLOSED',   -- OPEN | CLOSED
  closed_at  TIMESTAMPTZ  NOT NULL DEFAULT now(),
  closed_by  VARCHAR(64)  NOT NULL DEFAULT 'EOD',
  note       TEXT,
  CONSTRAINT pk_period     PRIMARY KEY (biz_date),
  CONSTRAINT chk_period_st CHECK (status IN ('OPEN','CLOSED'))
);
-- The freeze probes the most-recent CLOSED date on every posting → keep it cheap.
CREATE INDEX IF NOT EXISTS idx_period_closed ON WLT_PERIOD (biz_date DESC) WHERE status = 'CLOSED';

-- fn_period_closed_through — period high-water mark: the latest CLOSED business
-- date (NULL if none). STABLE (evaluated once per statement). A POST_DATE d is
-- frozen ⇔ d <= fn_period_closed_through().
CREATE OR REPLACE FUNCTION fn_period_closed_through()
RETURNS DATE
LANGUAGE sql STABLE AS $$
  SELECT max(biz_date) FROM WLT_PERIOD WHERE status = 'CLOSED';
$$;

-- fn_freeze_closed_period — full-immutability guard on the books (WLT_TRAN_HIST,
-- WLT_BATCH). Once a day is sealed (POST_DATE <= high-water) its rows can no
-- longer be INSERTed, UPDATEd, or DELETEd — so a sealed day's trial balance +
-- hash chain (US-6.3) are tamper-proof and a cross-period reversal (US-3.7)
-- provably lands in the OPEN period. The write-freeze holds regardless of which
-- SP (or ad-hoc statement) attempts the change. It catches:
--   INSERT / UPDATE landing a row INTO a closed period  (NEW.POST_DATE)
--   UPDATE / DELETE of a row already IN a closed period  (OLD.POST_DATE)
-- Normal postings (POST_DATE = CURRENT_DATE > high-water) never trip it. The EOD
-- GL-feed post UPDATEs status P→S while the day is still OPEN (T3 runs BEFORE the
-- T7 close), so that legitimate UPDATE is not blocked — which is exactly why the
-- close runs LAST. SQLSTATE P0092. NOTE: TRUNCATE bypasses row triggers (use it
-- for a full test-data reset); a row-level DELETE of a sealed day is blocked.
CREATE OR REPLACE FUNCTION fn_freeze_closed_period()
RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public, pg_catalog AS $fn$
DECLARE
  v_through DATE := fn_period_closed_through();
BEGIN
  IF v_through IS NULL THEN
    RETURN COALESCE(NEW, OLD);                       -- nothing sealed yet
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

-- ── trial balance (US-6.3) ───────────────────────────────────────────────────
-- Daily GL-level trial balance + tamper-evident hash chain. Granularity is the
-- chart of accounts (FM_GL_MAST) — a small fixed set, so the whole day is built
-- in one short TX (no chunking). Balances use a signed-net convention
-- (closing = opening + ΣDR − ΣCR; debit-positive). A balanced ledger satisfies
-- BOTH  ΣDR = ΣCR (the day's movements net to zero) AND Σ closing = 0 system-wide.
CREATE TABLE IF NOT EXISTS WLT_TRIAL_BALANCE (
  biz_date    DATE          NOT NULL,
  gl_code     VARCHAR(32)   NOT NULL,
  ccy         VARCHAR(4)    NOT NULL,
  gl_desc     VARCHAR(120),
  opening_bal NUMERIC(20,2) NOT NULL DEFAULT 0,   -- = prior day's closing (carry-forward)
  period_dr   NUMERIC(20,2) NOT NULL DEFAULT 0,   -- Σ WLT_BATCH DR for the day
  period_cr   NUMERIC(20,2) NOT NULL DEFAULT 0,   -- Σ WLT_BATCH CR for the day
  closing_bal NUMERIC(20,2) NOT NULL,             -- opening + period_dr - period_cr
  created_at  TIMESTAMPTZ   NOT NULL DEFAULT now(),
  created_by  VARCHAR(64)   NOT NULL DEFAULT 'SYSTEM',
  CONSTRAINT pk_trial_balance PRIMARY KEY (biz_date, gl_code, ccy)
);

-- one sealed proof per (biz_date, ccy); chain_hash links to the prior day's so any
-- retro-edit of a stored line or proof field breaks the chain from that day forward.
CREATE TABLE IF NOT EXISTS WLT_TRIAL_BALANCE_PROOF (
  biz_date     DATE          NOT NULL,
  ccy          VARCHAR(4)    NOT NULL,
  gl_count     INTEGER       NOT NULL,
  grand_dr     NUMERIC(24,2) NOT NULL,
  grand_cr     NUMERIC(24,2) NOT NULL,
  net_balance  NUMERIC(24,2) NOT NULL,            -- Σ closing_bal; 0 ⇔ balanced
  is_balanced  BOOLEAN       NOT NULL,
  content_hash VARCHAR(64)   NOT NULL,            -- sha256 of the ordered TB lines
  prev_hash    VARCHAR(64)   NOT NULL,            -- prior day's chain_hash ('GENESIS' if first)
  chain_hash   VARCHAR(64)   NOT NULL,            -- sha256(totals ‖ content_hash ‖ prev_hash)
  created_at   TIMESTAMPTZ   NOT NULL DEFAULT now(),
  created_by   VARCHAR(64)   NOT NULL DEFAULT 'SYSTEM',
  CONSTRAINT pk_trial_balance_proof PRIMARY KEY (biz_date, ccy)
);

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
-- T6 — daily trial balance + signed (hash-chained) proof  (US-6.3)
-- =============================================================================
-- Aggregates the immutable GL feed (WLT_BATCH, frozen for D after cutover) into a
-- per-(gl_code, ccy) trial balance, carries opening forward from the prior TB,
-- checks the books balance, and seals the day with a sha256 hash chain. Few GL
-- codes ⇒ one short TX (no chunking). Deterministic: re-running for unchanged data
-- reproduces the identical hash, so a re-run is safe and a *changed* hash is
-- exactly the tamper signal. Unbalanced books are RECORDED (is_balanced = false +
-- WARNING), never hidden by aborting.
CREATE OR REPLACE PROCEDURE eod_trial_balance(p_biz_date DATE)
LANGUAGE plpgsql
AS $$
DECLARE
  v_started TIMESTAMPTZ := clock_timestamp();
  r_ccy     RECORD;
  v_cnt     INTEGER;
  v_gdr     NUMERIC(24,2);
  v_gcr     NUMERIC(24,2);
  v_net     NUMERIC(24,2);
  v_content VARCHAR(64);
  v_prev    VARCHAR(64);
  v_chain   VARCHAR(64);
  v_bal     BOOLEAN;
BEGIN
  IF p_biz_date IS NULL OR p_biz_date > CURRENT_DATE THEN
    RAISE EXCEPTION 'EOD_INVALID_DATE: %', p_biz_date USING ERRCODE = 'P0090';
  END IF;
  PERFORM set_config('audit.actor', 'EOD', false);

  INSERT INTO WLT_EOD_RUN(biz_date, task, status, started_at)
       VALUES (p_biz_date, 'TRIAL_BALANCE', 'RUNNING', now())
  ON CONFLICT (biz_date, task)
       DO UPDATE SET status = 'RUNNING', started_at = now(), message = NULL;

  -- every currency that moved today, or carried a balance from the prior TB
  FOR r_ccy IN
    SELECT ccy FROM WLT_BATCH WHERE post_date = p_biz_date
    UNION
    SELECT ccy FROM WLT_TRIAL_BALANCE
     WHERE biz_date = (SELECT max(biz_date) FROM WLT_TRIAL_BALANCE WHERE biz_date < p_biz_date)
  LOOP
    DELETE FROM WLT_TRIAL_BALANCE WHERE biz_date = p_biz_date AND ccy = r_ccy.ccy;  -- idempotent rebuild

    INSERT INTO WLT_TRIAL_BALANCE(biz_date, gl_code, ccy, gl_desc,
                                  opening_bal, period_dr, period_cr, closing_bal)
    WITH prior AS (            -- carry-forward opening = most recent prior closing
      SELECT gl_code, closing_bal
        FROM WLT_TRIAL_BALANCE
       WHERE ccy = r_ccy.ccy
         AND biz_date = (SELECT max(biz_date) FROM WLT_TRIAL_BALANCE
                          WHERE ccy = r_ccy.ccy AND biz_date < p_biz_date)
    ),
    today AS (                 -- today's GL movement
      SELECT gl_code,
             COALESCE(SUM(amount) FILTER (WHERE tran_nature = 'DR'), 0) AS dr,
             COALESCE(SUM(amount) FILTER (WHERE tran_nature = 'CR'), 0) AS cr
        FROM WLT_BATCH
       WHERE post_date = p_biz_date AND ccy = r_ccy.ccy
       GROUP BY gl_code
    ),
    keys AS (SELECT gl_code FROM prior UNION SELECT gl_code FROM today)
    SELECT p_biz_date, k.gl_code, r_ccy.ccy, g.gl_code_desc,
           COALESCE(pr.closing_bal, 0),
           COALESCE(t.dr, 0),
           COALESCE(t.cr, 0),
           COALESCE(pr.closing_bal, 0) + COALESCE(t.dr, 0) - COALESCE(t.cr, 0)
      FROM keys k
      LEFT JOIN prior pr ON pr.gl_code = k.gl_code
      LEFT JOIN today t  ON t.gl_code  = k.gl_code
      JOIN fm_gl_mast g  ON g.gl_code  = k.gl_code;

    -- totals + canonical content hash over the ordered lines
    SELECT count(*), COALESCE(sum(period_dr), 0), COALESCE(sum(period_cr), 0),
           COALESCE(sum(closing_bal), 0),
           encode(sha256(convert_to(
             COALESCE(string_agg(gl_code || ':' || period_dr || ':' || period_cr || ':' || closing_bal,
                                  '|' ORDER BY gl_code), ''), 'UTF8')), 'hex')
      INTO v_cnt, v_gdr, v_gcr, v_net, v_content
      FROM WLT_TRIAL_BALANCE WHERE biz_date = p_biz_date AND ccy = r_ccy.ccy;

    v_bal := (v_gdr = v_gcr AND v_net = 0);

    SELECT chain_hash INTO v_prev
      FROM WLT_TRIAL_BALANCE_PROOF
     WHERE ccy = r_ccy.ccy AND biz_date < p_biz_date
     ORDER BY biz_date DESC LIMIT 1;
    v_prev := COALESCE(v_prev, 'GENESIS');

    v_chain := encode(sha256(convert_to(
      p_biz_date::text || '|' || r_ccy.ccy || '|' || v_gdr || '|' || v_gcr || '|' ||
      v_net || '|' || v_content || '|' || v_prev, 'UTF8')), 'hex');

    INSERT INTO WLT_TRIAL_BALANCE_PROOF(biz_date, ccy, gl_count, grand_dr, grand_cr,
                                        net_balance, is_balanced, content_hash, prev_hash, chain_hash)
    VALUES (p_biz_date, r_ccy.ccy, v_cnt, v_gdr, v_gcr, v_net, v_bal, v_content, v_prev, v_chain)
    ON CONFLICT (biz_date, ccy) DO UPDATE SET
      gl_count = EXCLUDED.gl_count, grand_dr = EXCLUDED.grand_dr, grand_cr = EXCLUDED.grand_cr,
      net_balance = EXCLUDED.net_balance, is_balanced = EXCLUDED.is_balanced,
      content_hash = EXCLUDED.content_hash, prev_hash = EXCLUDED.prev_hash, chain_hash = EXCLUDED.chain_hash;

    IF NOT v_bal THEN
      RAISE WARNING 'TRIAL BALANCE NOT BALANCED % %: DR=% CR=% net=%',
        p_biz_date, r_ccy.ccy, v_gdr, v_gcr, v_net;
    END IF;
  END LOOP;

  SELECT count(*) INTO v_cnt FROM WLT_TRIAL_BALANCE WHERE biz_date = p_biz_date;
  UPDATE WLT_EOD_RUN SET status = 'DONE', finished_at = now(), rows_done = v_cnt
    WHERE biz_date = p_biz_date AND task = 'TRIAL_BALANCE';
  PERFORM eod_log(p_biz_date, 'TRIAL_BALANCE', 'DONE', v_cnt, v_started);
  COMMIT;
END;
$$;

-- =============================================================================
-- T3 — GL-feed post: finalise the day's GL journal  (WLT_BATCH 'P' → 'S')
-- =============================================================================
-- Every posting writes its GL legs to WLT_BATCH (the GL feed) as PENDING ('P').
-- At close we mark the day's legs POSTED ('S') — the GL feed for D is finalised
-- and ready for downstream hand-off (the bank core GL / T24, out of scope here).
-- Chunked short-TX (COMMIT per chunk → no xmin pinning, never blocks posting's
-- Phase-2) and restart-safe: the WLT_EOD_RUN cursor advances on tran_key and the
-- UPDATE is idempotent (only 'P' rows flip), so a re-run resumes cleanly. Runs
-- for a past business date (D < CURRENT_DATE under the after-midnight close), so
-- its pending set is already complete and stable.
CREATE OR REPLACE PROCEDURE eod_gl_feed_post(p_biz_date DATE, p_step BIGINT DEFAULT 50000)
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

  INSERT INTO WLT_EOD_RUN(biz_date, task, status, last_key, started_at)
       VALUES (p_biz_date, 'GL_FEED', 'RUNNING', 0, now())
  ON CONFLICT (biz_date, task)
       DO UPDATE SET status = 'RUNNING', started_at = now(), message = NULL;

  SELECT last_key, rows_done INTO v_lo, v_tot
    FROM WLT_EOD_RUN WHERE biz_date = p_biz_date AND task = 'GL_FEED';
  SELECT COALESCE(max(tran_key), 0) INTO v_max FROM WLT_BATCH WHERE post_date = p_biz_date;

  WHILE v_lo <= v_max LOOP
    UPDATE WLT_BATCH
       SET status = 'S', time_stamp = now()
     WHERE post_date = p_biz_date
       AND status    = 'P'
       AND tran_key  >  v_lo
       AND tran_key  <= v_lo + p_step;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_tot := v_tot + v_n;
    v_lo  := v_lo + p_step;
    UPDATE WLT_EOD_RUN SET last_key = v_lo, rows_done = v_tot
      WHERE biz_date = p_biz_date AND task = 'GL_FEED';
    COMMIT;                                          -- short TX: release + advance xmin
  END LOOP;

  UPDATE WLT_EOD_RUN SET status = 'DONE', finished_at = now()
    WHERE biz_date = p_biz_date AND task = 'GL_FEED';
  PERFORM eod_log(p_biz_date, 'GL_FEED', 'DONE', v_tot, v_started);
  COMMIT;
END;
$$;

-- =============================================================================
-- T7 — close the business period  (engage the write-freeze for D)
-- =============================================================================
-- The final close step: mark D CLOSED in WLT_PERIOD, advancing the period
-- high-water mark so the freeze triggers reject any later write dated <= D. Runs
-- LAST, only once every prerequisite task is DONE and the trial balance sealed,
-- so a day is frozen only after it is fully finalised and proven. A date can be
-- closed only when strictly in the past (D < CURRENT_DATE): you cannot freeze
-- "today" while live postings legitimately use POST_DATE = CURRENT_DATE. Does
-- NOT block on an unbalanced trial balance (recorded in the proof, not hidden —
-- US-6.3), but warns. Idempotent: re-close is a no-op.
CREATE OR REPLACE PROCEDURE eod_close_period(p_biz_date DATE)
LANGUAGE plpgsql
AS $$
DECLARE
  v_started TIMESTAMPTZ := clock_timestamp();
  v_missing TEXT;
  v_unbal   INTEGER;
BEGIN
  IF p_biz_date IS NULL THEN
    RAISE EXCEPTION 'EOD_INVALID_DATE' USING ERRCODE = 'P0090';
  END IF;
  IF p_biz_date >= CURRENT_DATE THEN
    RAISE EXCEPTION 'EOD_PERIOD_NOT_PAST: cannot close % — not strictly before CURRENT_DATE (%)',
      p_biz_date, CURRENT_DATE USING ERRCODE = 'P0090';
  END IF;
  PERFORM set_config('audit.actor', 'EOD', false);

  -- already closed → idempotent no-op
  IF EXISTS (SELECT 1 FROM WLT_PERIOD WHERE biz_date = p_biz_date AND status = 'CLOSED') THEN
    PERFORM eod_log(p_biz_date, 'CLOSE_PERIOD', 'DONE', 0, v_started, 'already closed');
    COMMIT;
    RETURN;
  END IF;

  -- every prerequisite task must be DONE before the period may be sealed
  SELECT string_agg(t.task, ', ') INTO v_missing
    FROM (VALUES ('SNAPSHOT'),('PREV_DAY_ROLL'),('EXPIRE_RESTRAINTS'),('GL_FEED'),('TRIAL_BALANCE'))
           AS t(task)
   WHERE NOT EXISTS (SELECT 1 FROM WLT_EOD_RUN r
                      WHERE r.biz_date = p_biz_date AND r.task = t.task AND r.status = 'DONE');
  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION 'EOD_PERIOD_INCOMPLETE: task(s) not DONE for %: %', p_biz_date, v_missing
      USING ERRCODE = 'P0091';
  END IF;

  -- record (never block on) an unbalanced trial balance — see US-6.3
  SELECT count(*) INTO v_unbal FROM WLT_TRIAL_BALANCE_PROOF
   WHERE biz_date = p_biz_date AND is_balanced = false;
  IF v_unbal > 0 THEN
    RAISE WARNING 'CLOSE_PERIOD %: % currency proof(s) NOT balanced — sealing anyway (recorded in proof)',
      p_biz_date, v_unbal;
  END IF;

  INSERT INTO WLT_PERIOD(biz_date, status, closed_at, closed_by)
       VALUES (p_biz_date, 'CLOSED', now(), 'EOD')
  ON CONFLICT (biz_date) DO UPDATE
       SET status = 'CLOSED', closed_at = now(), closed_by = 'EOD';

  INSERT INTO WLT_EOD_RUN(biz_date, task, status, last_key, started_at, finished_at)
       VALUES (p_biz_date, 'CLOSE_PERIOD', 'DONE', 0, v_started, now())
  ON CONFLICT (biz_date, task)
       DO UPDATE SET status = 'DONE', finished_at = now(), message = NULL;
  PERFORM eod_log(p_biz_date, 'CLOSE_PERIOD', 'DONE', 1, v_started);
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
-- eod_verify_chain — re-derive and verify the trial-balance hash chain (tamper check)
-- =============================================================================
-- Recomputes each day's content + chain hash from the STORED trial-balance lines
-- and the prior proof, comparing to the sealed values. chain_ok = false ⇒ a TB
-- line (or proof field) was edited after sealing; link_ok = false ⇒ the chain was
-- broken/reordered. Read-only — run on the primary or a replica.
CREATE OR REPLACE FUNCTION eod_verify_chain(p_ccy VARCHAR, p_from DATE DEFAULT NULL, p_to DATE DEFAULT NULL)
RETURNS TABLE(biz_date DATE, is_balanced BOOLEAN, chain_ok BOOLEAN, link_ok BOOLEAN)
LANGUAGE plpgsql
AS $$
DECLARE
  r       RECORD;
  v_gdr   NUMERIC(24,2);
  v_gcr   NUMERIC(24,2);
  v_net   NUMERIC(24,2);
  v_cont  VARCHAR(64);
  v_chain VARCHAR(64);
  v_prev  VARCHAR(64) := 'GENESIS';
BEGIN
  FOR r IN
    SELECT pf.* FROM WLT_TRIAL_BALANCE_PROOF pf
     WHERE pf.ccy = p_ccy
       AND (p_from IS NULL OR pf.biz_date >= p_from)
       AND (p_to   IS NULL OR pf.biz_date <= p_to)
     ORDER BY pf.biz_date
  LOOP
    SELECT COALESCE(sum(tb.period_dr), 0), COALESCE(sum(tb.period_cr), 0), COALESCE(sum(tb.closing_bal), 0),
           encode(sha256(convert_to(
             COALESCE(string_agg(tb.gl_code || ':' || tb.period_dr || ':' || tb.period_cr || ':' || tb.closing_bal,
                                  '|' ORDER BY tb.gl_code), ''), 'UTF8')), 'hex')
      INTO v_gdr, v_gcr, v_net, v_cont
      FROM WLT_TRIAL_BALANCE tb WHERE tb.biz_date = r.biz_date AND tb.ccy = p_ccy;

    v_chain := encode(sha256(convert_to(
      r.biz_date::text || '|' || p_ccy || '|' || v_gdr || '|' || v_gcr || '|' ||
      v_net || '|' || v_cont || '|' || r.prev_hash, 'UTF8')), 'hex');

    biz_date    := r.biz_date;
    is_balanced := r.is_balanced;
    chain_ok    := (v_chain = r.chain_hash);   -- recomputed from stored lines == sealed?
    link_ok     := (r.prev_hash = v_prev);     -- prev_hash links to the previous day's chain?
    v_prev      := r.chain_hash;
    RETURN NEXT;
  END LOOP;
END;
$$;

-- =============================================================================
-- run_eod — orchestrator (T1 → T2 → T5 → T6), invoked at top level
-- =============================================================================
CREATE OR REPLACE PROCEDURE run_eod(p_biz_date DATE)
LANGUAGE plpgsql
AS $$
BEGIN
  CALL eod_snapshot(p_biz_date);          -- T1
  CALL eod_prev_day_roll(p_biz_date);     -- T2 (depends on T1)
  CALL eod_expire_restraints(p_biz_date); -- T5
  CALL eod_gl_feed_post(p_biz_date);      -- T3  WLT_BATCH 'P' → 'S' (GL feed finalised)
  CALL eod_trial_balance(p_biz_date);     -- T6 (US-6.3)
  CALL eod_close_period(p_biz_date);      -- T7  seal D → engage write-freeze (US-6.1)
END;
$$;

-- ── grants (local stack runs EOD as wallet_app; prod: dedicated batch role) ───
GRANT SELECT, INSERT, UPDATE ON WLT_EOD_RUN             TO wallet_app;
GRANT SELECT, INSERT         ON WLT_EOD_AUDIT_LOG       TO wallet_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON WLT_TRIAL_BALANCE       TO wallet_app;
GRANT SELECT, INSERT, UPDATE         ON WLT_TRIAL_BALANCE_PROOF TO wallet_app;
GRANT EXECUTE ON FUNCTION  eod_log(DATE, VARCHAR, VARCHAR, BIGINT, TIMESTAMPTZ, TEXT) TO wallet_app;
GRANT EXECUTE ON FUNCTION  eod_verify_chain(VARCHAR, DATE, DATE) TO wallet_app;
GRANT EXECUTE ON PROCEDURE eod_snapshot(DATE, BIGINT)        TO wallet_app;
GRANT EXECUTE ON PROCEDURE eod_prev_day_roll(DATE, BIGINT)   TO wallet_app;
GRANT EXECUTE ON PROCEDURE eod_expire_restraints(DATE)       TO wallet_app;
GRANT EXECUTE ON PROCEDURE eod_trial_balance(DATE)           TO wallet_app;
GRANT EXECUTE ON PROCEDURE eod_mark_failed(DATE, VARCHAR, TEXT) TO wallet_app;
GRANT EXECUTE ON PROCEDURE run_eod(DATE)                     TO wallet_app;
-- period control + GL feed (US-6.1/6.2). Local stack runs EOD as wallet_app; the
-- tracked migration hardens these onto wallet_eod and revokes them from wallet_app.
-- wallet_app keeps SELECT WLT_PERIOD + EXECUTE fn_period_closed_through() because
-- the freeze trigger reads them on the (wallet_app) posting path.
GRANT SELECT, INSERT, UPDATE ON WLT_PERIOD                   TO wallet_app;
GRANT UPDATE (STATUS, TIME_STAMP) ON WLT_BATCH               TO wallet_app;
GRANT EXECUTE ON FUNCTION  fn_period_closed_through()        TO wallet_app;
GRANT EXECUTE ON PROCEDURE eod_gl_feed_post(DATE, BIGINT)    TO wallet_app;
GRANT EXECUTE ON PROCEDURE eod_close_period(DATE)            TO wallet_app;
