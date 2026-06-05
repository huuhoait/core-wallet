package middleware

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"reflect"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/golang-jwt/jwt/v5"

	"github.com/ewallet-pg/wallet-service/internal/domain"
	"github.com/ewallet-pg/wallet-service/internal/http/dto"
)

func init() { gin.SetMode(gin.TestMode) }

const (
	testHMACSecret = "test-secret-do-not-use-in-prod"
	testIssuer     = "https://gateway.example/test"
	testAudience   = "wallet-service"
)

func signHS256(t *testing.T, claims jwt.MapClaims) string {
	t.Helper()
	tok := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	s, err := tok.SignedString([]byte(testHMACSecret))
	if err != nil {
		t.Fatalf("sign token: %v", err)
	}
	return s
}

func newJWTRouter(t *testing.T, cfg JWTConfig) *gin.Engine {
	t.Helper()
	mw, err := JWT(cfg)
	if err != nil {
		t.Fatalf("build jwt middleware: %v", err)
	}
	r := gin.New()
	r.Use(RequestID(), mw)
	r.GET("/protected", func(c *gin.Context) {
		sub, _ := c.Get(CtxKeyJWTSubject)
		roles, _ := c.Get(CtxKeyJWTRoles)
		c.JSON(http.StatusOK, gin.H{"sub": sub, "roles": roles})
	})
	return r
}

func validConfig() JWTConfig {
	return JWTConfig{
		Enabled:      true,
		Issuer:       testIssuer,
		Audience:     testAudience,
		Algorithm:    "HS256",
		HMACSecret:   testHMACSecret,
		RolesClaim:   "roles",
		ChannelClaim: "channel",
		ClockSkew:    30 * time.Second,
	}
}

func validClaims() jwt.MapClaims {
	now := time.Now()
	return jwt.MapClaims{
		"sub":   "ops-user-42",
		"iss":   testIssuer,
		"aud":   testAudience,
		"exp":   now.Add(5 * time.Minute).Unix(),
		"iat":   now.Unix(),
		"roles": []string{"wallet.finance.reverse"},
	}
}

func do(r *gin.Engine, hdr string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodGet, "/protected", nil)
	if hdr != "" {
		req.Header.Set("Authorization", hdr)
	}
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	return w
}

func TestJWT_Disabled_IsNoOp(t *testing.T) {
	r := newJWTRouter(t, JWTConfig{Enabled: false})
	w := do(r, "") // no header
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (JWT disabled = passthrough)", w.Code)
	}
}

