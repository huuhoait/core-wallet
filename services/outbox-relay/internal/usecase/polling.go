package usecase

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"sync"
	"time"

	"github.com/huuhoait/core-wallet/outbox-relay/internal/domain"
)

// PollingSettings carries the runtime knobs the polling relay needs. The
// composition root fills it from config so the usecase never imports the config
// package.
type PollingSettings struct {
	WorkerCount  int
	BatchSize    int
	MaxRetries   int
	PollInterval time.Duration
}

// PollingRelay runs a pool of goroutines that claim WLT_OUTBOX batches and relay
// pending events to the broker. All goroutines share the repository and the
// publisher (both driven ports), so the relay is fully unit-testable with fakes.
type PollingRelay struct {
	repo    OutboxRepository
	pub     EventPublisher
	metrics MetricsRecorder
	cfg     PollingSettings
	log     *slog.Logger

	cancel context.CancelFunc
	wg     sync.WaitGroup
}

// NewPollingRelay wires the polling relay.
func NewPollingRelay(repo OutboxRepository, pub EventPublisher, metrics MetricsRecorder, cfg PollingSettings, log *slog.Logger) *PollingRelay {
	return &PollingRelay{repo: repo, pub: pub, metrics: metrics, cfg: cfg, log: log}
}

// Start launches cfg.WorkerCount poll loops. It is non-blocking; the loops run
// until Stop is called or the parent ctx is cancelled.
func (r *PollingRelay) Start(ctx context.Context) {
	ctx, r.cancel = context.WithCancel(ctx)
	for i := 0; i < r.cfg.WorkerCount; i++ {
		r.wg.Add(1)
		go r.run(ctx, i)
	}
	r.log.Info("Outbox workers started", slog.Int("workers", r.cfg.WorkerCount))
}

// Stop signals the loops to finish and waits for in-flight batches to complete
// (graceful: a claimed batch's unit of work commits or rolls back before exit).
func (r *PollingRelay) Stop() {
	if r.cancel != nil {
		r.cancel()
	}
	r.wg.Wait()
	r.log.Info("Outbox workers stopped")
}

// run is one poll loop: claim+relay a batch, then idle for PollInterval whenever
// there was nothing pending.
func (r *PollingRelay) run(ctx context.Context, id int) {
	defer r.wg.Done()
	log := r.log.With(slog.Int("worker", id))
	for {
		select {
		case <-ctx.Done():
			return
		default:
		}

		n, err := r.processBatch(ctx)
		if err != nil {
			if ctx.Err() != nil { // shutting down — not a real failure
				return
			}
			log.Error("batch failed", slog.Any("error", err))
		}
		if n == 0 {
			select {
			case <-ctx.Done():
				return
			case <-time.After(r.cfg.PollInterval):
			}
		}
	}
}

// processBatch claims and relays one batch as a single unit of work so the SKIP
// LOCKED row locks are held across the publishes. Successful publishes are marked
// SENT (with their kafka partition/offset); failures get attempts bumped (FAILED,
// or DEAD once exhausted). Returns the number of rows claimed.
func (r *PollingRelay) processBatch(ctx context.Context) (int, error) {
	start := time.Now()

	batch, err := r.repo.ClaimBatch(ctx, r.cfg.BatchSize)
	if err != nil {
		return 0, err
	}
	// Fresh ctx so the rollback still reaches the server if ctx was cancelled.
	// No-op after a successful Commit.
	defer batch.Rollback(context.Background())

	events := batch.Events()
	r.metrics.RecordFetch(len(events))
	if len(events) == 0 {
		return 0, nil
	}

	var sent []domain.SentRef
	var failIDs []int64
	var lastErr string
	for _, e := range events {
		partition, offset, perr := r.pub.Publish(r.toMessage(e))
		if perr != nil {
			failIDs = append(failIDs, e.EventID)
			lastErr = perr.Error()
			r.metrics.IncrementErrors("publish")
			r.log.Warn("publish failed — will retry",
				slog.Any("error", perr),
				slog.String("event_uuid", e.EventUUID),
				slog.String("event_type", e.EventType),
				slog.Int("attempts", e.Attempts))
			continue
		}
		sent = append(sent, domain.SentRef{EventID: e.EventID, Partition: partition, Offset: offset})
		r.metrics.IncrementSuccess()
	}

	if err := batch.Commit(ctx, sent, failIDs, lastErr, r.cfg.MaxRetries); err != nil {
		return 0, fmt.Errorf("polling: commit batch: %w", err)
	}

	r.metrics.RecordProcessTime(time.Since(start))
	return len(events), nil
}

// toMessage maps an outbox row to its Kafka message. Topic, key (partition_key)
// and payload were chosen at write time; headers (jsonb object) are decoded into
// string→string (best-effort: a non-object/garbled headers value is dropped, not
// fatal — the payload still ships).
func (r *PollingRelay) toMessage(e domain.OutboxEvent) domain.KafkaMessage {
	var headers map[string]string
	if len(e.Headers) > 0 {
		if err := json.Unmarshal(e.Headers, &headers); err != nil {
			r.log.Warn("unparseable headers — dropping", slog.Any("error", err), slog.String("event_uuid", e.EventUUID))
			headers = nil
		}
	}
	return domain.KafkaMessage{
		Topic:   e.Topic,
		Key:     e.PartitionKey,
		Value:   e.Payload,
		Headers: headers,
	}
}
