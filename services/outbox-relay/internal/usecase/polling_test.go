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

func (r *fakeRepo) ClaimBatch(context.Context, int, RetryBackoff) (Batch, error) {
	return r.batch, nil
}
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
	fetched, success, dead int
	errors                 map[string]int
}

func newFakeMetrics() *fakeMetrics { return &fakeMetrics{errors: map[string]int{}} }

func (m *fakeMetrics) RecordFetch(n int)               { m.fetched += n }
func (m *fakeMetrics) IncrementSuccess()               { m.success++ }
func (m *fakeMetrics) IncrementErrors(kind string)     { m.errors[kind]++ }
func (m *fakeMetrics) IncrementDead()                  { m.dead++ }
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
	return NewPollingRelay(repo, pub, m, PollingSettings{
		BatchSize:   10,
		MaxAttempts: 3,
		Backoff:     RetryBackoff{Base: time.Second, Max: time.Minute},
	}, nopLogger())
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

// TestRetryBackoff_Delay verifies the exponential backoff schedule the relay logs
// and the SQL claim predicate mirror: Base*2^(attempts-1), capped at Max, with a
// floored/bounded exponent (no negative exponent, no int64 overflow at high n).
func TestRetryBackoff_Delay(t *testing.T) {
	b := RetryBackoff{Base: 5 * time.Second, Max: 5 * time.Minute}
	cases := []struct {
		attempts int
		want     time.Duration
	}{
		{0, 5 * time.Second},   // exponent floored at 0
		{1, 5 * time.Second},   // base * 2^0
		{2, 10 * time.Second},  // base * 2^1
		{3, 20 * time.Second},  // base * 2^2
		{4, 40 * time.Second},  // base * 2^3
		{6, 160 * time.Second}, // base * 2^5
		{7, 5 * time.Minute},   // 320s > cap → 300s
		{50, 5 * time.Minute},  // capped, exponent bound prevents overflow
	}
	for _, c := range cases {
		if got := b.Delay(c.attempts); got != c.want {
			t.Errorf("Delay(%d) = %s, want %s", c.attempts, got, c.want)
		}
	}
}

// TestProcessBatch_DeadTransition verifies that when a failing event exhausts its
// attempt budget (Attempts+1 >= MaxAttempts) the relay increments the dedicated
// DEAD metric AND still commits the batch (the mark-DEAD write is persisted, and
// under-budget failures are NOT flagged DEAD) — at-least-once, nothing dropped.
func TestProcessBatch_DeadTransition(t *testing.T) {
	evs := []domain.OutboxEvent{
		{EventID: 1, EventUUID: "u1", Topic: "t", PartitionKey: "k1", Payload: []byte(`{}`), Attempts: 0}, // fails, under budget
		{EventID: 2, EventUUID: "u2", Topic: "t", PartitionKey: "k2", Payload: []byte(`{}`), Attempts: 2}, // 3rd failure → DEAD (MaxAttempts=3)
	}
	batch := &fakeBatch{events: evs}
	repo := &fakeRepo{batch: batch}
	pub := &fakePublisher{failKeys: map[string]bool{"k1": true, "k2": true}}
	m := newFakeMetrics()

	if _, err := newRelay(repo, pub, m).processBatch(context.Background()); err != nil {
		t.Fatalf("processBatch: %v", err)
	}
	if m.dead != 1 {
		t.Fatalf("dead metric = %d, want 1 (only the budget-exhausted event)", m.dead)
	}
	if len(batch.failedIDs) != 2 {
		t.Fatalf("failedIDs = %v, want both events retried/marked", batch.failedIDs)
	}
	if !batch.committed {
		t.Fatal("batch must commit so the DEAD mark is persisted (not dropped)")
	}
	if batch.maxAttempts != 3 {
		t.Fatalf("maxAttempts passed to commit = %d, want 3", batch.maxAttempts)
	}
}
