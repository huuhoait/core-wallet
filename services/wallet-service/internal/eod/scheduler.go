// Package eod runs the daily end-of-day procedures from inside the service. The
// modern-core model splits them into TWO fixed-daily-time jobs (the caller wires
// one Scheduler each, sharing a dedicated pool):
//
//   - CUSTOMER EOD — run_eod(prior calendar day), fired in the overnight trough
//     (default 00:30): the snapshot / prev-day-roll / restraint-expiry tasks for
//     the calendar day that just ended.
//   - GL CLOSE — run_gl_close(today), fired at the GL accounting cutoff (default
//     18:00): seals TODAY's accounting day with no ledger downtime, because
//     post-cutoff GL entries carry the NEXT accounting date (fn_accounting_date).
//
// The procedures COMMIT between chunks and set a session GUC, so they MUST run on
// a DIRECT primary connection (NOT PgBouncer transaction-mode) as the wallet_eod
// role — the only role permitted to write the tamper-evident trial balance
// (migration 2026-05-30_ledger_integrity_hardening). The caller builds that pool
// from EOD_DSN with statement_timeout disabled.
package eod

import (
	"context"
	"fmt"
	"log/slog"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// Scheduler fires one stored procedure once per day at a fixed local time. The
// service runs two: the CUSTOMER EOD (run_eod, prior calendar day, overnight)
// and the GL CLOSE (run_gl_close, current day, at the GL accounting cutoff e.g.
// 18:00). proc is the procedure name; dateFn maps the fire instant → the DATE
// literal to pass it.
type Scheduler struct {
	pool       *pgxpool.Pool
	log        *slog.Logger
	loc        *time.Location
	h, m, s    int
	runTimeout time.Duration
	label      string                     // log tag, e.g. "customer-eod" / "gl-close"
	proc       string                     // procedure name, e.g. "run_eod" / "run_gl_close"
	dateFn     func(now time.Time) string // target business/accounting DATE at fire time
}

// New builds a Scheduler that CALLs proc(DATE) once per day. runAt is "HH:MM:SS"
// (24h) in tz (an IANA name, e.g. "Asia/Ho_Chi_Minh"); dateFn derives the date
// argument from the fire instant; runTimeout caps a single run.
func New(pool *pgxpool.Pool, label, proc string, dateFn func(time.Time) string, runAt, tz string, runTimeout time.Duration, log *slog.Logger) (*Scheduler, error) {
	loc, err := time.LoadLocation(tz)
	if err != nil {
		return nil, fmt.Errorf("eod: load timezone %q: %w", tz, err)
	}
	h, m, sec, err := parseClock(runAt)
	if err != nil {
		return nil, err
	}
	if runTimeout <= 0 {
		return nil, fmt.Errorf("eod: run timeout must be > 0")
	}
	if proc == "" || dateFn == nil {
		return nil, fmt.Errorf("eod: proc and dateFn are required")
	}
	if label == "" {
		label = proc
	}
	return &Scheduler{pool: pool, log: log, loc: loc, h: h, m: m, s: sec,
		runTimeout: runTimeout, label: label, proc: proc, dateFn: dateFn}, nil
}

// PriorDay → the prior local calendar day (customer EOD closes the day that just
// ended). CurrentDay → today's local date (GL close seals the accounting day that
// just became past at the cutoff — post-cutoff postings carry the next day).
func PriorDay(now time.Time) string   { return now.AddDate(0, 0, -1).Format("2006-01-02") }
func CurrentDay(now time.Time) string { return now.Format("2006-01-02") }

// Start blocks until ctx is cancelled, firing the close once per day at the
// configured local time. Returns nil on graceful shutdown.
func (s *Scheduler) Start(ctx context.Context) error {
	s.log.Info("eod scheduler started",
		slog.String("job", s.label),
		slog.String("proc", s.proc),
		slog.String("run_at", fmt.Sprintf("%02d:%02d:%02d", s.h, s.m, s.s)),
		slog.String("tz", s.loc.String()))
	for {
		next := s.nextFire(time.Now().In(s.loc))
		s.log.Info("eod next run scheduled", slog.Time("at", next))
		timer := time.NewTimer(time.Until(next))
		select {
		case <-ctx.Done():
			timer.Stop()
			s.log.Info("eod scheduler stopping")
			return nil
		case <-timer.C:
			s.runOnce(ctx)
		}
	}
}

// nextFire returns the next occurrence of the configured wall-clock time
// strictly after now (today if still ahead, otherwise tomorrow). Computed in
// the configured location so it is correct across DST/offset changes.
func (s *Scheduler) nextFire(now time.Time) time.Time {
	today := time.Date(now.Year(), now.Month(), now.Day(), s.h, s.m, s.s, 0, s.loc)
	if !today.After(now) {
		today = today.AddDate(0, 0, 1)
	}
	return today
}

// runOnce CALLs the configured procedure for the date dateFn derives from the
// fire instant. The EOD procedures are resumable, so a mid-run shutdown (ctx
// cancel) leaves committed chunks intact and the next run resumes from cursor.
func (s *Scheduler) runOnce(parent context.Context) {
	bizDate := s.dateFn(time.Now().In(s.loc))
	ctx, cancel := context.WithTimeout(parent, s.runTimeout)
	defer cancel()

	start := time.Now()
	s.log.Info("eod run starting", slog.String("job", s.label), slog.String("biz_date", bizDate))

	// bizDate is a server-derived date literal (no external input) → safe to
	// inline. Simple-protocol CALL at top level so the procedure's internal
	// COMMITs are permitted.
	if _, err := s.pool.Exec(ctx, fmt.Sprintf("CALL %s(DATE '%s')", s.proc, bizDate)); err != nil {
		s.log.Error("eod run failed",
			slog.String("job", s.label),
			slog.String("biz_date", bizDate),
			slog.Duration("took", time.Since(start)),
			slog.Any("error", err))
		return
	}
	s.log.Info("eod run completed",
		slog.String("job", s.label),
		slog.String("biz_date", bizDate),
		slog.Duration("took", time.Since(start)))
}

// parseClock parses "HH:MM:SS" (seconds optional) into h, m, s.
func parseClock(v string) (h, m, s int, err error) {
	parts := strings.Split(strings.TrimSpace(v), ":")
	if len(parts) < 2 || len(parts) > 3 {
		return 0, 0, 0, fmt.Errorf("eod: invalid run-at %q (want HH:MM[:SS])", v)
	}
	if h, err = atoiRange(parts[0], 0, 23); err != nil {
		return 0, 0, 0, fmt.Errorf("eod run-at hour: %w", err)
	}
	if m, err = atoiRange(parts[1], 0, 59); err != nil {
		return 0, 0, 0, fmt.Errorf("eod run-at minute: %w", err)
	}
	if len(parts) == 3 {
		if s, err = atoiRange(parts[2], 0, 59); err != nil {
			return 0, 0, 0, fmt.Errorf("eod run-at second: %w", err)
		}
	}
	return h, m, s, nil
}

func atoiRange(v string, lo, hi int) (int, error) {
	n, err := strconv.Atoi(v)
	if err != nil {
		return 0, fmt.Errorf("%q not an integer", v)
	}
	if n < lo || n > hi {
		return 0, fmt.Errorf("%d out of range [%d,%d]", n, lo, hi)
	}
	return n, nil
}
