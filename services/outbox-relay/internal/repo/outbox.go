// Package repo implements the usecase.OutboxRepository driven port against the
// wallet WLT_OUTBOX table over a pgx pool. This is the only place pgx is allowed
// to appear in the relay's read/write path; the usecase layer sees only the port.
package repo

import (
	"context"
	"fmt"
	"log/slog"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/huuhoait/core-wallet/outbox-relay/internal/domain"
	"github.com/huuhoait/core-wallet/outbox-relay/internal/usecase"
)

// PgOutboxRepo reads and updates WLT_OUTBOX over a pgxpool. It satisfies
// usecase.OutboxRepository.
type PgOutboxRepo struct {
	pool   *pgxpool.Pool
	logger *slog.Logger
}

// compile-time check that the adapter satisfies the port.
var _ usecase.OutboxRepository = (*PgOutboxRepo)(nil)

// New opens the pool and verifies connectivity.
func New(ctx context.Context, dsn, dbName, dbHost string, logger *slog.Logger) (*PgOutboxRepo, error) {
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		return nil, fmt.Errorf("repo: open pool: %w", err)
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("repo: ping: %w", err)
	}
	logger.Info("Outbox repository ready", slog.String("db", dbName), slog.String("host", dbHost))
	return &PgOutboxRepo{pool: pool, logger: logger}, nil
}

// Close releases the connection pool.
func (r *PgOutboxRepo) Close() { r.pool.Close() }

// ClaimBatch opens a transaction and locks up to limit un-sent rows (PENDING or a
// FAILED row due for retry), oldest first, with FOR UPDATE SKIP LOCKED so
// concurrent relays skip already-claimed rows instead of blocking. The returned
// Batch holds the transaction (and thus the locks) until Commit/Rollback.
func (r *PgOutboxRepo) ClaimBatch(ctx context.Context, limit int) (usecase.Batch, error) {
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return nil, fmt.Errorf("repo: begin tx: %w", err)
	}

	events, err := fetchPending(ctx, tx, limit)
	if err != nil {
		_ = tx.Rollback(context.Background())
		return nil, err
	}
	return &pgBatch{tx: tx, events: events}, nil
}

// MarkSent flips a single row to SENT by event id, recording where it landed.
// Used by CDC mode; the WHERE guard keeps it idempotent (no-op once SENT/DEAD).
func (r *PgOutboxRepo) MarkSent(ctx context.Context, ref domain.SentRef) error {
	_, err := r.pool.Exec(ctx, `
		UPDATE public.wlt_outbox
		   SET status          = 'SENT',
		       sent_at         = now(),
		       attempts        = attempts + 1,
		       kafka_partition = $2,
		       kafka_offset    = $3,
		       updated_at      = now(),
		       updated_by      = 'outbox-relay-cdc'
		 WHERE event_id = $1
		   AND status IN ('PENDING', 'FAILED')`,
		ref.EventID, ref.Partition, ref.Offset)
	if err != nil {
		return fmt.Errorf("repo: mark sent event_id=%d: %w", ref.EventID, err)
	}
	return nil
}

// pgBatch is one claim-and-mark unit of work, wrapping the pgx transaction that
// holds the SKIP LOCKED row locks. It satisfies usecase.Batch.
type pgBatch struct {
	tx     pgx.Tx
	events []domain.OutboxEvent
}

var _ usecase.Batch = (*pgBatch)(nil)

func (b *pgBatch) Events() []domain.OutboxEvent { return b.events }

// Commit records the outcome (sent + failed) inside the transaction and commits,
// so the row-status updates and the lock release happen atomically.
func (b *pgBatch) Commit(ctx context.Context, sent []domain.SentRef, failedIDs []int64, lastErr string, maxAttempts int) error {
	if err := markSent(ctx, b.tx, sent); err != nil {
		return err
	}
	if err := markFailed(ctx, b.tx, failedIDs, lastErr, maxAttempts); err != nil {
		return err
	}
	if err := b.tx.Commit(ctx); err != nil {
		return fmt.Errorf("repo: commit batch: %w", err)
	}
	return nil
}

