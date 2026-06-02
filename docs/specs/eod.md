# End-of-Day (EOD) & GL Accounting Cutoff — Design

**Version**: 1.0
**Date**: 2026-06-02
**Status**: Draft
**Companion**: `wallet_HLD.md`, `wallet_DLD.md`, `finance_transaction.md`, `error_management.md`

**Changelog**
- v1.0 (2026-06-02): Initial spec. Documents the modern-core 24/7 ledger + GL
  accounting-cutoff model, the two EOD jobs (`run_eod` / `run_gl_close`), the
  write-freeze, the in-process Go scheduler, and — critically — the **dangerous
  configuration updates** for the DB cutoff (`WLT_GL_CONFIG.cutoff_time`) and the
  Go scheduler (`EOD_GL_CUTOFF`).

---

## 1. Model — why two closes

The wallet is a **24/7 ledger with no downtime window**. EOD runs *concurrently*
with realtime posting. The modern-core (Vault / 10x style) design splits "end of
day" into **two independent layers**, each with its own date and its own job:

| Layer | Date axis | Job | When | Frozen? |
|-------|-----------|-----|------|---------|
| **Customer ledger** (`WLT_TRAN_HIST`, `WLT_ACCT*`) | `POST_DATE` = **calendar date** | `run_eod` | overnight (≈00:30) | **Never** period-frozen (append-only; reversals are compensating entries) |
| **GL / accounting journal** (`WLT_GL_BATCH`) | `ACCOUNTING_DATE` = **cutoff date** | `run_gl_close` | at the **GL cutoff** (≈18:00) | Sealed per accounting day (write-freeze) |

**Key idea:** a GL entry posted **at/after the cutoff** carries
`ACCOUNTING_DATE = next day`. So the GL period for *today* can be **sealed at the
cutoff** while the customer ledger keeps accepting traffic — post-cutoff entries
land in the *next* (open) accounting period. Period close + write-freeze move from
`POST_DATE` → `ACCOUNTING_DATE`.

```
calendar day D ───────────────────────────────────────────────▶
   00:30                      18:00 (cutoff)                  24:00
     │                          │                               │
 run_eod(D-1)              run_gl_close(D)                  (midnight roll)
 customer close            seal accounting day D
 (prior calendar day)      postings now carry ACCOUNTING_DATE = D+1
```

---

## 2. The seven tasks

Each task is a `PROCEDURE` (not a function) because it **COMMITs between chunks**.
All are **restart-safe**: progress is checkpointed in `WLT_EOD_RUN` (`last_key`
cursor) and writes are idempotent (`ON CONFLICT` / re-derivable), so a crashed or
interrupted run resumes from the last committed chunk.

| # | Procedure | Job | Keyed by | Purpose |
|---|-----------|-----|----------|---------|
| T1 | `eod_snapshot(D)` | run_eod | calendar `post_date` | Finalise `WLT_ACCT_BAL[D]` — sparse, ledger-derived close (last leg per account). |
| T2 | `eod_prev_day_roll(D)` | run_eod | calendar | `WLT_ACCT.prev_day_actual_bal := close(D)`. Depends on T1. |
| T5 | `eod_expire_restraints(D)` | run_eod | calendar | Auto-expire `WLT_RESTRAINTS` past `END_DATE`; recompute affected `WLT_ACCT` aggregates. |
| T3 | `eod_gl_feed_post(D)` | run_gl_close | `accounting_date` | Finalise GL feed: `WLT_GL_BATCH` `'P' → 'S'` for the accounting day. |
| T6 | `eod_trial_balance(D)` | run_gl_close | `accounting_date` | Daily GL trial balance + tamper-evident **hash chain** proof (US-6.3). |
| T7 | `eod_close_period(D)` | run_gl_close | `accounting_date` | Seal the accounting day in `WLT_PERIOD`; advance the freeze high-water (US-6.1). Runs **last**. |

**Orchestrators** (call at TOP LEVEL only — never inside an explicit transaction):

```sql
run_eod(p_biz_date)       -- CUSTOMER:  T1 → T2 → T5   (prior calendar day)
run_gl_close(p_acct_date) -- GL CLOSE:  T3 → T6 → T7   (accounting day at cutoff)
```

