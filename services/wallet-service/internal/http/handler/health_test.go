package handler

import (
	"context"
	"errors"
	"net/http"
	"testing"
)

// fakePinger stands in for the DB pool in the readiness check.
type fakePinger struct{ err error }

func (f fakePinger) Ping(context.Context) error { return f.err }

// TestReadyz_OK verifies a healthy DB ping yields 200.
func TestReadyz_OK(t *testing.T) {
	c, w := testCtx(http.MethodGet, "/readyz")
	(&Wallet{pinger: fakePinger{}}).Readyz(c)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", w.Code)
	}
}

// TestReadyz_DBDown verifies a failing DB ping yields 503 so a pod with a dead
// DB is pulled out of the load balancer instead of serving traffic.
func TestReadyz_DBDown(t *testing.T) {
	c, w := testCtx(http.MethodGet, "/readyz")
	(&Wallet{pinger: fakePinger{err: errors.New("pool exhausted")}}).Readyz(c)
	if w.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want 503", w.Code)
	}
}

// TestHealthz_CheapLiveness verifies liveness stays a cheap 200 with no DB
// dependency (a nil pinger must not be touched).
func TestHealthz_CheapLiveness(t *testing.T) {
	c, w := testCtx(http.MethodGet, "/healthz")
	(&Wallet{}).Healthz(c)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", w.Code)
	}
}
