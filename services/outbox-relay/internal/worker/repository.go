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

// Repository reads and updates the wallet WLT_OUTBOX over a pgx pool. One
// claim-and-mark cycle runs inside a single transaction (see worker.processBatch)
// so the row locks taken by FetchPendingEvents (FOR UPDATE SKIP LOCKED) are held
// across the Kafka publish — that is what lets multiple workers poll the same
// table without ever publishing a row twice.
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

// FetchPendingEvents claims up to limit un-sent rows (PENDING or a FAILED row due
// for retry), oldest first, locking them with FOR UPDATE SKIP LOCKED so concurrent
// workers skip already-claimed rows instead of blocking.
func (r *Repository) FetchPendingEvents(ctx context.Context, tx pgx.Tx, limit int) ([]models.OutboxEvent, error) {
	rows, err := tx.Query(ctx, `
		SELECT event_id, event_uuid::text, event_type, topic, partition_key, payload, headers, attempts, created_at
		  FROM public.wlt_outbox
		 WHERE status IN ('PENDING', 'FAILED')
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
		if err := rows.Scan(&e.EventID, &e.EventUUID, &e.EventType, &e.Topic,
			&e.PartitionKey, &e.Payload, &e.Headers, &e.Attempts, &e.CreatedAt); err != nil {
			return nil, fmt.Errorf("repository: scan outbox row: %w", err)
		}
		events = append(events, e)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("repository: iterate outbox rows: %w", err)
	}
	return events, nil
}

// MarkSent flips successfully-published rows to SENT and records where each one
// landed (kafka_partition / kafka_offset), in one bulk UPDATE.
func (r *Repository) MarkSent(ctx context.Context, tx pgx.Tx, sent []models.SentRef) error {
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
		return fmt.Errorf("repository: mark sent: %w", err)
	}
	return nil
}

// MarkFailed bumps attempts for rows whose publish failed and records the error.
// A row stays retryable (status FAILED → re-polled) until it reaches maxAttempts,
// after which it is parked as DEAD.
func (r *Repository) MarkFailed(ctx context.Context, tx pgx.Tx, ids []int64, errMsg string, maxAttempts int) error {
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
		return fmt.Errorf("repository: mark failed: %w", err)
	}
	return nil
}

// Close releases the connection pool.
func (r *Repository) Close() {
	r.pool.Close()
}