Helpers: `eod_log` (append audit row), `eod_mark_failed` (scheduler error path),
`eod_verify_chain` (re-derive + verify the trial-balance hash chain — read-only).

Control tables: `WLT_EOD_RUN` (live state + resume cursor, one row per
`(biz_date, task)`), `WLT_EOD_AUDIT_LOG` (append-only history), `WLT_PERIOD`
(closed-period high-water), `WLT_TRIAL_BALANCE` + `WLT_TRIAL_BALANCE_PROOF`.

> ⚠️ `WLT_EOD_RUN.biz_date` is **overloaded**: it is the **calendar** date for the
> customer tasks (SNAPSHOT / PREV_DAY_ROLL / EXPIRE_RESTRAINTS) and the
> **accounting** date for the GL tasks (GL_FEED / TRIAL_BALANCE / CLOSE_PERIOD).
> No PK collision (PK = `biz_date, task`), but an auditor must know which axis a
> task uses.

---

## 3. The accounting-date mechanism

```sql
-- one-row config table; the cutoff time of day (GMT+7)
WLT_GL_CONFIG(singleton BOOL PK, cutoff_time TIME = '18:00:00', updated_at)

-- every posting's GL legs are stamped via this DEFAULT
WLT_GL_BATCH.accounting_date DATE NOT NULL DEFAULT fn_accounting_date()

CREATE FUNCTION fn_accounting_date(p_ts timestamptz DEFAULT now()) RETURNS date
  -- if local time-of-day >= cutoff_time  → (local date + 1)
  -- else                                 → local date
```

So `fn_accounting_date()` reads `WLT_GL_CONFIG.cutoff_time` and decides which
accounting day a leg belongs to. **The singleton row is mandatory** — if it is
missing, `fn_accounting_date()` returns `NULL`, the `ACCOUNTING_DATE` default
becomes `NULL`, and the first posting fails the `NOT NULL` constraint. The row
ships in `db/export/seed.sql`.

Indexes: `idx_gl_batch_acctdate (accounting_date, ccy)` (trial-balance scan),
`idx_gl_batch_pending (accounting_date) WHERE status='P'` (GL-feed pending).

---

## 4. Write-freeze (US-6.1)

`fn_freeze_closed_period()` is a `BEFORE INSERT/UPDATE/DELETE` trigger on
**`WLT_GL_BATCH` only** (`trg_freeze_batch`). The 24/7 customer ledger
`WLT_TRAN_HIST` is **not** frozen (the legacy `trg_freeze_hist` is dropped).

- High-water = `fn_period_closed_through()` = latest `CLOSED` date in `WLT_PERIOD`.
- An accounting day `d` is frozen ⇔ `d <= high-water`.
- Rejects (SQLSTATE **`P0092`**, `PERIOD_CLOSED`):
  - `INSERT`/`UPDATE` landing a GL row **into** a closed period (`NEW.ACCOUNTING_DATE <= high-water`)
  - `UPDATE`/`DELETE` of a GL row **already in** a closed period (`OLD.ACCOUNTING_DATE <= high-water`)
- Post-cutoff entries carry `ACCOUNTING_DATE = next day` (> high-water) so they
  never trip it — this is what lets the GL seal at the cutoff **with no ledger
  downtime**. T3 (gl-feed `P→S`) runs **before** T7 (close), so its legitimate
  UPDATE is not blocked.

---

## 5. The in-process Go scheduler

Opt-in (`EOD_ENABLED=true` on **exactly one** replica). The service runs **two**
fixed-daily-time `Scheduler`s on a dedicated pool
(`services/wallet-service/internal/eod/scheduler.go`, wired in
`cmd/server/main.go`):

```go
custEOD := eod.New(pool, "customer-eod", "run_eod",      eod.PriorDay,   cfg.EOD.RunAt,   …)
glClose := eod.New(pool, "gl-close",     "run_gl_close", eod.CurrentDay, cfg.EOD.GLCutoff, …)
```

- `PriorDay`  → yesterday's calendar date (customer EOD closes the day that ended).
- `CurrentDay` → today's date (GL close seals the accounting day that just became
  past at the cutoff).

**The EOD pool MUST be a DIRECT primary connection** (NOT PgBouncer
transaction-mode — it cannot carry transaction control across the pool), built
from `EOD_DSN`, authenticating as the **`wallet_eod`** role (the only role allowed
to write the tamper-evident trial balance), with `statement_timeout` disabled
(these are long, resumable batches).

