package middleware

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"

	"github.com/ewallet-pg/wallet-service/internal/domain"
)

func newRBACRouter(_ *testing.T, setCtx func(*gin.Context), want ...string) *gin.Engine {
	r := gin.New()
	r.Use(RequestID())
	r.Use(func(c *gin.Context) {
		if setCtx != nil {
			setCtx(c)
		}
		c.Next()
	})
	r.GET("/protected", RequireAnyRole(want...), func(c *gin.Context) {
		c.Status(http.StatusOK)
	})
	return r
}

func TestRBAC_HasOneOfRoles_Passes(t *testing.T) {
	r := newRBACRouter(t, func(c *gin.Context) {
		c.Set(CtxKeyJWTRoles, []string{"wallet.ops.read", "wallet.finance.reverse"})
	}, "wallet.finance.reverse")

	w := httptest.NewRecorder()
	r.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/protected", nil))
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", w.Code)
	}
}

func TestRBAC_MissingRole_403(t *testing.T) {
	r := newRBACRouter(t, func(c *gin.Context) {
		c.Set(CtxKeyJWTRoles, []string{"wallet.ops.read"})
	}, "wallet.finance.reverse")

	w := httptest.NewRecorder()
	r.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/protected", nil))
	assertProblem(t, w, http.StatusForbidden, domain.CodeForbidden)
}

func TestRBAC_NoJWTContext_IsPassthrough(t *testing.T) {
	// JWT disabled → CtxKeyJWTRoles never set → middleware skips enforcement.
	r := newRBACRouter(t, nil, "wallet.finance.reverse")

	w := httptest.NewRecorder()
	r.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/protected", nil))
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (JWT disabled = passthrough)", w.Code)
	}
}

func TestRBAC_EmptyRolesClaim_403(t *testing.T) {
	r := newRBACRouter(t, func(c *gin.Context) {
		c.Set(CtxKeyJWTRoles, []string{})
	}, "wallet.finance.reverse")

	w := httptest.NewRecorder()
	r.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/protected", nil))
	assertProblem(t, w, http.StatusForbidden, domain.CodeForbidden)
}
