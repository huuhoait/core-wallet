package middleware

import (
	"context"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/metric"
)

// HTTP server instruments, recorded on the global meter provider that
// telemetry.SetupMetrics installs. Created once (initMetrics) the first time
// either Metrics() is wired or RecordError() fires — by then main() has already
// run SetupMetrics, so the global provider is the real Prometheus-backed one
// (or the no-op default when METRICS_ENABLED=false, in which case these become
// no-op instruments).
//
// The OTel→Prometheus exporter renders these as the scraped names the deployed
// Prometheus alert rules already key on (deploy/k8s/.../prometheus.yaml):
//   - wallet_requests          → wallet_requests_total          (monotonic ⇒ _total)
//   - wallet_request_duration  → wallet_request_duration_seconds (unit "s" ⇒ _seconds)
//   - wallet_errors            → wallet_errors_total            (monotonic ⇒ _total)
var (
	metricsOnce sync.Once
	reqCount    metric.Int64Counter
	reqDuration metric.Float64Histogram
	errCount    metric.Int64Counter
)

func initMetrics() {
	meter := otel.GetMeterProvider().Meter("wallet-service/http")
	reqCount, _ = meter.Int64Counter(
		"wallet_requests",
		metric.WithDescription("Total HTTP requests handled, by method, route and status."),
	)
	reqDuration, _ = meter.Float64Histogram(
		"wallet_request_duration",
		metric.WithUnit("s"),
		metric.WithDescription("HTTP request latency in seconds, by method, route and status."),
	)
	errCount, _ = meter.Int64Counter(
		"wallet_errors",
		metric.WithDescription("Total errors rendered, by canonical domain error code."),
	)
}

// Metrics records per-request HTTP server metrics: wallet_requests_total and
// wallet_request_duration_seconds, labelled by method/route/status.
//
// The route label uses gin's FullPath() (the matched template, e.g.
// /v1/accounts/:acct_no) — never the raw URL — so high-cardinality path params
// don't explode the metric series. Unmatched paths (404) report route="<unmatched>".
func Metrics() gin.HandlerFunc {
	metricsOnce.Do(initMetrics)
	return func(c *gin.Context) {
		start := time.Now()
		c.Next()

		route := c.FullPath()
		if route == "" {
			route = "<unmatched>"
		}
		attrs := metric.WithAttributes(
			attribute.String("method", c.Request.Method),
			attribute.String("route", route),
			attribute.Int("status", c.Writer.Status()),
		)
		reqCount.Add(c.Request.Context(), 1, attrs)
		reqDuration.Record(c.Request.Context(), time.Since(start).Seconds(), attrs)
	}
}

// RecordError increments wallet_errors_total for the canonical domain error
// code (e.g. INSUFFICIENT_FUNDS, BATCH_UNBALANCED, TIMEOUT) as the central error
// renderer maps a failure to its envelope. The code label is the stable
// canonical name — never the client-facing SQLSTATE/E#### — so alerts can key on
// it. No-op safe before SetupMetrics or when metrics are disabled.
func RecordError(ctx context.Context, code string) {
	metricsOnce.Do(initMetrics)
	if errCount == nil {
		return
	}
	errCount.Add(ctx, 1, metric.WithAttributes(attribute.String("code", code)))
}