### Configuration (`services/wallet-service/.env.example`)

| Env | Default | Meaning |
|-----|---------|---------|
| `EOD_ENABLED` | `false` | Enable on exactly ONE replica. |
| `EOD_DSN` | — | Direct primary conn as `wallet_eod` (e.g. `:5432`, **not** PgBouncer `:6432`). |
| `EOD_RUN_AT` | `00:30:00` | Customer EOD (`run_eod`) fire time — after the midnight roll. |
| `EOD_GL_CUTOFF` | `18:00:00` | GL close (`run_gl_close`) fire time. **MUST equal `WLT_GL_CONFIG.cutoff_time`.** |
| `EOD_TIMEZONE` | `Asia/Ho_Chi_Minh` | IANA tz for both jobs. |
| `EOD_RUN_TIMEOUT` | `30m` | Hard cap on a single run. |

> Config is read **once at process start** — there is **no hot-reload**. Changing
> any `EOD_*` env requires a **service restart**.

---

## 6. Timing & guards — why each runs when it does

| Job | Fires | Closes | Guard | On violation |
|-----|-------|--------|-------|--------------|
| `run_eod` | `EOD_RUN_AT` (00:30) | **prior** calendar day | `eod_snapshot`: `p_biz_date > CURRENT_DATE` → error | `P0090` `EOD_INVALID_DATE` |
| `run_gl_close` | `EOD_GL_CUTOFF` (18:00) | **today's** accounting day | `eod_close_period`: `p_biz_date >= fn_accounting_date()` → error | `P0090` `EOD_PERIOD_NOT_PAST` |

- **Customer EOD** runs *after* midnight so the prior calendar day is fully past:
  once `CURRENT_DATE` rolls forward, no posting can target `post_date = D` (live
  postings use `post_date = CURRENT_DATE`), so the day's rows are calendar-stable.
- **GL close** runs *at the cutoff*: at 18:00, `fn_accounting_date()` already
  returns `D+1`, so `eod_close_period(D)` sees `D >= D+1 → false` and seals D. The
  scheduler must therefore fire **at or after** the DB `cutoff_time` (the `>=` in
  `fn_accounting_date` makes equality work).

### Error codes (class `P009x` = EOD)

| SQLSTATE | Name | Raised by |
|----------|------|-----------|
| `P0090` | `EOD_INVALID_DATE` | NULL or future `p_biz_date` |
| `P0090` | `EOD_PERIOD_NOT_PAST` | `eod_close_period` — accounting day still open |
| `P0091` | `EOD_SNAPSHOT_NOT_DONE` | `eod_prev_day_roll` before T1 done |
| `P0091` | `EOD_PERIOD_INCOMPLETE` | `eod_close_period` — `GL_FEED`/`TRIAL_BALANCE` not DONE |
| `P0092` | `PERIOD_CLOSED` | `fn_freeze_closed_period` — write into a sealed accounting day |

`eod_close_period` does **not** block on an unbalanced trial balance — it records
`is_balanced=false` in the proof and warns (US-6.3), never hides it.

---

## 7. ⚠️ DANGEROUS configuration updates

There are **two separate sources of truth** for "the cutoff", and they must stay
equal:

| | Where | Controls |
|---|-------|----------|
| `WLT_GL_CONFIG.cutoff_time` | **DB** (one row) | Which `accounting_date` every posting's GL legs get stamped with (via `fn_accounting_date()`). |
| `EOD_GL_CUTOFF` | **Go env** (read at startup) | The wall-clock time the `gl-close` scheduler fires `run_gl_close(today)`. |

**Invariant (HARD RULE):** `EOD_GL_CUTOFF` **==** `WLT_GL_CONFIG.cutoff_time`, and
the gl-close scheduler must fire **≥** the DB cutoff.

### 7.1 Failure modes