func TestJWT_Valid_PopulatesSubAndRoles(t *testing.T) {
	r := newJWTRouter(t, validConfig())
	w := do(r, "Bearer "+signHS256(t, validClaims()))
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200, body=%s", w.Code, w.Body.String())
	}
	var body struct {
		Sub   string   `json:"sub"`
		Roles []string `json:"roles"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatalf("body decode: %v", err)
	}
	if body.Sub != "ops-user-42" {
		t.Errorf("sub = %q, want ops-user-42", body.Sub)
	}
	wantRoles := []string{"wallet.finance.reverse"}
	sort.Strings(body.Roles)
	if !reflect.DeepEqual(body.Roles, wantRoles) {
		t.Errorf("roles = %v, want %v", body.Roles, wantRoles)
	}
}

func TestJWT_MissingHeader_401(t *testing.T) {
	r := newJWTRouter(t, validConfig())
	w := do(r, "")
	assertProblem(t, w, http.StatusUnauthorized, domain.CodeUnauthorized)
}

func TestJWT_MalformedBearer_401(t *testing.T) {
	r := newJWTRouter(t, validConfig())
	w := do(r, "Token abc")
	assertProblem(t, w, http.StatusUnauthorized, domain.CodeUnauthorized)
}

func TestJWT_Expired_401(t *testing.T) {
	c := validClaims()
	c["exp"] = time.Now().Add(-1 * time.Hour).Unix()
	c["iat"] = time.Now().Add(-2 * time.Hour).Unix()
	r := newJWTRouter(t, validConfig())
	w := do(r, "Bearer "+signHS256(t, c))
	assertProblem(t, w, http.StatusUnauthorized, domain.CodeUnauthorized)
}

func TestJWT_WrongIssuer_401(t *testing.T) {
	c := validClaims()
	c["iss"] = "https://attacker.example"
	r := newJWTRouter(t, validConfig())
	w := do(r, "Bearer "+signHS256(t, c))
	assertProblem(t, w, http.StatusUnauthorized, domain.CodeUnauthorized)
}

func TestJWT_WrongAudience_401(t *testing.T) {
	c := validClaims()
	c["aud"] = "some-other-service"
	r := newJWTRouter(t, validConfig())
	w := do(r, "Bearer "+signHS256(t, c))
	assertProblem(t, w, http.StatusUnauthorized, domain.CodeUnauthorized)
}

func TestJWT_BadSignature_401(t *testing.T) {
	tok := jwt.NewWithClaims(jwt.SigningMethodHS256, validClaims())
	bad, err := tok.SignedString([]byte("wrong-secret"))
	if err != nil {
		t.Fatalf("sign: %v", err)
	}
	r := newJWTRouter(t, validConfig())
	w := do(r, "Bearer "+bad)
	assertProblem(t, w, http.StatusUnauthorized, domain.CodeUnauthorized)
}

func TestJWT_MissingSub_401(t *testing.T) {
	c := validClaims()
	delete(c, "sub")
	r := newJWTRouter(t, validConfig())
	w := do(r, "Bearer "+signHS256(t, c))
	assertProblem(t, w, http.StatusUnauthorized, domain.CodeUnauthorized)
}

func TestJWT_BuildFails_HS256NoSecret(t *testing.T) {
	cfg := validConfig()
	cfg.HMACSecret = ""
	if _, err := JWT(cfg); err == nil {
		t.Fatal("expected JWT() to fail when HS256 secret is missing")
	}
}

func TestJWT_BuildFails_UnknownAlgorithm(t *testing.T) {
	cfg := validConfig()
	cfg.Algorithm = "ES512"
	if _, err := JWT(cfg); err == nil {
		t.Fatal("expected JWT() to fail for unknown algorithm")
	}
}

func TestExtractRoles_StringFallback(t *testing.T) {
	got := extractRoles(jwt.MapClaims{"roles": "a b  c"}, "roles")
	want := []string{"a", "b", "c"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("extractRoles(string) = %v, want %v", got, want)
	}
}

func TestExtractRoles_Missing(t *testing.T) {
	if got := extractRoles(jwt.MapClaims{}, "roles"); got != nil {
		t.Errorf("extractRoles(missing) = %v, want nil", got)
	}
}

func TestJWT_ChannelClaim_PopulatesContext(t *testing.T) {
	r := gin.New()
	mw, err := JWT(validConfig())
	if err != nil {
		t.Fatalf("build jwt middleware: %v", err)
	}
	r.Use(RequestID(), mw)
	r.GET("/probe", func(c *gin.Context) {
		ch, _ := c.Get(CtxKeyJWTChannel)
		c.JSON(http.StatusOK, gin.H{"channel": ch})
	})

	claims := validClaims()
	claims["channel"] = "TREASURY"

	w := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/probe", nil)
	req.Header.Set("Authorization", "Bearer "+signHS256(t, claims))
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200, body=%s", w.Code, w.Body.String())
	}
	var body struct {
		Channel string `json:"channel"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatalf("body decode: %v", err)
	}
	if body.Channel != "TREASURY" {
		t.Errorf("channel = %q, want TREASURY", body.Channel)
	}
}

func TestJWT_NoChannelClaim_NoContext(t *testing.T) {
	r := gin.New()
	mw, err := JWT(validConfig())
	if err != nil {
		t.Fatalf("build jwt middleware: %v", err)
	}
	r.Use(RequestID(), mw)
	r.GET("/probe", func(c *gin.Context) {
		_, ok := c.Get(CtxKeyJWTChannel)
		c.JSON(http.StatusOK, gin.H{"set": ok})
	})

	w := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/probe", nil)
	req.Header.Set("Authorization", "Bearer "+signHS256(t, validClaims()))
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200, body=%s", w.Code, w.Body.String())
	}
	if !strings.Contains(w.Body.String(), `"set":false`) {
		t.Errorf("expected channel ctx to be unset; body=%s", w.Body.String())
	}
}

func assertProblem(t *testing.T, w *httptest.ResponseRecorder, wantStatus int, wantCode string) {
	t.Helper()
	if w.Code != wantStatus {
		t.Fatalf("status = %d, want %d, body=%s", w.Code, wantStatus, w.Body.String())
	}
	if ct := w.Header().Get("Content-Type"); ct != "application/problem+json" {
		t.Errorf("Content-Type = %q, want application/problem+json", ct)
	}
	var p dto.ProblemDetails
	if err := json.Unmarshal(w.Body.Bytes(), &p); err != nil {
		t.Fatalf("body decode: %v\nbody=%s", err, w.Body.String())
	}
	if p.ErrorCode != wantCode {
		t.Errorf("errorCode = %q, want %q", p.ErrorCode, wantCode)
	}
}
