package middleware_test

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/prometheus/client_golang/prometheus/promhttp"

	"github.com/ewallet-pg/wallet-service/internal/http/middleware"
	"github.com/ewallet-pg/wallet-service/internal/telemetry"
)

// TestMetrics_ExposesNamedSeries proves the full path: the Metrics middleware
// records into the OTel meter provider that SetupMetrics installs, and the
// Prometheus exporter renders them at /metrics under the exact scraped names
// (the exporter appends _total to the counter and _seconds to the s-unit
// histogram). It also asserts the route label is the matched template, not the
// raw path with its param value.
func TestMetrics_ExposesNamedSeries(t *testing.T) {
	shutdown, err := telemetry.SetupMetrics(context.Background(), true, "wallet-service-test", "test")
	if err != nil {
		t.Fatalf("SetupMetrics: %v", err)
	}
	t.Cleanup(func() { _ = shutdown(context.Background()) })

	gin.SetMode(gin.TestMode)
	r := gin.New()
	r.Use(middleware.Metrics())
	r.GET("/v1/accounts/:acct_no", func(c *gin.Context) { c.Status(http.StatusOK) })
	r.GET("/metrics", gin.WrapH(promhttp.Handler()))

	// Drive one matched business request so the instruments have a sample.
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/v1/accounts/9701234567", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("business request status = %d, want 200", rec.Code)
	}

	// Record an error so wallet_errors_total has a sample (renderError calls this).
	middleware.RecordError(context.Background(), "INSUFFICIENT_FUNDS")

	scrape := httptest.NewRecorder()
	r.ServeHTTP(scrape, httptest.NewRequest(http.MethodGet, "/metrics", nil))
	if scrape.Code != http.StatusOK {
		t.Fatalf("/metrics status = %d, want 200", scrape.Code)
	}
	body := scrape.Body.String()

	for _, want := range []string{
		"wallet_requests_total",
		"wallet_request_duration_seconds",
		"wallet_errors_total",
		`route="/v1/accounts/:acct_no"`, // matched template, not the raw acct_no
		`method="GET"`,
		`status="200"`,
		`code="INSUFFICIENT_FUNDS"`,
	} {
		if !strings.Contains(body, want) {
			t.Errorf("/metrics output missing %q\n--- body ---\n%s", want, body)
		}
	}

	// The raw param value must never leak into a label (cardinality guard).
	if strings.Contains(body, "9701234567") {
		t.Errorf("/metrics leaked raw acct_no into a label (high cardinality)")
	}
}