// Rollback aborts the unit of work on a fresh context so cleanup reaches the
// server even if the caller's ctx was cancelled. No-op after a successful Commit.
func (b *pgBatch) Rollback(ctx context.Context) { _ = b.tx.Rollback(ctx) }

// fetchPending claims up to limit un-sent rows, locking them with FOR UPDATE
// SKIP LOCKED.
func fetchPending(ctx context.Context, tx pgx.Tx, limit int) ([]domain.OutboxEvent, error) {
	rows, err := tx.Query(ctx, `
		SELECT event_id, event_uuid::text, event_type, topic, partition_key, payload, headers, attempts, created_at
		  FROM public.wlt_outbox
		 WHERE status IN ('PENDING', 'FAILED')
		 ORDER BY created_at
		 FOR UPDATE SKIP LOCKED
		 LIMIT $1`, limit)
	if err != nil {
		return nil, fmt.Errorf("repo: fetch pending: %w", err)
	}
	defer rows.Close()

	var events []domain.OutboxEvent
	for rows.Next() {
		var e domain.OutboxEvent
		if err := rows.Scan(&e.EventID, &e.EventUUID, &e.EventType, &e.Topic,
			&e.PartitionKey, &e.Payload, &e.Headers, &e.Attempts, &e.CreatedAt); err != nil {
			return nil, fmt.Errorf("repo: scan outbox row: %w", err)
		}
		events = append(events, e)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("repo: iterate outbox rows: %w", err)
	}
	return events, nil
}

// markSent flips successfully-published rows to SENT and records where each one
// landed (kafka_partition / kafka_offset), in one bulk UPDATE.
func markSent(ctx context.Context, tx pgx.Tx, sent []domain.SentRef) error {
	if len(sent) == 0 {
		return nil
	}
	ids := make([]int64, len(sent))
	parts := make([]int32, len(sent))
	offs := make([]int64, len(sent))
	for i, s := range sent {
		ids[i], parts[i], offs[i] = s.EventID, s.Partition, s.Offset
	}
	if _, err := tx.Exec(ctx, `
		UPDATE public.wlt_outbox o
		   SET status          = 'SENT',
		       sent_at         = now(),
		       attempts        = o.attempts + 1,
		       kafka_partition = v.part,
		       kafka_offset    = v.off,
		       updated_at      = now(),
		       updated_by      = 'outbox-relay'
		  FROM (SELECT unnest($1::bigint[]) AS id,
		               unnest($2::int[])    AS part,
		               unnest($3::bigint[]) AS off) v
		 WHERE o.event_id = v.id`, ids, parts, offs); err != nil {
		return fmt.Errorf("repo: mark sent: %w", err)
	}
	return nil
}

// markFailed bumps attempts for rows whose publish failed and records the error.
// A row stays retryable (status FAILED → re-polled) until it reaches maxAttempts,
// after which it is parked as DEAD.
func markFailed(ctx context.Context, tx pgx.Tx, ids []int64, errMsg string, maxAttempts int) error {
	if len(ids) == 0 {
		return nil
	}
	if len(errMsg) > 500 {
		errMsg = errMsg[:500]
	}
	if _, err := tx.Exec(ctx, `
		UPDATE public.wlt_outbox
		   SET attempts        = attempts + 1,
		       last_attempt_at = now(),
		       last_error      = $2,
		       status          = CASE WHEN attempts + 1 >= $3 THEN 'DEAD' ELSE 'FAILED' END,
		       updated_at      = now(),
		       updated_by      = 'outbox-relay'
		 WHERE event_id = ANY($1)`, ids, errMsg, maxAttempts); err != nil {
		return fmt.Errorf("repo: mark failed: %w", err)
	}
	return nil
}
