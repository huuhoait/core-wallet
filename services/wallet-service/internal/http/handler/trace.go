// Tracing adapters for the handler package. The reusable span logic lives in
// the shared github.com/ewallet-pg/otelx module (used by both this API service
// and the outbox relay); these thin wrappers bind it to gin's request context
// so handlers read as bind → trace → call → render.
package handler

import (
	"context"

	"github.com/gin-gonic/gin"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/trace"

	"github.com/ewallet-pg/shared/otelx"
)

// startSpan opens a handler span on the incoming request context (via the
// shared helper), applying attrs up front. The returned context carries the
// span, so passing it into the usecase makes it the parent of the repo SP →
// outbox trace (and keeps it nested under the otelgin server span). Callers
// MUST defer span.End().
func startSpan(c *gin.Context, name string, attrs ...attribute.KeyValue) (context.Context, trace.Span) {
	return otelx.StartSpan(c.Request.Context(), tracer, name, attrs...)
}

// failSpan records err on the span and marks it Error. Call on the failure path
// right before renderError so the trace matches what the client sees.
func failSpan(span trace.Span, err error) { otelx.FailSpan(span, err) }
