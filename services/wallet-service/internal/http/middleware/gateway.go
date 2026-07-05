package middleware

import (
	"encoding/base64"
	"encoding/json"
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"

	"github.com/ewallet-pg/wallet-service/internal/domain"
	"github.com/ewallet-pg/wallet-service/internal/http/dto"
)

// CtxKeyGatewayActor is the gin-context key under which GatewayIdentity stashes
// the authoritative actor extracted from the Kong-forwarded JWT. resolveActor()
// reads it (see middleware.go) and it becomes audit.actor for the whole request.
const CtxKeyGatewayActor = "wallet.gateway_actor"

// GatewayConfig is the runtime config for the Kong-gateway trust middleware.
// Build it from config.GatewayAuth in server.New so this package stays free of
// the env-binding code (mirrors JWTConfig).
type GatewayConfig struct {
	Enforce            bool   // reject mutating requests that carry no decodable identity
	JWTHeader          string // header Kong forwards the validated JWT in (e.g. Authorization)
	ActorClaim         string // primary claim to use as the actor (e.g. preferred_username)
	ActorClaimFallback string // claim to use when ActorClaim is absent (e.g. sub)
}

// GatewayIdentity extracts the caller identity that Kong (the API gateway)
// already authenticated, and stashes it on the gin context so downstream
// auditing attributes the change to a TRUSTED actor rather than a spoofable
// client header.
//
// TRUST MODEL — this is deliberate: authentication is performed UPSTREAM by
// Kong, which validates the JWT signature/exp/aud/iss. This service does NOT
// re-verify the signature; it only base64url-DECODEs the JWT payload and reads
// the actor claim ("JWT claim forward"). Consequently these endpoints MUST only
// be reachable through Kong — never exposed directly to untrusted clients. When
// the token is missing or unparseable the actor is simply left empty (the
// request is rejected later by EnforceGatewayIdentity on mutating routes when
// Enforce is on).
func GatewayIdentity(cfg GatewayConfig) gin.HandlerFunc {
	header := cfg.JWTHeader
	if header == "" {
		header = "Authorization"
	}
	return func(c *gin.Context) {
		if actor := gatewayActorFromRequest(c, header, cfg.ActorClaim, cfg.ActorClaimFallback); actor != "" {
			c.Set(CtxKeyGatewayActor, actor)
		}
		c.Next()
	}
}

// EnforceGatewayIdentity rejects MUTATING requests (POST/PUT/PATCH/DELETE) that
// carry no gateway-verified actor with a 401 RFC7807 envelope. Read-only methods
// (GET/HEAD/OPTIONS) always pass — Kong still fronts them but a balance/profile
// read is not a change that needs an attributable actor. When enforce is false
// (local dev, APP_ENV=dev) it is a no-op so the stack runs without a gateway.
func EnforceGatewayIdentity(enforce bool) gin.HandlerFunc {
	return func(c *gin.Context) {
		if !enforce || !isMutatingMethod(c.Request.Method) {
			c.Next()
			return
		}
		if v, ok := c.Get(CtxKeyGatewayActor); ok {
			if s, _ := v.(string); s != "" {
				c.Next()
				return
			}
		}
		writeProblem(c, dto.NewProblem(
			domain.CodeUnauthorized, http.StatusUnauthorized,
			"missing or unparseable gateway identity token",
			c.Request.URL.Path, c.GetString(CtxKeyRequestID)))
	}
}

// GatewayActor returns the gateway-extracted actor and whether one was present.
func GatewayActor(c *gin.Context) (string, bool) {
	if v, ok := c.Get(CtxKeyGatewayActor); ok {
		if s, _ := v.(string); s != "" {
			return s, true
		}
	}
	return "", false
}

func isMutatingMethod(m string) bool {
	switch m {
	case http.MethodPost, http.MethodPut, http.MethodPatch, http.MethodDelete:
		return true
	default:
		return false
	}
}

// gatewayActorFromRequest reads the JWT from the configured header, decodes its
// (already-verified) payload and returns actorClaim, falling back to
// fallbackClaim (typically "sub"). Returns "" when the token is missing or
// unparseable.
func gatewayActorFromRequest(c *gin.Context, header, actorClaim, fallbackClaim string) string {
	raw := strings.TrimSpace(c.GetHeader(header))
	if raw == "" {
		return ""
	}
	// Tolerate the "Bearer " scheme prefix (Authorization header) or a bare token.
	const bearer = "bearer "
	if len(raw) >= len(bearer) && strings.EqualFold(raw[:len(bearer)], bearer) {
		raw = strings.TrimSpace(raw[len(bearer):])
	}
	claims, ok := decodeJWTPayload(raw)
	if !ok {
		return ""
	}
	if v := claimString(claims, actorClaim); v != "" {
		return v
	}
	return claimString(claims, fallbackClaim)
}

// decodeJWTPayload splits a JWT and base64url-decodes the PAYLOAD segment into a
// claims map. It does NOT verify the signature — Kong already did (see the trust
// model on GatewayIdentity). Returns ok=false for anything that is not a
// header.payload[.signature] with a decodable JSON payload.
func decodeJWTPayload(token string) (map[string]any, bool) {
	parts := strings.Split(token, ".")
	if len(parts) < 2 {
		return nil, false
	}
	payload, err := b64urlDecode(parts[1])
	if err != nil {
		return nil, false
	}
	var claims map[string]any
	if err := json.Unmarshal(payload, &claims); err != nil {
		return nil, false
	}
	return claims, true
}

// b64urlDecode decodes a JWT segment. JWTs use base64url WITHOUT padding, but we
// re-pad and accept padded input too so a stray '=' does not defeat extraction.
func b64urlDecode(s string) ([]byte, error) {
	if m := len(s) % 4; m != 0 {
		s += strings.Repeat("=", 4-m)
	}
	return base64.URLEncoding.DecodeString(s)
}

// claimString returns the string value of claim key, or "" when the claim is
// absent, empty, or not a string.
func claimString(claims map[string]any, key string) string {
	if key == "" {
		return ""
	}
	if v, ok := claims[key]; ok {
		if s, ok := v.(string); ok {
			return strings.TrimSpace(s)
		}
	}
	return ""
}
