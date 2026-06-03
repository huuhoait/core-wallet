package worker

import (
	"context"
	"fmt"
	"sync"
	"time"

	"github.com/rs/zerolog"

	"github.com/huuhoait/core-wallet/outbox-relay/internal/config"
	"github.com/huuhoait/core-wallet/outbox-relay/pkg/models"
	"github.com/huuhoait/core-wallet/outbox-relay/pkg/utils"
)

// Producer is the subset of the Kafka producer the worker needs. Keeping it an
// interface (rather than importing the producer package) avoids an import cycle
// and lets the worker be unit-tested with a fake.
type Producer interface {
	Publish(msg models.KafkaMessage) error
}

// Worker runs a pool of goroutines that poll WLT_OUTBOX and relay pending events
// to Kafka. All goroutines share the repository pool and the producer.
type Worker struct {
	repo     *Repository
	producer Producer
	cfg      *config.Config
	logger   *zerolog.Logger
	metrics  *utils.Metrics

	cancel context.CancelFunc
	wg     sync.WaitGroup
}

// NewWorker wires the relay worker.
func NewWorker(repo *Repository, producer Producer, cfg *config.Config, logger *zerolog.Logger, metrics *utils.Metrics) *Worker {
	return &Worker{repo: repo, producer: producer, cfg: cfg, logger: logger, metrics: metrics}
}

// Start launches cfg.WorkerCount poll loops. It is non-blocking; the loops run
// until Stop is called or the parent ctx is cancelled.
func (w *Worker) Start(ctx context.Context) {
	ctx, w.cancel = context.WithCancel(ctx)
	for i := 0; i < w.cfg.WorkerCount; i++ {
		w.wg.Add(1)
		go w.run(ctx, i)
	}
	w.logger.Info().Int("workers", w.cfg.WorkerCount).Msg("Outbox workers started")
}

// Stop signals the loops to finish and waits for in-flight batches to complete
// (graceful: a claimed batch's transaction either commits or rolls back before
// the goroutine exits).
func (w *Worker) Stop() {
	if w.cancel != nil {
		w.cancel()
	}
	w.wg.Wait()
	w.logger.Info().Msg("Outbox workers stopped")
}

// run is one poll loop: claim+relay a batch, then idle for PollInterval whenever
// there was nothing pending.
func (w *Worker) run(ctx context.Context, id int) {
	defer w.wg.Done()
	log := w.logger.With().Int("worker", id).Logger()
	for {
		select {
		case <-ctx.Done():
			return
		default:
		}

		n, err := w.processBatch(ctx)
		if err != nil {
			if ctx.Err() != nil { // shutting down — not a real failure
				return
			}
			log.Error().Err(err).Msg("batch failed")
		}
		if n == 0 {
			select {
			case <-ctx.Done():
				return
			case <-time.After(w.cfg.PollInterval):
			}
		}
	}
}

// processBatch claims and relays one batch inside a single transaction so the
// SKIP LOCKED row locks are held across the publishes. Successful publishes are
// marked processed; failures get retry_count bumped (left pending). Returns the
// number of rows claimed.
func (w *Worker) processBatch(ctx context.Context) (int, error) {
	start := time.Now()

	tx, err := w.repo.BeginTx(ctx)
	if err != nil {
		return 0, err
	}
	// Fresh ctx so the rollback still reaches the server if ctx was cancelled.
	// No-op after a successful Commit.
	defer tx.Rollback(context.Background())

	events, err := w.repo.FetchPendingEvents(ctx, tx, w.cfg.BatchSize)
	if err != nil {
		return 0, err
	}
	w.metrics.RecordFetch(len(events))
	if len(events) == 0 {
		return 0, nil
	}

	var okIDs, failIDs []int64
	for _, e := range events {
		if err := w.producer.Publish(w.toMessage(e)); err != nil {
			failIDs = append(failIDs, e.ID)
			w.metrics.IncrementErrors("publish")
			w.logger.Warn().Err(err).
				Str("event_uuid", e.EventUUID).
				Str("event_type", e.EventType).
				Int("retry_count", e.RetryCount).
				Msg("publish failed — will retry")
			continue
		}
		okIDs = append(okIDs, e.ID)
		w.metrics.IncrementSuccess()
	}

	if err := w.repo.MarkAsProcessed(ctx, tx, okIDs); err != nil {
		return 0, err
	}
	if err := w.repo.IncrementRetryCount(ctx, tx, failIDs); err != nil {
		return 0, err
	}
	if err := tx.Commit(ctx); err != nil {
		return 0, fmt.Errorf("worker: commit batch: %w", err)
	}

	w.metrics.RecordProcessTime(time.Since(start))
	return len(events), nil
}

// toMessage maps an outbox row to its Kafka message: topic = prefix.event_type,
// key = event_uuid (all events of one entity hash to the same partition → order
// preserved per entity), value = the raw JSON payload.
func (w *Worker) toMessage(e models.OutboxEvent) models.KafkaMessage {
	return models.KafkaMessage{
		Topic: fmt.Sprintf("%s.%s", w.cfg.KafkaTopicPrefix, e.EventType),
		Key:   e.EventUUID,
		Value: e.Payload,
		Headers: map[string]string{
			"event_type": e.EventType,
			"event_uuid": e.EventUUID,
		},
	}
}
