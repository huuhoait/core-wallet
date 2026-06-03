package worker

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/rs/zerolog"

	"github.com/huuhoait/core-wallet/outbox-relay/internal/config"
	"github.com/huuhoait/core-wallet/outbox-relay/pkg/models"
)

// Repository reads and updates WLT_OUTBOX over a pgx connection pool. One
// claim-and-mark cycle runs inside a single transaction (see worker.processBatch)
// so the row locks taken by FetchPendingEvents (FOR UPDATE SKIP LOCKED) are held
// across the Kafka publish — that is what lets multiple workers poll the same
// table without ever processing a row twice.
type Repository struct {
	pool   *pgxpool.Pool
	logger *zerolog.Logger
}

// NewRepository opens the pool and verifies connectivity.
func NewRepository(ctx context.Context, cfg *config.Config, logger *zerolog.Logger) (*Repository, error) {
	pool, err := pgxpool.New(ctx, cfg.DSN())
	if err != nil {
		return nil, fmt.Errorf("repository: open pool: %w", err)
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("repository: ping: %w", err)
	}
	logger.Info().Str("db", cfg.DBName).Str("host", cfg.DBHost).Msg("Outbox repository ready")
	return &Repository{pool: pool, logger: logger}, nil
}

// BeginTx starts a transaction for one claim-and-mark cycle.
func (r *Repository) BeginTx(ctx context.Context) (pgx.Tx, error) {
	return r.pool.Begin(ctx)
}

// FetchPendingEvents claims up to limit unprocessed rows, oldest first, locking
// them with FOR UPDATE SKIP LOCKED so concurrent workers skip already-claimed
// rows instead of blocking.
func (r *Repository) FetchPendingEvents(ctx context.Context, tx pgx.Tx, limit int) ([]models.OutboxEvent, error) {
	rows, err := tx.Query(ctx, `
		SELECT id, event_uuid::text, event_type, payload, created_at, processed_at, retry_count
		  FROM public.wlt_outbox
		 WHERE processed_at IS NULL
		 ORDER BY created_at
		 FOR UPDATE SKIP LOCKED
		 LIMIT $1`, limit)
	if err != nil {
		return nil, fmt.Errorf("repository: fetch pending: %w", err)
	}
	defer rows.Close()

	var events []models.OutboxEvent
	for rows.Next() {
		var e models.OutboxEvent
		if err := rows.Scan(&e.ID, &e.EventUUID, &e.EventType, &e.Payload,
			&e.CreatedAt, &e.ProcessedAt, &e.RetryCount); err != nil {
			return nil, fmt.Errorf("repository: scan outbox row: %w", err)
		}
		events = append(events, e)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("repository: iterate outbox rows: %w", err)
	}
	return events, nil
}

// MarkAsProcessed stamps processed_at = now() for the given ids (successful
// publishes), within the supplied transaction.
func (r *Repository) MarkAsProcessed(ctx context.Context, tx pgx.Tx, ids []int64) error {
	if len(ids) == 0 {
		return nil
	}
	if _, err := tx.Exec(ctx,
		`UPDATE public.wlt_outbox SET processed_at = now() WHERE id = ANY($1)`, ids); err != nil {
		return fmt.Errorf("repository: mark processed: %w", err)
	}
	return nil
}

// IncrementRetryCount bumps retry_count for rows whose publish failed, leaving
// processed_at NULL so they are retried on a later poll.
func (r *Repository) IncrementRetryCount(ctx context.Context, tx pgx.Tx, ids []int64) error {
	if len(ids) == 0 {
		return nil
	}
	if _, err := tx.Exec(ctx,
		`UPDATE public.wlt_outbox SET retry_count = retry_count + 1 WHERE id = ANY($1)`, ids); err != nil {
		return fmt.Errorf("repository: increment retry: %w", err)
	}
	return nil
}

// Close releases the connection pool.
func (r *Repository) Close() {
	r.pool.Close()
}
