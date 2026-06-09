// Package otelx holds OpenTelemetry span helpers shared across the wallet
// services — the HTTP API (wallet-service) and the outbox relay (outbox-relay).
//
// It deliberately depends only on the OTel API packages (attribute, codes,
// trace) — no gin, no sarama, no SDK wiring — so both modules can import it
// without dragging in each other's framework dependencies. Provider/exporter
// setup stays per-service (each owns its own telemetry.Setup); only the
// repetitive per-span boilerplate lives here.
package otelx

import (
	"context"

	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/trace"
)

// StartSpan opens a span on ctx via the given tracer, applying attrs up front.
// The returned context carries the span, so passing it downstream makes the
// span the parent of the work that follows. Callers MUST defer span.End().
//
// For spans that need a non-default kind or an extracted parent (e.g. a Kafka
// PRODUCER span built from an upstream traceparent), call tracer.Start directly
// with the appropriate options — this helper covers the common attribute-only
// case.
func StartSpan(ctx context.Context, tracer trace.Tracer, name string, attrs ...attribute.KeyValue) (context.Context, trace.Span) {
	return tracer.Start(ctx, name, trace.WithAttributes(attrs...))
}

// FailSpan records err on the span and marks its status Error. Use it on the
// failure path so the exported trace reflects the same outcome surfaced to the
// caller. No-op safe: passing a nil error still records nothing meaningful, so
// only call it when err != nil.
func FailSpan(span trace.Span, err error) {
	span.RecordError(err)
	span.SetStatus(codes.Error, err.Error())
}
