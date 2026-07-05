// This file adds the in-process data-retention purge janitor. It ages rows out
// of the two unbounded operational tables so they don't grow without bound:
//
//   - WLT_API_MESSAGE     — the API idempotency ledger (default 3 days)
//   - WLT_OUTBOX (SENT)   — already-published transactional-outbox events
//                           (default 7 days; only status='SENT' is ever deleted)
//
// WLT_GL_BATCH is deliberately NOT touched (compliance retention — out of scope).
//
// Each purge is a CALL to a SECURITY DEFINER function (fn_purge_api_message /
// fn_purge_outbox_sent) that deletes ONE bounded batch and returns the count.
// The janitor loops the batches, each in its OWN short transaction, so row locks
// are held for only one batch at a time. That per-batch COMMIT boundary is the
// same lock-friendly property the eod_* procedures get from an internal COMMIT —
// but done in Go so the routine stays a plain no-internal-COMMIT function and can
// run on the ORDINARY app pool (PgBouncer transaction-mode safe), exactly like
// the withdraw janitor. A COMMIT-per-chunk PROCEDURE would instead have to run on
// a dedicated DIRECT connection (see internal/eod/scheduler.go), which this
// janitor does not use.
//
// Deletes are naturally idempotent (a row deleted once stays deleted), so the
// janitor is safe to run on every replica — no leader election needed; enabling
// it on one replica is enough and simply avoids redundant scans.
package janitor

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// Retention purges aged rows from WLT_API_MESSAGE and WLT_OUTBOX (status='SENT')
// on a fixed interval by CALLing the DB purge functions in bounded batches.
type Retention struct {
	pool       *pgxpool.Pool
	log        *slog.Logger
	interval   time.Duration
	apiDays    int
	outboxDays int
	batchSize  int
	runTimeout time.Duration
}

// validateRetention checks the scalar tuning args (pure, no pool) so it can be
// unit tested without a database. Retention days must be >= 1 — a 0-day window
// (created_at < now()) would delete essentially the whole table; the SQL
// functions enforce the same floor as a second line of defence.
func validateRetention(interval time.Duration, apiDays, outboxDays, batchSize int, runTimeout time.Duration) error {
	if err := validateConfig(interval, batchSize, runTimeout); err != nil {
		return err
	}
	if apiDays < 1 {
		return fmt.Errorf("janitor: api-message retention days must be >= 1")
	}
	if outboxDays < 1 {
		return fmt.Errorf("janitor: outbox retention days must be >= 1")
	}
	return nil
}

// NewRetention builds the janitor. interval is the purge cadence, apiDays /
// outboxDays are the per-table age cutoffs, batchSize caps rows deleted per
// batch/TX, runTimeout caps one whole purge run (all batches of both tables).
func NewRetention(pool *pgxpool.Pool, interval time.Duration, apiDays, outboxDays, batchSize int, runTimeout time.Duration, log *slog.Logger) (*Retention, error) {
	if pool == nil {
		return nil, fmt.Errorf("janitor: pool is required")
	}
	if err := validateRetention(interval, apiDays, outboxDays, batchSize, runTimeout); err != nil {
		return nil, err
	}
	return &Retention{pool: pool, log: log, interval: interval, apiDays: apiDays,
		outboxDays: outboxDays, batchSize: batchSize, runTimeout: runTimeout}, nil
}

// Start blocks until ctx is cancelled, purging once at startup and then every
// interval. Returns nil on graceful shutdown. Each run is independent and
// resumable; a run cut short (error or time budget) leaves committed batches
// intact and the next tick continues aging out whatever remains.
func (r *Retention) Start(ctx context.Context) error {
	r.log.Info("retention janitor started",
		slog.Duration("interval", r.interval),
		slog.Int("api_message_days", r.apiDays),
		slog.Int("outbox_sent_days", r.outboxDays),
		slog.Int("batch_size", r.batchSize))

	r.runOnce(ctx) // purge immediately so a restart doesn't wait a full interval

	ticker := time.NewTicker(r.interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			r.log.Info("retention janitor stopping")
			return nil
		case <-ticker.C:
			r.runOnce(ctx)
		}
	}
}

