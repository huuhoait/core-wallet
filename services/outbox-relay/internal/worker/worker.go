package worker

import (
	"context"
	"encoding/json"
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
// and lets the worker be unit-tested with a fake. Publish returns the
// partition+offset the message landed on so they can be stamped back on the row.
type Producer interface {
	Publish(msg models.KafkaMessage) (int32, int64, error)
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
// (graceful: a claimed batch's transaction commits or rolls back before exit).
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
// marked SENT (with their kafka partition/offset); failures get attempts bumped
// (FAILED, or DEAD once exhausted). Returns the number of rows claimed.
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

	var sent []models.SentRef
	var failIDs []int64
	var lastErr string
	for _, e := range events {
		partition, offset, perr := w.producer.Publish(w.toMessage(e))
		if perr != nil {
			failIDs = append(failIDs, e.EventID)
			lastErr = perr.Error()
			w.metrics.IncrementErrors("publish")
			w.logger.Warn().Err(perr).
				Str("event_uuid", e.EventUUID).
				Str("event_type", e.EventType).
				Int("attempts", e.Attempts).
				Msg("publish failed — will retry")
			continue
		}
		sent = append(sent, models.SentRef{EventID: e.EventID, Partition: partition, Offset: offset})
		w.metrics.IncrementSuccess()
	}

	if err := w.repo.MarkSent(ctx, tx, sent); err != nil {
		return 0, err
	}
	if err := w.repo.MarkFailed(ctx, tx, failIDs, lastErr, w.cfg.MaxRetries); err != nil {
		return 0, err
	}
	if err := tx.Commit(ctx); err != nil {
		return 0, fmt.Errorf("worker: commit batch: %w", err)
	}

	w.metrics.RecordProcessTime(time.Since(start))
	return len(events), nil
}

// toMessage maps an outbox row to its Kafka message. Topic, key (partition_key)
// and payload were chosen at write time; headers (jsonb object) are decoded into
// string→string (best-effort: a non-object/garbled headers value is dropped, not
// fatal — the payload still ships).
func (w *Worker) toMessage(e models.OutboxEvent) models.KafkaMessage {
	var headers map[string]string
	if len(e.Headers) > 0 {
		if err := json.Unmarshal(e.Headers, &headers); err != nil {
			w.logger.Warn().Err(err).Str("event_uuid", e.EventUUID).Msg("unparseable headers — dropping")
			headers = nil
		}
	}
	return models.KafkaMessage{
		Topic:   e.Topic,
		Key:     e.PartitionKey,
		Value:   e.Payload,
		Headers: headers,
	}
}
