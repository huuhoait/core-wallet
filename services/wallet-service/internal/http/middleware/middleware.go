// Package middleware contains gin middlewares used by the HTTP server.
package middleware

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"go.opentelemetry.io/otel/trace"

	"github.com/ewallet-pg/wallet-service/internal/domain"
	"github.com/ewallet-pg/wallet-service/internal/http/dto"
)

// Context keys (gin-stored values, exported for handler use)
const (
	CtxKeyAudit     = "wallet.audit_context"
	CtxKeyRequestID = "wallet.request_id"
)

// RequestID generates a request_id if the client didn't supply one,
// echoes it back in the response header, and stashes it in the gin context.
func RequestID() gin.HandlerFunc {
	return func(c *gin.Context) {
		rid := strings.TrimSpace(c.GetHeader("X-Request-Id"))
		if rid == "" {
			rid = uuid.NewString()
		}
		c.Set(CtxKeyRequestID, rid)
		c.Writer.Header().Set("X-Request-Id", rid)
		c.Next()
	}
}

// AuditContext extracts the per-request audit context from headers + JWT
// claims (TODO: real JWT lookup), stashes it on the gin context. Repository
// layer reads it via FromGin() and writes to PG GUCs.
func AuditContext() gin.HandlerFunc {
	return func(c *gin.Context) {
		audit := domain.AuditContext{
			Actor:     resolveActor(c),
			Channel:   resolveChannel(c),
			RequestID: c.GetString(CtxKeyRequestID),
			TraceID:   spanIDFromGin(c),
			IPAddress: c.ClientIP(),
			UserAgent: c.Request.UserAgent(),
		}
		c.Set(CtxKeyAudit, audit)
		c.Next()
	}
}

// FromGin returns the audit context attached by AuditContext middleware.
// Panics in dev if not set so the wiring bug is caught early.
func FromGin(c *gin.Context) domain.AuditContext {
	v, ok := c.Get(CtxKeyAudit)
	if !ok {
		panic("audit middleware not attached")
	}
	return v.(domain.AuditContext)
}

func resolveActor(c *gin.Context) string {
	// Phase 1: trust a header set by the API gateway after JWT validation.
	// Phase 2: parse and verify JWT here.
	if v := strings.TrimSpace(c.GetHeader("X-Caller-Subject")); v != "" {
		return v
	}
	return "anonymous"
}

func resolveChannel(c *gin.Context) domain.Channel {
	switch strings.ToUpper(c.GetHeader("X-Channel")) {
	case "MOBILE":
		return domain.ChannelMobile
	case "OPSUI":
		return domain.ChannelOpsUI
	case "TREASURY":
		return domain.ChannelTreasury
	case "PARTNER":
		return domain.ChannelPartner
	case "API":
		return domain.ChannelAPI
	}
	return domain.ChannelAPI
}

func spanIDFromGin(c *gin.Context) string {
	// otelgin sets the span on the request context. Extract the trace_id
	// (W3C traceparent) so the SP can put it into the outbox HEADERS.
	sc := trace.SpanContextFromContext(c.Request.Context())
	if !sc.IsValid() {
		return ""
	}
	return sc.TraceID().String()
}

// WithTimeout wraps the incoming request's context with a hard deadline.
// Outer ring of the timeout stack (HLD §9):
//
//	PG lock_timeout (1.5s) < PG statement_timeout (2.5s) < this ctx (default 10s)
//
// When the deadline fires, pgx detects ctx.Err() and sends a Cancel message to
// PG so the in-flight query stops promptly. The handler then returns the
// canonical TIMEOUT envelope via Recovery / renderError.
//
// Apply selectively to transactional groups — read-only / healthz don't need it.
func WithTimeout(d time.Duration) gin.HandlerFunc {
	return func(c *gin.Context) {
		if d <= 0 {
			c.Next()
			return
		}
		ctx, cancel := context.WithTimeout(c.Request.Context(), d)
		defer cancel()
		c.Request = c.Request.WithContext(ctx)
		c.Next()

		// If the deadline fired and the handler didn't already write a body,
		// emit a uniform timeout response so the client always sees a code.
		if ctx.Err() == context.DeadlineExceeded && !c.Writer.Written() {
			writeProblem(c, dto.NewProblem(domain.CodeTimeout, http.StatusGatewayTimeout,
				"request deadline exceeded", c.Request.URL.Path, c.GetString(CtxKeyRequestID)))
		}
	}
}

// Recovery converts panics into 500 responses with the canonical envelope.
func Recovery() gin.HandlerFunc {
	return gin.CustomRecovery(func(c *gin.Context, _ any) {
		writeProblem(c, dto.NewProblem(domain.CodeInternal, http.StatusInternalServerError,
			"internal server error", c.Request.URL.Path, c.GetString(CtxKeyRequestID)))
	})
}

// writeProblem renders an RFC 7807 problem+json body. Mirrors the handler's
// writer so timeout / panic responses use the same envelope as the handlers.
func writeProblem(c *gin.Context, p dto.ProblemDetails) {
	body, err := json.Marshal(p)
	if err != nil {
		c.AbortWithStatus(p.Status)
		return
	}
	c.Header("Content-Type", "application/problem+json")
	c.Status(p.Status)
	_, _ = c.Writer.Write(body)
	c.Abort()
}