// runOnce purges both tables to completion (or until the run's time budget is
// spent), then logs the totals. A spent budget / cancellation is expected and
// logged calmly; only a real DB error is logged at ERROR.
func (r *Retention) runOnce(parent context.Context) {
	ctx, cancel := context.WithTimeout(parent, r.runTimeout)
	defer cancel()

	start := time.Now()

	apiPurged, apiErr := r.purge(ctx, "fn_purge_api_message", r.apiDays)
	outboxPurged, outboxErr := r.purge(ctx, "fn_purge_outbox_sent", r.outboxDays)

	r.report("api_message", apiPurged, apiErr)
	r.report("outbox_sent", outboxPurged, outboxErr)

	if apiErr == nil && outboxErr == nil && apiPurged == 0 && outboxPurged == 0 {
		r.log.Debug("retention janitor: nothing to purge", slog.Duration("took", time.Since(start)))
		return
	}
	r.log.Info("retention janitor: purge done",
		slog.Int64("api_message_purged", apiPurged),
		slog.Int64("outbox_sent_purged", outboxPurged),
		slog.Duration("took", time.Since(start)))
}

// report logs a per-table outcome: budget-exhausted/cancelled is not an error
// (the next tick resumes); anything else is a real failure.
func (r *Retention) report(table string, purged int64, err error) {
	switch {
	case err == nil:
		// covered by the aggregate line in runOnce
	case errors.Is(err, context.DeadlineExceeded) || errors.Is(err, context.Canceled):
		r.log.Info("retention janitor: purge budget exhausted, will resume next tick",
			slog.String("table", table), slog.Int64("purged", purged))
	default:
		r.log.Error("retention janitor: purge failed",
			slog.String("table", table), slog.Int64("purged_before_error", purged), slog.Any("error", err))
	}
}

// purge repeatedly runs one batch of fn(retentionDays, batchSize) — each in its
// own committed transaction — until a batch removes fewer than batchSize rows
// (drained) or ctx is done, returning the total removed. The old-row set only
// shrinks (new rows are never immediately old), so the loop always terminates.
func (r *Retention) purge(ctx context.Context, fn string, retentionDays int) (int64, error) {
	var total int64
	for {
		if err := ctx.Err(); err != nil {
			return total, err
		}
		n, err := r.purgeBatch(ctx, fn, retentionDays)
		if err != nil {
			return total, err
		}
		total += n
		if n < int64(r.batchSize) {
			return total, nil // a short (or empty) batch means nothing older is left
		}
	}
}

// purgeBatch runs a single fn(retentionDays, batchSize) call in a bounded TX and
// returns the rows it deleted. A generous local statement_timeout backstops a
// runaway batch; the real cap is the run ctx. Mirrors repo.withTx / the withdraw
// janitor: unconditional rollback on a FRESH context so cleanup always reaches
// the server even if ctx has already timed out.
func (r *Retention) purgeBatch(ctx context.Context, fn string, retentionDays int) (int64, error) {
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return 0, fmt.Errorf("begin: %w", err)
	}
	defer func() { _ = tx.Rollback(context.Background()) }()

	if _, err := tx.Exec(ctx, fmt.Sprintf("SET LOCAL statement_timeout = %d", r.runTimeout.Milliseconds())); err != nil {
		return 0, fmt.Errorf("set timeout: %w", err)
	}
	// fn is a trusted in-code constant (never external input); the retention/batch
	// values are bound as parameters.
	var deleted int64
	if err := tx.QueryRow(ctx, fmt.Sprintf("SELECT %s($1, $2)", fn), retentionDays, r.batchSize).Scan(&deleted); err != nil {
		return 0, fmt.Errorf("%s: %w", fn, err)
	}
	if err := tx.Commit(ctx); err != nil {
		return 0, fmt.Errorf("commit: %w", err)
	}
	return deleted, nil
}