| Change | Effect | Severity |
|--------|--------|----------|
| **Scheduler fires BEFORE DB cutoff** (e.g. `EOD_GL_CUTOFF=17:00`, DB=18:00) | At 17:00 `fn_accounting_date()` still = today → `eod_close_period(today)`: `today >= today` → **`EOD_PERIOD_NOT_PAST` (P0090)**. The day **never seals** (scheduler fires once/day) → unsealed accounting days accumulate. | 🔴 Critical |
| **Scheduler fires AFTER DB cutoff** (e.g. `EOD_GL_CUTOFF=19:00`, DB=18:00) | Close still succeeds (`19:00` → `fn_accounting_date()`=D+1). But: accounting_date still rolls at **18:00** (DB-governed); the seal, GL-feed finalise, trial balance and write-freeze are **delayed ~1h**; an 18:00–19:00 "open-but-inactive" window. Functionally safe, but **config drift** (DB≠env). | 🟡 Latency + drift |
| **Move DB cutoff LATER, intraday, after the day is already sealed** | A new posting computes `accounting_date = the sealed day` → `fn_freeze_closed_period` rejects a **legitimate customer transaction** with **`PERIOD_CLOSED` (P0092)**. | 🔴 Critical |
| **Change DB cutoff but not env (or vice-versa)** | Config drift — see §7.2. | 🟡 Latent |
| **Change `EOD_*` env without restart** | No effect (env read once at startup); operator believes the change applied. | 🟡 Silent |
| **Run EOD via PgBouncer (`:6432`) instead of direct primary** | Transaction-mode pool cannot carry the procedures' inter-chunk COMMITs → batch breaks. | 🔴 Critical |
| **Run EOD as a role other than `wallet_eod`** | Cannot write `WLT_TRIAL_BALANCE` (least-privilege) → trial balance / proof fails. | 🔴 Critical |
| **Delete / never seed the `WLT_GL_CONFIG` singleton row** | `fn_accounting_date()` → NULL → `ACCOUNTING_DATE` default NULL → **every posting fails** `NOT NULL`. | 🔴 Critical |

### 7.2 Config drift — what it is and why it bites

"Drift" = the same concept (the cutoff) stored in two places that hold **different
values**. The system may *appear* to work (e.g. env 19:00 ≥ DB 18:00 passes the
guard) while the code's assumption (they are equal) is violated — a latent bug.

**Trap example:** today DB=18:00, env=19:00 (works). Months later an engineer
reads `.env`, assumes "cutoff is 19:00", and sets DB `cutoff_time=19:30` to
"match". Now env(19:00) **<** DB(19:30) → `run_gl_close` fires before the roll →
`EOD_PERIOD_NOT_PAST` (P0090) → GL close silently stops sealing. The incident
originates from the drift introduced earlier but detonates in someone else's hands.

### 7.3 Safe runbook — changing the cutoff

Treat the cutoff as **one** setting. To move it (e.g. 18:00 → 19:00):

1. Pick a **safe window** — ideally overnight, **after** the current accounting day
   is already sealed and **well before** the next cutoff approaches. **Never**
   change it intraday on a day that may already be sealed (avoids P0092).
2. Update the DB:
   ```sql
   UPDATE WLT_GL_CONFIG SET cutoff_time = '19:00:00', updated_at = now() WHERE singleton;
   ```
3. Update the env and **restart** the EOD replica:
   ```
   EOD_GL_CUTOFF=19:00:00
   ```
4. Verify `EOD_GL_CUTOFF == WLT_GL_CONFIG.cutoff_time` and that the gl-close
   scheduler fires **at or after** the DB cutoff.

> `EOD_RUN_AT` (customer EOD) is **independent** of the GL cutoff — it only needs
> to fire after the local midnight roll; any time after 00:00 is functionally
> correct (00:30 is just a low-traffic-trough buffer). It is **not** coupled to
> `WLT_GL_CONFIG.cutoff_time`.

---

## 8. Operational notes

- **Resumability**: a mid-run shutdown (ctx cancel / crash) leaves committed chunks
  intact; the next run resumes from the `WLT_EOD_RUN.last_key` cursor. On a SQL
  error the scheduler calls `eod_mark_failed(date, task, SQLERRM)` (status →
  `FAILED`, cursor preserved) so a retry resumes from the last committed chunk.
- **Concurrency-safe**: every task is short-TX (COMMIT per chunk) so it never pins
  the xmin horizon (autovacuum starvation) nor holds row locks that block posting's
  Phase-2 balance UPDATE. Schedule at the low-traffic trough.
