// Package janitor runs the in-process withdrawal SLA-timeout sweeper (US-5.3).
//
// Withdrawals commit to the ledger immediately, then their disbursement is
// driven asynchronously by the Treasury state machine (SUBMITTED → ACKED →
// DISBURSING → COMPLETED/FAILED → REVERSED, US-5.1). A disbursement that never
// reaches a terminal state leaves the customer's funds debited indefinitely.
// WLT_WITHDRAW_TRACK.FINAL_DEADLINE (default SUBMITTED_AT + 24h) is the SLA; this
// janitor periodically CALLs reverse_stuck_withdrawals(batch) to auto-reverse
// everything past it, crediting the principal + fee/VAT back via the same
// post_withdraw_reversal path a Treasury-initiated reverse uses (US-3.3).
//
// The SP takes candidates FOR UPDATE SKIP LOCKED, so running this on more than
// one replica is safe (just redundant); operationally enable it on exactly one.
// The sweep is a single bounded statement (no internal COMMIT), so it runs on
// the ordinary app pool — no dedicated direct connection like EOD.
package janitor

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// Withdraw sweeps stuck withdrawals on a fixed interval.
type Withdraw struct {
	pool       *pgxpool.Pool
	log        *slog.Logger
	interval   time.Duration
	batchSize  int
	runTimeout time.Duration
}

// validateConfig checks the scalar tuning args (pure, no pool) so it can be unit
// tested without a database.
func validateConfig(interval time.Duration, batchSize int, runTimeout time.Duration) error {
	if interval <= 0 {
		return fmt.Errorf("janitor: interval must be > 0")
	}
	if batchSize <= 0 {
		return fmt.Errorf("janitor: batch size must be > 0")
	}
	if runTimeout <= 0 {
		return fmt.Errorf("janitor: run timeout must be > 0")
	}
	return nil
}

// NewWithdraw builds the janitor. interval is the sweep cadence, batchSize caps
// how many rows one sweep reverses, runTimeout caps a single sweep.
func NewWithdraw(pool *pgxpool.Pool, interval time.Duration, batchSize int, runTimeout time.Duration, log *slog.Logger) (*Withdraw, error) {
	if pool == nil {
		return nil, fmt.Errorf("janitor: pool is required")
	}
	if err := validateConfig(interval, batchSize, runTimeout); err != nil {
		return nil, err
	}
	return &Withdraw{pool: pool, log: log, interval: interval, batchSize: batchSize, runTimeout: runTimeout}, nil
}

// Start blocks until ctx is cancelled, sweeping once at startup and then every
// interval. Returns nil on graceful shutdown. Each sweep is independent; a
// failed sweep is logged and the next tick retries (rows stay stuck, not lost).
func (w *Withdraw) Start(ctx context.Context) error {
	w.log.Info("withdraw janitor started",
		slog.Duration("interval", w.interval),
		slog.Int("batch_size", w.batchSize))

	w.runOnce(ctx) // sweep immediately so a restart doesn't wait a full interval

	ticker := time.NewTicker(w.interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			w.log.Info("withdraw janitor stopping")
			return nil
		case <-ticker.C:
			w.runOnce(ctx)
		}
	}
}

// runOnce CALLs reverse_stuck_withdrawals(batch) once under a bounded TX. A
// generous local statement_timeout overrides the pool's OLTP cap (a batch of
// reversals is heavier than a single posting), while still bounding a runaway.
func (w *Withdraw) runOnce(parent context.Context) {
	ctx, cancel := context.WithTimeout(parent, w.runTimeout)
	defer cancel()

	start := time.Now()
	var reversed, failed, expired int

	tx, err := w.pool.Begin(ctx)
	if err != nil {
		w.log.Error("withdraw janitor: begin failed", slog.Any("error", err))
		return
	}
	// Unconditional rollback on a FRESH context so cleanup reaches the server
	// even if ctx already timed out (mirrors repo.withTx).
	defer func() { _ = tx.Rollback(context.Background()) }()

	if _, err := tx.Exec(ctx, fmt.Sprintf("SET LOCAL statement_timeout = %d", w.runTimeout.Milliseconds())); err != nil {
		w.log.Error("withdraw janitor: set timeout failed", slog.Any("error", err))
		return
	}
	row := tx.QueryRow(ctx,
		"SELECT reversed_count, failed_count, expired_count FROM reverse_stuck_withdrawals($1)",
		w.batchSize)
	if err := row.Scan(&reversed, &failed, &expired); err != nil {
		w.log.Error("withdraw janitor: sweep failed",
			slog.Duration("took", time.Since(start)),
			slog.Any("error", err))
		return
	}
	if err := tx.Commit(ctx); err != nil {
		w.log.Error("withdraw janitor: commit failed", slog.Any("error", err))
		return
	}

	// Stay quiet on idle ticks; only log when something actually happened or
	// needs attention (expired/failed always warrant a line).
	if reversed == 0 && failed == 0 && expired == 0 {
		w.log.Debug("withdraw janitor: nothing to reverse", slog.Duration("took", time.Since(start)))
		return
	}
	lvl := slog.LevelInfo
	if failed > 0 || expired > 0 {
		lvl = slog.LevelWarn
	}
	w.log.Log(ctx, lvl, "withdraw janitor: sweep done",
		slog.Int("reversed", reversed),
		slog.Int("failed", failed),
		slog.Int("expired_window", expired),
		slog.Duration("took", time.Since(start)))
}
