// Package usecase contains the application services that orchestrate the relay
// (polling and CDC). It defines the driven ports (interfaces) those services
// depend on; concrete implementations live in the adapter packages
// (internal/repo, internal/kafka, internal/debezium, internal/metrics).
//
// Layering rule: usecase depends on internal/domain and the standard library
// only. It MUST NOT import pgx, sarama, or net/http. The injected *zerolog.Logger
// is the single permitted logging primitive (a leaf dependency, not a framework
// that dictates structure).
package usecase

import (
	"context"
	"time"

	"github.com/huuhoait/core-wallet/outbox-relay/internal/domain"
)

// OutboxRepository is the driven port for the WLT_OUTBOX store.
// Implemented by internal/repo.PgOutboxRepo.
type OutboxRepository interface {
	// ClaimBatch opens a unit of work that locks up to limit un-sent rows
	// (PENDING or FAILED, FOR UPDATE SKIP LOCKED) and returns them with a Batch
	// handle to finalize the result. The locks are held until the Batch is
	// committed or rolled back, so publishes happen while the rows are locked —
	// that is what lets multiple relays poll the same table without ever
	// publishing a row twice.
	ClaimBatch(ctx context.Context, limit int) (Batch, error)

	// MarkSent flips a single row to SENT by event id, recording where it landed.
	// Used by CDC mode (no lock/tx needed — Debezium already delivered the row).
	// A no-op if the row is not currently PENDING/FAILED.
	MarkSent(ctx context.Context, ref domain.SentRef) error

	// Close releases the underlying connection pool.
	Close()
}

// Batch is one claim-and-mark unit of work returned by ClaimBatch. Callers MUST
// call exactly one of Commit or Rollback (Rollback is a no-op after a Commit, so
// `defer batch.Rollback(...)` is the safe idiom).
type Batch interface {
	// Events returns the rows claimed by this batch (possibly empty).
	Events() []domain.OutboxEvent

	// Commit records the outcome and commits the unit of work atomically: sent
	// rows are marked SENT (with their partition/offset); failedIDs get attempts
	// bumped and lastErr recorded, parked as DEAD once attempts reach maxAttempts.
	Commit(ctx context.Context, sent []domain.SentRef, failedIDs []int64, lastErr string, maxAttempts int) error

	// Rollback aborts the unit of work. Safe to call after Commit (no-op).
	Rollback(ctx context.Context)
}

// EventPublisher is the driven port for delivering messages to the broker.
// Implemented by internal/kafka.SyncProducer. Publish returns the partition and
// offset the message landed on so the caller can stamp them back on the row;
// the at-least-once outbox guarantee relies on this ack arriving before the row
// is marked SENT.
type EventPublisher interface {
	Publish(msg domain.KafkaMessage) (partition int32, offset int64, err error)
	Close() error
}

// ConnectorController is the driven port for the CDC connector lifecycle.
// Implemented by internal/debezium.ConnectorManager.
type ConnectorController interface {
	// Ensure registers or updates the connector (idempotent).
	Ensure(ctx context.Context) error
	// Status returns the connector state (RUNNING, PAUSED, FAILED, NOT_FOUND, ...).
	Status(ctx context.Context) (string, error)
	Pause(ctx context.Context) error
	Resume(ctx context.Context) error
}

// MetricsRecorder is the driven port for relay metrics.
// Implemented by internal/metrics.Metrics.
type MetricsRecorder interface {
	RecordFetch(count int)
	IncrementSuccess()
	IncrementErrors(kind string)
	RecordProcessTime(d time.Duration)
}
