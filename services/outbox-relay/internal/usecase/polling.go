package usecase

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"math"
	"sync"
	"time"

	"github.com/huuhoait/core-wallet/outbox-relay/internal/domain"
)

// batchCommitTimeout bounds the fresh context used to commit a claimed batch's
// outcome. It is deliberately independent of the caller's (possibly cancelled)
// ctx so the final in-flight batch still drains on shutdown; the DB pool's own
// statement/lock timeouts remain the inner bound on the commit itself.
const batchCommitTimeout = 5 * time.Second

// RetryBackoff bounds when a FAILED outbox row becomes eligible for re-claim.
// A FAILED row is skipped until Base*2^(attempts-1) (capped at Max) has elapsed
// since its last_attempt_at, giving exponential backoff so a transient broker
// outage does not burn the whole attempt budget in milliseconds and DEAD the
// events. With Base=5s, Max=5m and MaxAttempts=10 the total window from first
// failure to DEAD is ~20 minutes (5+10+20+40+80+160+300+300+300s).
type RetryBackoff struct {
	Base time.Duration
	Max  time.Duration
}

// Delay returns how long a row that has now failed `attempts` times waits before
// it is eligible for re-claim: Base*2^(attempts-1), capped at Max. It mirrors the
// SQL claim predicate in repo.fetchPending (kept in lockstep) and is used both to
// surface the next-retry ETA in logs and to make the schedule unit-testable. The
// exponent is bounded to avoid overflow, matching the SQL LEAST(...,20) guard.
func (b RetryBackoff) Delay(attempts int) time.Duration {
	exp := attempts - 1
	if exp < 0 {
		exp = 0
	}
	if exp > 20 {
		exp = 20
	}
	d := time.Duration(float64(b.Base) * math.Pow(2, float64(exp)))
	if b.Max > 0 && (d > b.Max || d < 0) { // d<0 guards int64 overflow
		return b.Max
	}
	return d
}

// PollingSettings carries the runtime knobs the polling relay needs. The
// composition root fills it from config so the usecase never imports the config
// package.
type PollingSettings struct {
	WorkerCount int
	BatchSize   int
	// MaxAttempts is the DEAD threshold: a row that fails to publish this many
	// times is parked DEAD (no longer retried). Distinct from the Kafka producer's
	// per-send retry budget.
	MaxAttempts int
	// Backoff governs how long a FAILED row waits before it is re-claimed.
	Backoff      RetryBackoff
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

	batch, err := r.repo.ClaimBatch(ctx, r.cfg.BatchSize, r.cfg.Backoff)
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
			// This failure is the (Attempts+1)th; mirror the SQL DEAD rule
			// (attempts+1 >= MaxAttempts) so a DEAD transition is never silent.
			if e.Attempts+1 >= r.cfg.MaxAttempts {
				r.metrics.IncrementDead()
				r.log.Error("outbox event exhausted retries — parking DEAD",
					slog.Any("error", perr),
					slog.String("event_uuid", e.EventUUID),
					slog.String("event_type", e.EventType),
					slog.Int("attempts", e.Attempts+1),
					slog.Int("max_attempts", r.cfg.MaxAttempts))
			} else {
				r.log.Warn("publish failed — will retry",
					slog.Any("error", perr),
					slog.String("event_uuid", e.EventUUID),
					slog.String("event_type", e.EventType),
					slog.Int("attempts", e.Attempts+1),
					slog.Duration("retry_in", r.cfg.Backoff.Delay(e.Attempts+1)))
			}
			continue
		}
		sent = append(sent, domain.SentRef{EventID: e.EventID, Partition: partition, Offset: offset})
		r.metrics.IncrementSuccess()
	}

	// Persisting the batch outcome must survive shutdown: once we have published to
	// Kafka, committing on a cancelled ctx would roll back the SENT marks and the
	// same events would be re-published on restart (needless duplicates). Commit on
	// a fresh, bounded context so the final in-flight batch always drains — mirrors
	// the withTx fresh-context cleanup pattern. Still at-least-once, never drops.
	commitCtx, cancel := context.WithTimeout(context.Background(), batchCommitTimeout)
	defer cancel()
	if err := batch.Commit(commitCtx, sent, failIDs, lastErr, r.cfg.MaxAttempts); err != nil {
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
