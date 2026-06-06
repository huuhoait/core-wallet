package middleware

import (
	"net/http"

	"github.com/gin-gonic/gin"

	"github.com/ewallet-pg/wallet-service/internal/domain"
	"github.com/ewallet-pg/wallet-service/internal/http/dto"
)

// Role catalog — kept here so additions are visible alongside the middleware
// that enforces them. Granted via the `roles` claim on the JWT (see JWTConfig).
const (
	RoleFinanceReverse = "wallet.finance.reverse" // any reversal endpoint (transfer, topup, fee-charge, merchant-withdraw)
	RoleOpsRead        = "wallet.ops.read"        // /v1/ops/* — unmasked PII + ops balance views
	RoleTreasury       = "wallet.treasury"        // /v1/treasury/* — S2S callbacks from Treasury Service
)

// RequireAnyRole returns 403 unless the JWT-attached roles include at least one
// of the listed roles. When the JWT middleware is disabled (dev / unit tests),
// CtxKeyJWTRoles is unset and this middleware is a no-op — the route behaves
// as before. Enable JWT in staging/prod to make these checks bind.
func RequireAnyRole(roles ...string) gin.HandlerFunc {
	want := make(map[string]struct{}, len(roles))
	for _, r := range roles {
		want[r] = struct{}{}
	}
	return func(c *gin.Context) {
		v, exists := c.Get(CtxKeyJWTRoles)
		if !exists {
			// JWT validation disabled — skip enforcement.
			c.Next()
			return
		}
		have, _ := v.([]string)
		for _, r := range have {
			if _, ok := want[r]; ok {
				c.Next()
				return
			}
		}
		writeProblem(c, dto.NewProblem(
			domain.CodeForbidden, http.StatusForbidden,
			"missing required role", c.Request.URL.Path,
			c.GetString(CtxKeyRequestID)))
	}
}
