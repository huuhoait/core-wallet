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
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/propagation"
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

// FlowID lets a caller correlate a request to a distributed trace by sending a
// simple `FlowId` — a 32-hex trace-id — instead of crafting a full W3C
// traceparent. The value is read from the `FlowId` header or, as a fallback
// (handy from a browser/URL), a `?flowId=` query parameter. When present, the
// FlowId becomes the OTel trace-id: it's expanded to the minimal valid
// traceparent `00-<flow-id>-0000000000000001-01` (placeholder span-id, sampled)
// and written to the request's traceparent header so otelgin's propagator picks
// it up.
//
// A genuine upstream W3C `traceparent` ALWAYS takes precedence and is left
// untouched — real service-to-service propagation (and the outbox → Kafka trace)
// is unaffected; FlowId is only the convenience entry point for manual callers.
// A FlowId that isn't a valid 32-hex id is ignored. MUST be registered BEFORE
// otelgin.Middleware.
func FlowID() gin.HandlerFunc {
	return func(c *gin.Context) {
		// A real propagated trace wins — never override an upstream traceparent.
		if strings.TrimSpace(c.GetHeader("traceparent")) != "" {
			c.Next()
			return
		}
		flow := strings.TrimSpace(c.GetHeader("FlowId"))
		if flow == "" {
			flow = strings.TrimSpace(c.Query("flowId"))
		}
		if isBareTraceID(flow) {
			c.Request.Header.Set("traceparent", "00-"+strings.ToLower(flow)+"-0000000000000001-01")
		}
		c.Next()
	}
}

// isBareTraceID reports whether s is a 32-char hex trace-id on its own (no
// dashes / other traceparent fields) and not the all-zero id (which W3C deems
// invalid).
func isBareTraceID(s string) bool {
	if len(s) != 32 {
		return false
	}
	allZero := true
	for i := 0; i < len(s); i++ {
		ch := s[i]
		switch {
		case ch >= '0' && ch <= '9', ch >= 'a' && ch <= 'f', ch >= 'A' && ch <= 'F':
		default:
			return false
		}
		if ch != '0' {
			allZero = false
		}
	}
	return !allZero
}

// AuditContext extracts the per-request audit context from headers + JWT
// claims (TODO: real JWT lookup), stashes it on the gin context. Repository
// layer reads it via FromGin() and writes to PG GUCs.
func AuditContext() gin.HandlerFunc {
	return func(c *gin.Context) {
		audit := domain.AuditContext{
			Actor:       resolveActor(c),
			Channel:     resolveChannel(c),
			RequestID:   c.GetString(CtxKeyRequestID),
			TraceID:     spanIDFromGin(c),
			TraceParent: traceparentFromGin(c),
			IPAddress:   c.ClientIP(),
			UserAgent:   c.Request.UserAgent(),
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
	// Prefer the JWT subject when this service validated the token itself
	// (US-9.10). Fall back to a gateway-set header for the JWT-disabled path
	// (dev / unit tests / staged rollout).
	if v, ok := c.Get(CtxKeyJWTSubject); ok {
		if s, _ := v.(string); s != "" {
			return s
		}
	}
	if v := strings.TrimSpace(c.GetHeader("X-Caller-Subject")); v != "" {
		return v
	}
	return "anonymous"
}

func resolveChannel(c *gin.Context) domain.Channel {
	// Prefer the channel claim from the JWT (US-9.10). The gateway / IdP
	// stamps it onto the token so the caller can't override it from a header.
	// Header is used only when JWT is disabled or the claim is absent.
	if v, ok := c.Get(CtxKeyJWTChannel); ok {
		if s, _ := v.(string); s != "" {
			if ch := parseChannel(s); ch != "" {
				return ch
			}
		}
	}
	if ch := parseChannel(c.GetHeader("X-Channel")); ch != "" {
		return ch
	}
	return domain.ChannelAPI
}

func parseChannel(s string) domain.Channel {
	switch strings.ToUpper(strings.TrimSpace(s)) {
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
	return ""
}

func spanIDFromGin(c *gin.Context) string {
	// otelgin sets the span on the request context. Extract the bare trace-id
	// (32 hex) for the response envelope / logs / audit.request_id.
	sc := trace.SpanContextFromContext(c.Request.Context())
	if !sc.IsValid() {
		return ""
	}
	return sc.TraceID().String()
}

// traceparentFromGin serialises the active span into a full W3C `traceparent`
// (00-<trace-id>-<span-id>-<flags>) using the globally-installed propagator.
// This — not the bare trace-id — is what gets stamped into the outbox HEADERS
// so the outbox-relay (and the Kafka consumer after it) can EXTRACT a valid
// parent and continue the same distributed trace. Returns "" when there is no
// valid span (OTel disabled / unsampled), in which case the outbox header is
// simply omitted.
func traceparentFromGin(c *gin.Context) string {
	carrier := propagation.MapCarrier{}
	otel.GetTextMapPropagator().Inject(c.Request.Context(), carrier)
	return carrier.Get("traceparent")
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
