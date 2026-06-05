package middleware

import (
	"crypto/rsa"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/golang-jwt/jwt/v5"

	"github.com/ewallet-pg/wallet-service/internal/domain"
	"github.com/ewallet-pg/wallet-service/internal/http/dto"
)

// Context keys populated by the JWT middleware. Downstream middlewares /
// handlers read these via c.Get (no panic if absent → JWT disabled).
const (
	CtxKeyJWTSubject = "wallet.jwt_subject"
	CtxKeyJWTRoles   = "wallet.jwt_roles"
	CtxKeyJWTChannel = "wallet.jwt_channel"
)

// JWTConfig is the runtime config consumed by the middleware. Construct it
// from config.JWT in cmd/server/main.go; the package boundary keeps the
// middleware independent of the env-binding code.
type JWTConfig struct {
	Enabled      bool
	Issuer       string
	Audience     string
	Algorithm    string // HS256 | RS256
	HMACSecret   string
	RSAPublicKey string // PEM-encoded
	RolesClaim   string
	ChannelClaim string // claim holding the source channel; empty/absent → X-Channel header fallback
	ClockSkew    time.Duration
}

// JWT returns a gin middleware that validates the Bearer token on each request
// and extracts the subject + roles into the gin context. When cfg.Enabled is
// false the middleware is a no-op — useful for dev / unit tests where the
// gateway hasn't issued a token. Misconfiguration (bad PEM, unknown algorithm)
// fails fast at construction so a typo doesn't silently bypass auth in prod.
func JWT(cfg JWTConfig) (gin.HandlerFunc, error) {
	if !cfg.Enabled {
		return func(c *gin.Context) { c.Next() }, nil
	}
	keyFunc, err := buildKeyFunc(cfg)
	if err != nil {
		return nil, fmt.Errorf("jwt middleware: %w", err)
	}
	parserOpts := []jwt.ParserOption{
		jwt.WithLeeway(cfg.ClockSkew),
		jwt.WithValidMethods([]string{cfg.Algorithm}),
		jwt.WithExpirationRequired(),
	}
	if cfg.Issuer != "" {
		parserOpts = append(parserOpts, jwt.WithIssuer(cfg.Issuer))
	}
	if cfg.Audience != "" {
		parserOpts = append(parserOpts, jwt.WithAudience(cfg.Audience))
	}
	parser := jwt.NewParser(parserOpts...)
	rolesClaim := cfg.RolesClaim
	if rolesClaim == "" {
		rolesClaim = "roles"
	}
	channelClaim := cfg.ChannelClaim
	return func(c *gin.Context) {
		raw := bearerToken(c)
		if raw == "" {
			abortUnauthorized(c, "missing or malformed Authorization header")
			return
		}
		claims := jwt.MapClaims{}
		if _, err := parser.ParseWithClaims(raw, claims, keyFunc); err != nil {
			abortUnauthorized(c, "invalid token: "+err.Error())
			return
		}
		sub, _ := claims["sub"].(string)
		if sub == "" {
			abortUnauthorized(c, "missing sub claim")
			return
		}
		c.Set(CtxKeyJWTSubject, sub)
		c.Set(CtxKeyJWTRoles, extractRoles(claims, rolesClaim))
		if ch := extractChannel(claims, channelClaim); ch != "" {
			c.Set(CtxKeyJWTChannel, ch)
		}
		c.Next()
	}, nil
}

// extractChannel reads the channel claim and returns its trimmed string value.
// When the claim is absent or not a string, returns "" so the caller falls
// back to the X-Channel header.
func extractChannel(claims jwt.MapClaims, key string) string {
	if key == "" {
		return ""
	}
	raw, ok := claims[key]
	if !ok {
		return ""
	}
	s, _ := raw.(string)
	return strings.TrimSpace(s)
}

func buildKeyFunc(cfg JWTConfig) (jwt.Keyfunc, error) {
	switch strings.ToUpper(cfg.Algorithm) {
	case "HS256":
		if cfg.HMACSecret == "" {
			return nil, errors.New("HS256 requires JWT_HMAC_SECRET")
		}
		secret := []byte(cfg.HMACSecret)
		return func(_ *jwt.Token) (any, error) { return secret, nil }, nil
	case "RS256":
		if cfg.RSAPublicKey == "" {
			return nil, errors.New("RS256 requires JWT_RSA_PUBLIC_KEY (PEM)")
		}
		pub, err := jwt.ParseRSAPublicKeyFromPEM([]byte(cfg.RSAPublicKey))
		if err != nil {
			return nil, fmt.Errorf("parse RSA public key: %w", err)
		}
		return func(_ *jwt.Token) (any, error) { return (*rsa.PublicKey)(pub), nil }, nil
	}
	return nil, fmt.Errorf("unsupported algorithm %q (HS256 or RS256)", cfg.Algorithm)
}

// extractRoles reads the roles claim. Accepts both []string and a
// space-separated string (some IdPs flatten claim values).
func extractRoles(claims jwt.MapClaims, key string) []string {
	raw, ok := claims[key]
	if !ok {
		return nil
	}
	switch v := raw.(type) {
	case []any:
		out := make([]string, 0, len(v))
		for _, e := range v {
			if s, ok := e.(string); ok && s != "" {
				out = append(out, s)
			}
		}
		return out
	case []string:
		return v
	case string:
		return strings.Fields(v)
	}
	return nil
}

func bearerToken(c *gin.Context) string {
	h := c.GetHeader("Authorization")
	const prefix = "Bearer "
	if len(h) <= len(prefix) || !strings.EqualFold(h[:len(prefix)], prefix) {
		return ""
	}
	return strings.TrimSpace(h[len(prefix):])
}

func abortUnauthorized(c *gin.Context, detail string) {
	writeProblem(c, dto.NewProblem(
		domain.CodeUnauthorized, http.StatusUnauthorized, detail,
		c.Request.URL.Path, c.GetString(CtxKeyRequestID)))
}
