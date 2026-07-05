package janitor

// This file adds the partition roll-forward janitor. It complements the
// withdrawal SLA sweeper (withdraw.go) in the same package: both are in-process
// tickers on the ordinary app pool, but this one CREATES partitions ahead of
// time rather than reversing rows.
//
// The 4 partitioned parents (wlt_tran_hist, wlt_outbox, wlt_acct_bal,
// fm_client_audit_log) hold monthly RANGE partitions pre-created by
// partitions.sql only through a fixed horizon. Once inserts pass that horizon
// they land in the DEFAULT catch-all partition, which bloats AND blocks ever
// adding the proper month's partition (a DEFAULT holding rows in a range forbids
// attaching a partition over that range until the rows are moved). This janitor
// re-runs fn_ensure_wallet_partitions(current_month, current_month + N months)
// daily so a partition for each upcoming month always exists before any row
// needs it.
//
// fn_ensure_wallet_partitions is idempotent (CREATE … IF NOT EXISTS), so running
// this on several replicas at once is harmless — there is no leader election and
// none is needed (contrast the destructive/singleton EOD + withdraw jobs). The
// function is SECURITY DEFINER, so wallet_app calls it without holding any DDL
// privilege on the parents.

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// Partition rolls monthly partitions forward on a fixed interval.
type Partition struct {
	pool            *pgxpool.Pool
	log             *slog.Logger
	interval        time.Duration
	lookaheadMonths int
	runTimeout      time.Duration
}

// validatePartitionConfig checks the scalar tuning args (pure, no pool) so it can
// be unit tested without a database.
func validatePartitionConfig(interval time.Duration, lookaheadMonths int, runTimeout time.Duration) error {
	if interval <= 0 {
		return fmt.Errorf("partition janitor: interval must be > 0")
	}
	if lookaheadMonths <= 0 {
		return fmt.Errorf("partition janitor: lookahead months must be > 0")
	}
	if runTimeout <= 0 {
		return fmt.Errorf("partition janitor: run timeout must be > 0")
	}
	return nil
}

// NewPartition builds the roller. interval is the roll cadence (daily is plenty),
// lookaheadMonths is how many months of partitions to keep ahead of the current
// month, runTimeout caps a single roll.
func NewPartition(pool *pgxpool.Pool, interval time.Duration, lookaheadMonths int, runTimeout time.Duration, log *slog.Logger) (*Partition, error) {
	if pool == nil {
		return nil, fmt.Errorf("partition janitor: pool is required")
	}
	if err := validatePartitionConfig(interval, lookaheadMonths, runTimeout); err != nil {
		return nil, err
	}
	return &Partition{pool: pool, log: log, interval: interval, lookaheadMonths: lookaheadMonths, runTimeout: runTimeout}, nil
}

// Start blocks until ctx is cancelled, rolling once at startup (so a fresh deploy
// seeds ahead immediately, not after a full interval) and then every interval.
// Returns nil on graceful shutdown. Each roll is independent; a failed roll is
// logged and the next tick retries. Because partitions are created N months
// ahead, a transient failure has huge slack before any partition is actually
// needed.
func (p *Partition) Start(ctx context.Context) error {
	p.log.Info("partition janitor started",
		slog.Duration("interval", p.interval),
		slog.Int("lookahead_months", p.lookaheadMonths))

	p.runOnce(ctx) // roll immediately so a restart doesn't wait a full interval

	ticker := time.NewTicker(p.interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			p.log.Info("partition janitor stopping")
			return nil
		case <-ticker.C:
			p.runOnce(ctx)
		}
	}
}

// runOnce calls fn_ensure_wallet_partitions(current_month, current_month + N
// months) once under a bounded TX. The current month and the upper bound are
// computed IN THE DATABASE (date_trunc('month', now())) so the window tracks the
// server's clock/timezone rather than the pod's, and the lookahead is passed as a
// bound parameter (no SQL string-building). A local statement_timeout bounds the
// DDL; on lock contention it aborts and the next tick retries (create-ahead slack
// absorbs the delay). The function is idempotent, so this never double-creates.
func (p *Partition) runOnce(parent context.Context) {
	ctx, cancel := context.WithTimeout(parent, p.runTimeout)
	defer cancel()

	start := time.Now()

	tx, err := p.pool.Begin(ctx)
	if err != nil {
		p.log.Error("partition janitor: begin failed", slog.Any("error", err))
		return
	}
	// Unconditional rollback on a FRESH context so cleanup reaches the server
	// even if ctx already timed out (mirrors repo.withTx / withdraw janitor).
	defer func() { _ = tx.Rollback(context.Background()) }()

	if _, err := tx.Exec(ctx, fmt.Sprintf("SET LOCAL statement_timeout = %d", p.runTimeout.Milliseconds())); err != nil {
		p.log.Error("partition janitor: set timeout failed", slog.Any("error", err))
		return
	}

	// Compute the [from, to) month window in the DB and ensure it in one round
	// trip. The CROSS JOIN LATERAL forces fn_ensure_wallet_partitions to be
	// evaluated (its void result is discarded) while we read back the resolved
	// bounds for the log line.
	const q = `
SELECT b.from_m::text, b.to_m::text
FROM (
    SELECT date_trunc('month', now())::date AS from_m,
           (date_trunc('month', now()) + make_interval(months => $1::int))::date AS to_m
) b
CROSS JOIN LATERAL fn_ensure_wallet_partitions(b.from_m, b.to_m) AS _ensured`
	var fromM, toM string
	if err := tx.QueryRow(ctx, q, p.lookaheadMonths).Scan(&fromM, &toM); err != nil {
		p.log.Error("partition janitor: ensure failed",
			slog.Int("lookahead_months", p.lookaheadMonths),
			slog.Duration("took", time.Since(start)),
			slog.Any("error", err))
		return
	}
	if err := tx.Commit(ctx); err != nil {
		p.log.Error("partition janitor: commit failed", slog.Any("error", err))
		return
	}

	p.log.Info("partition janitor: ensured partitions",
		slog.String("from_month", fromM),
		slog.String("to_month", toM),
		slog.Int("lookahead_months", p.lookaheadMonths),
		slog.Duration("took", time.Since(start)))
}
