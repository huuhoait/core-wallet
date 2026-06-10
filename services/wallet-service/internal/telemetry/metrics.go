package telemetry

import (
	"context"
	"fmt"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	promexp "go.opentelemetry.io/otel/exporters/prometheus"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/resource"
	semconv "go.opentelemetry.io/otel/semconv/v1.26.0"
)

// SetupMetrics wires an OpenTelemetry MeterProvider backed by a Prometheus
// exporter and installs it as the global meter provider, so the HTTP metrics
// middleware (and otelgin's built-in instruments) record into it. The exporter
// registers itself with the Prometheus default registry; the caller exposes it
// by mounting promhttp.Handler() at /metrics.
//
// When enabled is false we install a no-op MeterProvider (OTel's default) so
// metric instruments short-circuit and /metrics is not mounted — symmetric with
// Setup's tracing no-op.
//
// Returns a shutdown function the caller should defer; it flushes/stops the
// provider on graceful exit.
func SetupMetrics(ctx context.Context, enabled bool, serviceName, env string) (func(context.Context) error, error) {
	if !enabled {
		return func(context.Context) error { return nil }, nil
	}

	exp, err := promexp.New()
	if err != nil {
		return nil, fmt.Errorf("prometheus exporter: %w", err)
	}

	res, err := resource.New(ctx,
		resource.WithAttributes(
			semconv.ServiceName(serviceName),
			attribute.String("deployment.environment.name", env),
		))
	if err != nil {
		return nil, fmt.Errorf("otel metric resource: %w", err)
	}

	mp := sdkmetric.NewMeterProvider(
		sdkmetric.WithReader(exp),
		sdkmetric.WithResource(res),
	)
	otel.SetMeterProvider(mp)

	return mp.Shutdown, nil
}
