// Package telemetry wires the OpenTelemetry tracer provider and the W3C
// propagator for the outbox relay.
//
// The relay is the PRODUCER side of the async hop in the wallet's distributed
// trace: a posting stored procedure stamps the originating request's W3C
// traceparent into WLT_OUTBOX.HEADERS->>'traceparent'; the Kafka producer
// (internal/kafka) EXTRACTS that as the parent, opens a producer span, and
// re-INJECTS the span into the outgoing Kafka headers so the downstream
// consumer continues the same trace.
//
// When OTEL_ENABLED=false a no-op tracer is installed. The propagator is still
// set, so the producer's extract→start→inject collapses to a zero-overhead
// pass-through of the upstream traceparent (the header is preserved untouched).
package telemetry

import (
	"context"
	"fmt"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.26.0"
	nooptrace "go.opentelemetry.io/otel/trace/noop"

	"github.com/huuhoait/core-wallet/outbox-relay/internal/config"
)

// Setup installs the global propagator and tracer provider. It returns a
// shutdown function the caller should defer (flushes the batch exporter); the
// shutdown is a no-op when tracing is disabled.
func Setup(ctx context.Context, cfg config.OtelConfig, env string) (func(context.Context) error, error) {
	// Always install the W3C propagator so traceparent flows through the outbox
	// headers → Kafka regardless of whether spans are exported.
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
		propagation.TraceContext{}, propagation.Baggage{}))

	if !cfg.Enabled {
		// No-op tracer: the producer's extract→start→inject becomes a verbatim
		// pass-through of the upstream traceparent (no span overhead).
		otel.SetTracerProvider(nooptrace.NewTracerProvider())
		return func(context.Context) error { return nil }, nil
	}

	opts := []otlptracegrpc.Option{otlptracegrpc.WithEndpoint(cfg.Endpoint)}
	if cfg.Insecure {
		opts = append(opts, otlptracegrpc.WithInsecure())
	}
	exp, err := otlptrace.New(ctx, otlptracegrpc.NewClient(opts...))
	if err != nil {
		return nil, fmt.Errorf("otlp exporter: %w", err)
	}

	res, err := resource.New(ctx, resource.WithAttributes(
		semconv.ServiceName(cfg.ServiceName),
		attribute.String("deployment.environment.name", env),
	))
	if err != nil {
		return nil, fmt.Errorf("otel resource: %w", err)
	}

	tp := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(exp),
		sdktrace.WithResource(res),
		sdktrace.WithSampler(sdktrace.TraceIDRatioBased(cfg.SamplingRatio)),
	)
	otel.SetTracerProvider(tp)
	return tp.Shutdown, nil
}
