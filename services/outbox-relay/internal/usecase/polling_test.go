package usecase

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"testing"
	"time"

	"github.com/huuhoait/core-wallet/outbox-relay/internal/domain"
)

// --- fakes for the driven ports ---

type fakeBatch struct {
	events      []domain.OutboxEvent
	sent        []domain.SentRef
	failedIDs   []int64
	lastErr     string
	maxAttempts int
	committed   bool
	rolledBack  bool
}

func (b *fakeBatch) Events() []domain.OutboxEvent { return b.events }

func (b *fakeBatch) Commit(_ context.Context, sent []domain.SentRef, failedIDs []int64, lastErr string, maxAttempts int) error {
	b.sent, b.failedIDs, b.lastErr, b.maxAttempts, b.committed = sent, failedIDs, lastErr, maxAttempts, true
	return nil
}

func (b *fakeBatch) Rollback(context.Context) { b.rolledBack = true }

type fakeRepo struct {
	batch  *fakeBatch
	marked []domain.SentRef
}

func (r *fakeRepo) ClaimBatch(context.Context, int) (Batch, error) { return r.batch, nil }
func (r *fakeRepo) MarkSent(_ context.Context, ref domain.SentRef) error {
	r.marked = append(r.marked, ref)
	return nil
}
func (r *fakeRepo) Close() {}

type fakePublisher struct {
	failKeys  map[string]bool
	published []domain.KafkaMessage
	offset    int64
}

func (p *fakePublisher) Publish(msg domain.KafkaMessage) (int32, int64, error) {
	if p.failKeys[msg.Key] {
		return 0, 0, errors.New("publish boom")
	}
	p.published = append(p.published, msg)
	p.offset++
	return 3, p.offset, nil
}
func (p *fakePublisher) Close() error { return nil }

type fakeMetrics struct {
	fetched, success int
	errors           map[string]int
}

func newFakeMetrics() *fakeMetrics { return &fakeMetrics{errors: map[string]int{}} }

func (m *fakeMetrics) RecordFetch(n int)               { m.fetched += n }
func (m *fakeMetrics) IncrementSuccess()               { m.success++ }
func (m *fakeMetrics) IncrementErrors(kind string)     { m.errors[kind]++ }
func (m *fakeMetrics) RecordProcessTime(time.Duration) {}

func nopLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

func events() []domain.OutboxEvent {
	return []domain.OutboxEvent{
		{EventID: 1, EventUUID: "u1", Topic: "t", PartitionKey: "k1", Payload: []byte(`{"a":1}`)},
		{EventID: 2, EventUUID: "u2", Topic: "t", PartitionKey: "k2", Payload: []byte(`{"a":2}`)},
		{EventID: 3, EventUUID: "u3", Topic: "t", PartitionKey: "k3", Payload: []byte(`{"a":3}`)},
	}
}

func newRelay(repo OutboxRepository, pub EventPublisher, m MetricsRecorder) *PollingRelay {
	return NewPollingRelay(repo, pub, m, PollingSettings{BatchSize: 10, MaxRetries: 3}, nopLogger())
}

// TestProcessBatch_AllPublished verifies every claimed event is published and the
// batch commits all of them as SENT, with their partition/offset recorded.
func TestProcessBatch_AllPublished(t *testing.T) {
	batch := &fakeBatch{events: events()}
	repo := &fakeRepo{batch: batch}
	pub := &fakePublisher{failKeys: map[string]bool{}}
	m := newFakeMetrics()

	n, err := newRelay(repo, pub, m).processBatch(context.Background())
	if err != nil {
		t.Fatalf("processBatch: %v", err)
	}
	if n != 3 {
		t.Fatalf("claimed = %d, want 3", n)
	}
	if !batch.committed {
		t.Fatal("batch was not committed")
	}
	if len(batch.sent) != 3 {
		t.Fatalf("sent = %d, want 3", len(batch.sent))
	}
	if len(batch.failedIDs) != 0 {
		t.Fatalf("failedIDs = %v, want none", batch.failedIDs)
	}
	if len(pub.published) != 3 {
		t.Fatalf("published = %d, want 3", len(pub.published))
	}
	if m.success != 3 || m.fetched != 3 {
		t.Fatalf("metrics success=%d fetched=%d, want 3/3", m.success, m.fetched)
	}
}

// TestProcessBatch_PartialFailure verifies a publish failure routes that event to
// the failed set (for retry) while the others still commit SENT.
func TestProcessBatch_PartialFailure(t *testing.T) {
	batch := &fakeBatch{events: events()}
	repo := &fakeRepo{batch: batch}
	pub := &fakePublisher{failKeys: map[string]bool{"k2": true}}
	m := newFakeMetrics()

	n, err := newRelay(repo, pub, m).processBatch(context.Background())
	if err != nil {
		t.Fatalf("processBatch: %v", err)
	}
	if n != 3 {
		t.Fatalf("claimed = %d, want 3", n)
	}
	if len(batch.sent) != 2 {
		t.Fatalf("sent = %d, want 2", len(batch.sent))
	}
	if len(batch.failedIDs) != 1 || batch.failedIDs[0] != 2 {
		t.Fatalf("failedIDs = %v, want [2]", batch.failedIDs)
	}
	if batch.lastErr == "" {
		t.Fatal("lastErr not recorded for failed publish")
	}
	if batch.maxAttempts != 3 {
		t.Fatalf("maxAttempts = %d, want 3", batch.maxAttempts)
	}
	if m.errors["publish"] != 1 {
		t.Fatalf("publish errors = %d, want 1", m.errors["publish"])
	}
}

// TestProcessBatch_Empty verifies an empty claim commits nothing and reports 0.
func TestProcessBatch_Empty(t *testing.T) {
	batch := &fakeBatch{}
	repo := &fakeRepo{batch: batch}
	pub := &fakePublisher{failKeys: map[string]bool{}}

	n, err := newRelay(repo, pub, newFakeMetrics()).processBatch(context.Background())
	if err != nil {
		t.Fatalf("processBatch: %v", err)
	}
	if n != 0 {
		t.Fatalf("claimed = %d, want 0", n)
	}
	if batch.committed {
		t.Fatal("empty batch should not commit")
	}
}

// TestCDCStatusUpdater verifies the CDC use case guards a zero event_id and marks
// a valid one delivered via the repo.
func TestCDCStatusUpdater(t *testing.T) {
	repo := &fakeRepo{}
	u := NewCDCStatusUpdater(repo)

	if err := u.MarkDelivered(context.Background(), domain.SentRef{EventID: 0}); !errors.Is(err, domain.ErrZeroEventID) {
		t.Fatalf("zero event_id: got %v, want ErrZeroEventID", err)
	}

	ref := domain.SentRef{EventID: 42, Partition: 1, Offset: 99}
	if err := u.MarkDelivered(context.Background(), ref); err != nil {
		t.Fatalf("MarkDelivered: %v", err)
	}
	if len(repo.marked) != 1 || repo.marked[0] != ref {
		t.Fatalf("marked = %v, want [%v]", repo.marked, ref)
	}
}