- **The two jobs are decoupled**: `run_eod`'s timing has no bearing on
  `run_gl_close`. `eod_close_period` requires only `GL_FEED` + `TRIAL_BALANCE`
  DONE (the customer tasks are **not** prerequisites for sealing the GL period).
- **Verification**: `eod_verify_chain(ccy, from, to)` re-derives the trial-balance
  hash chain from the stored lines and compares to the sealed proof; `chain_ok=false`
  ⇒ a TB line/proof field was edited after sealing; `link_ok=false` ⇒ the chain was
  broken/reordered. Read-only (runnable on a replica).

## 9. Performance impact of the accounting-day machinery

**Verdict: small and bounded — tens of µs per posting, well under 1 % of posting
latency. Not a bottleneck.** The cutoff model adds work in three places on the GL
write path (`WLT_GL_BATCH` insert), none on the balance-update critical section.

What it adds per **GL leg** insert (a posting writes ~2–5 legs):

| Addition | What it costs | Measured (PG17, local, warm/cached) |
|----------|---------------|-------------------------------------|
| `accounting_date` DEFAULT = `fn_accounting_date()` | One `WLT_GL_CONFIG` singleton lookup + tz arithmetic, evaluated **once per INSERT statement** (the DEFAULT uses `now()`, which is `STABLE`, so the planner does not re-run it per row) | ~**7 µs** worst case (forced re-eval); the singleton index probe itself is ~0.01 ms cold, sub-µs hot |
| `fn_freeze_closed_period` BEFORE-ROW trigger | plpgsql invocation + `fn_period_closed_through()` = `max(biz_date) WHERE status='CLOSED'` | Index-Only Scan on `idx_period_closed` (~0.08 ms cold, ~µs hot); early-returns when nothing is sealed yet |
| `idx_gl_batch_acctdate (accounting_date, ccy)` | One extra B-tree insert per leg (net +1 index; `idx_gl_batch_pending` was *repointed*, not added) | a few µs |
| `accounting_date` column | +4 bytes/row | negligible |

Rough per-posting overhead ≈ `(≈7 µs default + a few µs trigger + a few µs index) ×
legs` ≈ **30–85 µs**. Against the warm posting `p(95)` measured in the HTTP load
test (~7.7 ms) that is **< 1 %** — dominated, as expected, by the balance UPDATE
(version CAS), the idempotency gate, and the existing multi-table writes, not by
the cutoff machinery.

**What to watch at very high TPS** (none are problems today, but they are the only
places this could ever show up):
- The freeze trigger is **per-row** (fires once per GL leg). At N× legs/posting it
  is N× plpgsql invocations. If it ever matters, it could be made statement-level
  or cache the high-water in a GUC.
- `WLT_GL_CONFIG` and `WLT_PERIOD` are read on **every** leg insert. They are
  1-row / few-row, fully cached, **MVCC reads with no lock contention** (cutoff and
  the closed-period high-water change ~never), so they do not serialise posting.
- `idx_gl_batch_pending` is partial (`WHERE status='P'`): a leg enters it on insert
  and leaves it when `eod_gl_feed_post` flips `P→S` — normal churn, same profile as
  before the cutoff (the index was repointed `post_date → accounting_date`, not added).

**EOD side**: `eod_gl_feed_post` and `eod_trial_balance` scan by `accounting_date`,
both index-supported (`idx_gl_batch_pending` / `idx_gl_batch_acctdate`); the trial
balance aggregates over the small fixed COA set in one short TX. No regression vs
the prior `post_date`-keyed scans.

> Caveat: the figures above are component micro-benchmarks on an idle local DB
> (PG17), not an end-to-end A/B of posting throughput. For a definitive number,
> compare posting `p(95)` / TPS via the k6 tier with the trigger + default present
> vs a baseline — the expected delta is in the noise.

## 10. Where it lives

| Concern | Location |
|---------|----------|
| EOD procedures + freeze + accounting-date + `WLT_GL_CONFIG` | `db/export/schema.sql` |
| `WLT_GL_CONFIG` singleton row | `db/export/seed.sql` |
| Go scheduler | `services/wallet-service/internal/eod/scheduler.go` |
| Scheduler wiring (two jobs) | `services/wallet-service/cmd/server/main.go` |
| EOD config | `services/wallet-service/internal/config/config.go`, `.env.example` |
