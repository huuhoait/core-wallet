package kafka

import (
	"context"
	"testing"

	"go.opentelemetry.io/otel/propagation"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"
	"go.opentelemetry.io/otel/trace"

	"github.com/huuhoait/core-wallet/outbox-relay/internal/domain"
)

// newTestProducer builds a SyncProducer wired with a real SDK tracer (recording
// to sr) and the W3C propagator, but no sarama producer — startProducerSpan never
// touches the broker, so the propagation logic is exercised in isolation.
func newTestProducer(t *testing.T) (*SyncProducer, *tracetest.SpanRecorder) {
	t.Helper()
	sr := tracetest.NewSpanRecorder()
	tp := sdktrace.NewTracerProvider(sdktrace.WithSpanProcessor(sr))
	return &SyncProducer{
		tracer:     tp.Tracer("test"),
		propagator: propagation.TraceContext{},
	}, sr
}

func extractedSpanContext(headers map[string]string) trace.SpanContext {
	ctx := propagation.TraceContext{}.Extract(context.Background(),
		propagation.MapCarrier(headers))
	return trace.SpanContextFromContext(ctx)
}

// TestStartProducerSpan_ContinuesUpstreamTrace is the core guarantee: a valid
// upstream traceparent (what the posting SP now stamps into the outbox row) is
// continued — same trace-id, fresh span-id — so the Kafka consumer can keep the
// same distributed trace.
func TestStartProducerSpan_ContinuesUpstreamTrace(t *testing.T) {
	p, _ := newTestProducer(t)

	const upstreamTrace = "4bf92f3577b34da6a3ce929d0e0e4736"
	const upstreamSpan = "00f067aa0ba902b7"
	msg := domain.KafkaMessage{
		Topic:   "wallet.transactions",
		Headers: map[string]string{"traceparent": "00-" + upstreamTrace + "-" + upstreamSpan + "-01"},
	}

	span := p.startProducerSpan(&msg)
	span.End()

	// The span itself must inherit the upstream trace.
	if got := span.SpanContext().TraceID().String(); got != upstreamTrace {
		t.Fatalf("span trace-id = %s, want %s (upstream)", got, upstreamTrace)
	}

	// The re-injected header must carry the same trace but a NEW (this) span as
	// the parent for downstream.
	out := extractedSpanContext(msg.Headers)
	if !out.IsValid() {
		t.Fatalf("injected traceparent is not a valid span context: %q", msg.Headers["traceparent"])
	}
	if out.TraceID().String() != upstreamTrace {
		t.Errorf("injected trace-id = %s, want %s", out.TraceID(), upstreamTrace)
	}
	if out.SpanID().String() == upstreamSpan {
		t.Errorf("injected span-id should be the producer span, not the upstream %s", upstreamSpan)
	}
}

// TestStartProducerSpan_NilHeaders guards the propagation against a nil headers
// map (the polling relay passes nil when the outbox row had no headers): it must
// not panic and must produce an injectable, valid traceparent.
func TestStartProducerSpan_NilHeaders(t *testing.T) {
	p, _ := newTestProducer(t)
	msg := domain.KafkaMessage{Topic: "wallet.transactions", Headers: nil}

	span := p.startProducerSpan(&msg)
	span.End()

	if msg.Headers == nil {
		t.Fatal("headers should have been allocated")
	}
	if !extractedSpanContext(msg.Headers).IsValid() {
		t.Errorf("expected a valid injected traceparent, got %q", msg.Headers["traceparent"])
	}
}

// TestStartProducerSpan_LegacyBareTraceID covers a legacy/bare trace-id that is
// NOT a parseable W3C traceparent: the span starts a fresh trace but records the
// original value as an attribute so it stays searchable.
func TestStartProducerSpan_LegacyBareTraceID(t *testing.T) {
	p, sr := newTestProducer(t)
	const bare = "4bf92f3577b34da6a3ce929d0e0e4736"
	msg := domain.KafkaMessage{
		Topic:   "wallet.transactions",
		Headers: map[string]string{"traceparent": bare},
	}

	span := p.startProducerSpan(&msg)
	span.End()

	ended := sr.Ended()
	if len(ended) != 1 {
		t.Fatalf("expected 1 recorded span, got %d", len(ended))
	}
	var found bool
	for _, a := range ended[0].Attributes() {
		if string(a.Key) == "wallet.upstream.traceparent" && a.Value.AsString() == bare {
			found = true
		}
	}
	if !found {
		t.Errorf("expected wallet.upstream.traceparent=%q attribute on the span", bare)
	}
}
