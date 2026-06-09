// Package kafka holds the broker adapters: a synchronous producer that satisfies
// usecase.EventPublisher (polling mode) and a Debezium CDC consumer that drives
// usecase.CDCStatusUpdater (CDC mode). Sarama is confined to this package.
package kafka

import (
	"context"
	"fmt"
	"log/slog"

	"github.com/IBM/sarama"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/trace"

	"github.com/ewallet-pg/shared/kafkax"
	"github.com/ewallet-pg/shared/otelx"
	"github.com/huuhoait/core-wallet/outbox-relay/internal/domain"
	"github.com/huuhoait/core-wallet/outbox-relay/internal/usecase"
)

// SyncProducer publishes outbox events via a synchronous Kafka producer. The
// relay needs the per-message broker ack (and its partition/offset) BEFORE it
// marks the source row SENT, so the outbox guarantee is at-least-once. It
// satisfies usecase.EventPublisher.
type SyncProducer struct {
	sync       sarama.SyncProducer
	tracer     trace.Tracer
	propagator propagation.TextMapPropagator
	logger     *slog.Logger
}

var _ usecase.EventPublisher = (*SyncProducer)(nil)

// NewSyncProducer builds a SyncProducer against brokers with idempotent,
// all-replicas-ack delivery. maxRetries bounds the per-send retry budget.
func NewSyncProducer(brokers []string, maxRetries int, logger *slog.Logger) (*SyncProducer, error) {
	sp, err := kafkax.NewSyncProducer(brokers, maxRetries)
	if err != nil {
		return nil, err
	}
	logger.Info("Kafka producer ready", slog.Any("brokers", brokers))
	return &SyncProducer{
		sync:       sp,
		tracer:     otel.Tracer("outbox-relay/kafka"),
		propagator: otel.GetTextMapPropagator(),
		logger:     logger,
	}, nil
}

// Publish sends one message synchronously and returns the partition+offset it
// landed on (so the caller can record them) plus any error.
//
// Tracing: the upstream W3C traceparent the posting SP stamped into the outbox
// row travels in msg.Headers. We EXTRACT it as the parent, open a PRODUCER span,
// then re-INJECT the live span back into the headers so this producer span
// becomes the parent the downstream Kafka consumer continues from. With OTel
// disabled the tracer is a no-op and this collapses to a verbatim pass-through
// of the upstream traceparent.
func (p *SyncProducer) Publish(msg domain.KafkaMessage) (int32, int64, error) {
	// startProducerSpan mutates msg.Headers (ensures non-nil + injects the live
	// traceparent), so the loop below ships the updated headers.
	span := p.startProducerSpan(&msg)
	defer span.End()

	headers := make([]sarama.RecordHeader, 0, len(msg.Headers))
	for k, v := range msg.Headers {
		headers = append(headers, sarama.RecordHeader{Key: []byte(k), Value: []byte(v)})
	}
	partition, offset, err := p.sync.SendMessage(&sarama.ProducerMessage{
		Topic:   msg.Topic,
		Key:     sarama.StringEncoder(msg.Key),
		Value:   sarama.ByteEncoder(msg.Value),
		Headers: headers,
	})
	if err != nil {
		otelx.FailSpan(span, err)
		return 0, 0, fmt.Errorf("kafka: send to %s: %w", msg.Topic, err)
	}
	span.SetAttributes(
		attribute.Int("messaging.kafka.destination.partition", int(partition)),
		attribute.Int64("messaging.kafka.message.offset", offset),
	)
	return partition, offset, nil
}

// startProducerSpan opens the PRODUCER span for one outbox message and wires the
// trace context through the message headers. It EXTRACTS the upstream traceparent
// (stamped by the posting SP) as the parent, starts the span, then re-INJECTS the
// live span back into msg.Headers so the downstream consumer continues the trace.
// It ensures msg.Headers is non-nil. The returned span MUST be ended by the
// caller. Split out from Publish so the propagation logic is unit-testable
// without a live broker.
func (p *SyncProducer) startProducerSpan(msg *domain.KafkaMessage) trace.Span {
	if msg.Headers == nil {
		msg.Headers = make(map[string]string)
	}
	carrier := propagation.MapCarrier(msg.Headers)

	parentCtx := p.propagator.Extract(context.Background(), carrier)
	linked := trace.SpanContextFromContext(parentCtx).IsValid()

	ctx, span := p.tracer.Start(parentCtx, msg.Topic+" publish",
		trace.WithSpanKind(trace.SpanKindProducer),
		trace.WithAttributes(
			attribute.String("messaging.system", "kafka"),
			attribute.String("messaging.destination.name", msg.Topic),
			attribute.String("messaging.operation.name", "publish"),
			attribute.String("messaging.kafka.message.key", msg.Key),
		),
	)

	// Preserve correlation when the upstream value is present but not a parseable
	// W3C traceparent (e.g. a legacy bare trace-id) — the span starts a new trace,
	// so surface the original so it can still be searched for.
	if !linked {
		if raw := msg.Headers["traceparent"]; raw != "" {
			span.SetAttributes(attribute.String("wallet.upstream.traceparent", raw))
		}
	}

	// Re-inject so THIS producer span is what the consumer extracts as parent.
	p.propagator.Inject(ctx, carrier)
	return span
}

// Close flushes and closes the underlying producer.
func (p *SyncProducer) Close() error { return p.sync.Close() }
