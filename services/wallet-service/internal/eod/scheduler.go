// Package eod runs the end-of-day close (run_eod) on a daily schedule from
// inside the service.
//
// run_eod COMMITs between chunks and sets a session GUC, so it MUST run on a
// DIRECT primary connection (NOT PgBouncer transaction-mode, which can hand the
// connection to another client between commits) and as the wallet_eod role —
// the only role permitted to write the tamper-evident trial balance (migration
// 2026-05-30_ledger_integrity_hardening). The caller wires both via a dedicated
// pool built from EOD_DSN with statement_timeout disabled.
//
// This is a fixed-daily-time scheduler (one fire per local wall-clock day), not
// a general cron — adequate for a once-a-day close. It closes the business day
// that is ending (the local calendar date at fire time).
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

// Scheduler fires run_eod once per day at a fixed local time.
type Scheduler struct {
	pool       *pgxpool.Pool
	log        *slog.Logger
	loc        *time.Location
	h, m, s    int
	runTimeout time.Duration
}

// New builds a Scheduler. runAt is "HH:MM:SS" (24h) in tz (an IANA name, e.g.
// "Asia/Ho_Chi_Minh"). runTimeout caps a single close.
func New(pool *pgxpool.Pool, runAt, tz string, runTimeout time.Duration, log *slog.Logger) (*Scheduler, error) {
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
	return &Scheduler{pool: pool, log: log, loc: loc, h: h, m: m, s: sec, runTimeout: runTimeout}, nil
}

// Start blocks until ctx is cancelled, firing the close once per day at the
// configured local time. Returns nil on graceful shutdown.
func (s *Scheduler) Start(ctx context.Context) error {
	s.log.Info("eod scheduler started",
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

// runOnce closes the business day that is ending (the current local date).
// run_eod is resumable, so a mid-run shutdown (ctx cancel) leaves committed
// chunks intact and the next run continues from the resume cursor.
func (s *Scheduler) runOnce(parent context.Context) {
	bizDate := time.Now().In(s.loc).Format("2006-01-02")
	ctx, cancel := context.WithTimeout(parent, s.runTimeout)
	defer cancel()

	start := time.Now()
	s.log.Info("eod run starting", slog.String("biz_date", bizDate))

	// bizDate is a server-derived date literal (no external input) → safe to
	// inline. Simple-protocol CALL at top level so the procedure's internal
	// COMMITs are permitted.
	if _, err := s.pool.Exec(ctx, fmt.Sprintf("CALL run_eod(DATE '%s')", bizDate)); err != nil {
		s.log.Error("eod run failed",
			slog.String("biz_date", bizDate),
			slog.Duration("took", time.Since(start)),
			slog.Any("error", err))
		return
	}
	s.log.Info("eod run completed",
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
