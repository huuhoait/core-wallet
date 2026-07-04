package middleware

import (
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
)

func init() { gin.SetMode(gin.TestMode) }

// makeJWT builds an UNSIGNED-looking JWT (header.payload.signature). The service
// never verifies the signature (Kong does), so the signature segment is a dummy.
// Payload is base64url(json(claims)) with NO padding — exactly like a real JWT.
func makeJWT(claims map[string]any) string {
	hdr := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"RS256","typ":"JWT"}`))
	pb, _ := json.Marshal(claims)
	payload := base64.RawURLEncoding.EncodeToString(pb)
	return hdr + "." + payload + ".sig-not-verified"
}

func defaultGWConfig(enforce bool) GatewayConfig {
	return GatewayConfig{
		Enforce:            enforce,
		JWTHeader:          "Authorization",
		ActorClaim:         "preferred_username",
		ActorClaimFallback: "sub",
	}
}

// captureActor runs GatewayIdentity over a request and returns the actor it
// stashed on the context (and whether one was set).
func captureActor(cfg GatewayConfig, req *http.Request) (string, bool) {
	var got string
	var ok bool
	r := gin.New()
	r.Use(RequestID(), GatewayIdentity(cfg))
	r.Any("/x", func(c *gin.Context) {
		got, ok = GatewayActor(c)
		c.Status(http.StatusOK)
	})
	r.ServeHTTP(httptest.NewRecorder(), req)
	return got, ok
}

func TestGatewayIdentity_ExtractsPreferredUsername(t *testing.T) {
	tok := makeJWT(map[string]any{"preferred_username": "alice@corp", "sub": "uuid-123"})
	req := httptest.NewRequest(http.MethodPost, "/x", nil)
	req.Header.Set("Authorization", "Bearer "+tok)

	got, ok := captureActor(defaultGWConfig(true), req)
	if !ok || got != "alice@corp" {
		t.Fatalf("actor = %q (set=%v), want %q", got, ok, "alice@corp")
	}
}

func TestGatewayIdentity_FallsBackToSub(t *testing.T) {
	// No preferred_username → fall back to sub.
	tok := makeJWT(map[string]any{"sub": "uuid-123"})
	req := httptest.NewRequest(http.MethodPost, "/x", nil)
	req.Header.Set("Authorization", "Bearer "+tok)

	got, ok := captureActor(defaultGWConfig(true), req)
	if !ok || got != "uuid-123" {
		t.Fatalf("actor = %q (set=%v), want %q", got, ok, "uuid-123")
	}
}

func TestGatewayIdentity_BareTokenNoBearerPrefix(t *testing.T) {
	tok := makeJWT(map[string]any{"preferred_username": "bob"})
	req := httptest.NewRequest(http.MethodPost, "/x", nil)
	req.Header.Set("Authorization", tok) // no "Bearer " prefix

	got, ok := captureActor(defaultGWConfig(true), req)
	if !ok || got != "bob" {
		t.Fatalf("actor = %q (set=%v), want %q", got, ok, "bob")
	}
}

func TestGatewayIdentity_NoToken_EmptyActor(t *testing.T) {
	req := httptest.NewRequest(http.MethodPost, "/x", nil)
	if got, ok := captureActor(defaultGWConfig(true), req); ok || got != "" {
		t.Fatalf("actor = %q (set=%v), want empty/unset", got, ok)
	}
}

func TestGatewayIdentity_UnparseableToken_EmptyActor(t *testing.T) {
	req := httptest.NewRequest(http.MethodPost, "/x", nil)
	req.Header.Set("Authorization", "Bearer not-a-jwt")
	if got, ok := captureActor(defaultGWConfig(true), req); ok || got != "" {
		t.Fatalf("actor = %q (set=%v), want empty/unset", got, ok)
	}
}

// newEnforceRouter mirrors the real chain: GatewayIdentity extracts, then
// EnforceGatewayIdentity gates. A POST + GET route exercise both method classes.
func newEnforceRouter(enforce bool) *gin.Engine {
	r := gin.New()
	r.Use(RequestID(), GatewayIdentity(defaultGWConfig(enforce)), EnforceGatewayIdentity(enforce))
	r.POST("/write", func(c *gin.Context) { c.Status(http.StatusOK) })
	r.GET("/read", func(c *gin.Context) { c.Status(http.StatusOK) })
	return r
}

func TestEnforce_MutatingNoToken_401(t *testing.T) {
	w := httptest.NewRecorder()
	newEnforceRouter(true).ServeHTTP(w, httptest.NewRequest(http.MethodPost, "/write", nil))
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401", w.Code)
	}
	if ct := w.Header().Get("Content-Type"); !strings.Contains(ct, "application/problem+json") {
		t.Fatalf("content-type = %q, want application/problem+json", ct)
	}
}

func TestEnforce_MutatingWithToken_OK(t *testing.T) {
	tok := makeJWT(map[string]any{"preferred_username": "alice"})
	req := httptest.NewRequest(http.MethodPost, "/write", nil)
	req.Header.Set("Authorization", "Bearer "+tok)

	w := httptest.NewRecorder()
	newEnforceRouter(true).ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", w.Code)
	}
}

func TestEnforce_ReadNotBlocked(t *testing.T) {
	// GET with enforcement on and NO token must still pass (balance/health reads).
	w := httptest.NewRecorder()
	newEnforceRouter(true).ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/read", nil))
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (reads are not gated)", w.Code)
	}
}

func TestEnforce_Disabled_IsNoop(t *testing.T) {
	// enforce=false (dev): a mutating request with no token passes.
	w := httptest.NewRecorder()
	newEnforceRouter(false).ServeHTTP(w, httptest.NewRequest(http.MethodPost, "/write", nil))
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (enforcement disabled)", w.Code)
	}
}

// TestActor_GatewayOverridesClientHeader is the security-critical case: a client
// that supplies X-Caller-Subject cannot override the gateway-verified actor. The
// audit actor MUST be the gateway JWT claim, not the spoofed header.
func TestActor_GatewayOverridesClientHeader(t *testing.T) {
	tok := makeJWT(map[string]any{"preferred_username": "gw-user"})
	req := httptest.NewRequest(http.MethodPost, "/write", nil)
	req.Header.Set("Authorization", "Bearer "+tok)
	req.Header.Set("X-Caller-Subject", "attacker") // spoof attempt

	var actor string
	r := gin.New()
	// Real order: GatewayIdentity BEFORE AuditContext so resolveActor sees it.
	r.Use(RequestID(), GatewayIdentity(defaultGWConfig(true)), AuditContext())
	r.POST("/write", func(c *gin.Context) {
		actor = FromGin(c).Actor
		c.Status(http.StatusOK)
	})
	r.ServeHTTP(httptest.NewRecorder(), req)

	if actor != "gw-user" {
		t.Fatalf("audit actor = %q, want %q (client X-Caller-Subject must not override)", actor, "gw-user")
	}
}

// TestActor_HeaderFallbackWhenNoGateway proves the dev fallback still works when
// neither a gateway token nor a self-validated JWT produced an actor.
func TestActor_HeaderFallbackWhenNoGateway(t *testing.T) {
	req := httptest.NewRequest(http.MethodPost, "/write", nil)
	req.Header.Set("X-Caller-Subject", "dev-user")

	var actor string
	r := gin.New()
	r.Use(RequestID(), GatewayIdentity(defaultGWConfig(false)), AuditContext())
	r.POST("/write", func(c *gin.Context) {
		actor = FromGin(c).Actor
		c.Status(http.StatusOK)
	})
	r.ServeHTTP(httptest.NewRecorder(), req)

	if actor != "dev-user" {
		t.Fatalf("audit actor = %q, want %q (dev header fallback)", actor, "dev-user")
	}
}
