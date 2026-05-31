package repo

import (
	"context"
	"errors"
	"net/http"
	"testing"

	"github.com/jackc/pgx/v5/pgconn"

	"github.com/ewallet-pg/wallet-service/internal/domain"
)

// TestMapPgError_SQLSTATE asserts the full pg-error → domain.Error contract,
// the seam that previously let VERSION_CONFLICT (40001) and deadlock (40P01)
// collapse to a non-retryable HTTP 500. It also pins the no-leak rule: a
// non-P0 SQLSTATE must surface as INTERNAL_ERROR without exposing raw text.
func TestMapPgError_SQLSTATE(t *testing.T) {
	cases := []struct {
		name          string
		code          string // SQLSTATE
		message       string
		wantCode      string
		wantStatus    int
		wantRetriable bool
	}{
		{"serialization_failure→retryable 409", "40001", "VERSION_CONFLICT", domain.CodeVersionConflict, http.StatusConflict, true},
		{"deadlock_detected→retryable 409", "40P01", "deadlock detected", domain.CodeVersionConflict, http.StatusConflict, true},
		{"lock_timeout→503", "55P03", "canceling statement due to lock timeout", domain.CodeTimeout, http.StatusServiceUnavailable, false},
		{"statement_timeout→504", "57014", "canceling statement due to statement timeout", domain.CodeTimeout, http.StatusGatewayTimeout, false},
		{"unique_violation→409", "23505", "duplicate key", domain.CodeDuplicateReference, http.StatusConflict, false},
		{"acct_role_invalid→422", "P0028", "ACCT_ROLE_INVALID: X is a SHARD wallet", domain.CodeAcctRoleInvalid, http.StatusUnprocessableEntity, false},
		{"acct_not_active→403", "P0022", "ACCT_NOT_ACTIVE: status=C", domain.CodeAcctNotActive, http.StatusForbidden, false},
		{"cr_restraint_active→423", "P0029", "CR_RESTRAINT_ACTIVE: refund target X is credit-blocked", domain.CodeCRRestraintActive, http.StatusLocked, false},
		{"insufficient_funds→422", "P0026", "INSUFFICIENT_FUNDS: receiver X", domain.CodeInsufficientFunds, http.StatusUnprocessableEntity, false},
		// Merchant hot-wallet group lifecycle (activate_hot_wallet).
		{"invalid_shard_count→422", "P0052", "INVALID_SHARD_COUNT: 5 (allowed: 4, 8, 16)", domain.CodeInvalidShardCount, http.StatusUnprocessableEntity, false},
		{"group_already_activated→409", "P0053", "GROUP_ALREADY_ACTIVATED: GF01 already has 4 shard(s)", domain.CodeGroupAlreadyActivated, http.StatusConflict, false},
		{"settlement_not_found→404 (family)", "P0054", "SETTLEMENT_NOT_FOUND: group GF01 has no settlement account", "SETTLEMENT_NOT_FOUND", http.StatusNotFound, false},
		{"group_not_found→404 (family)", "P0050", "GROUP_NOT_FOUND: GF01", "GROUP_NOT_FOUND", http.StatusNotFound, false},
		{"non_P0_permission→internal 500 (no leak)", "42501", "permission denied for table WLT_ACCT", domain.CodeInternal, http.StatusInternalServerError, false},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			pgErr := &pgconn.PgError{Code: tc.code, Message: tc.message}
			de, ok := domain.AsDomain(mapPgError(pgErr))
			if !ok {
				t.Fatalf("expected *domain.Error, got plain error")
			}
			if de.Code != tc.wantCode {
				t.Errorf("code: got %q want %q", de.Code, tc.wantCode)
			}
			if de.HTTPStatus != tc.wantStatus {
				t.Errorf("status: got %d want %d", de.HTTPStatus, tc.wantStatus)
			}
			if de.IsRetriable() != tc.wantRetriable {
				t.Errorf("retriable: got %v want %v", de.IsRetriable(), tc.wantRetriable)
			}
			// No-leak: a non-P0 SQLSTATE must not echo its raw message as detail.
			if tc.code == "42501" && de.Detail != "internal server error" {
				t.Errorf("non-P0 leaked detail: %q", de.Detail)
			}
		})
	}
}

// TestMapPgError_ContextErrors covers the up-front ctx branches (not PgErrors).
func TestMapPgError_ContextErrors(t *testing.T) {
	if de, _ := domain.AsDomain(mapPgError(context.DeadlineExceeded)); de.HTTPStatus != http.StatusGatewayTimeout {
		t.Errorf("DeadlineExceeded: got %d want 504", de.HTTPStatus)
	}
	if de, _ := domain.AsDomain(mapPgError(context.Canceled)); de.HTTPStatus != 499 {
		t.Errorf("Canceled: got %d want 499", de.HTTPStatus)
	}
}

// TestMapPgError_PassThrough: an existing *domain.Error is not re-wrapped.
func TestMapPgError_PassThrough(t *testing.T) {
	orig := domain.NewError(domain.CodeInsufficientFunds, http.StatusUnprocessableEntity, "x", nil)
	got := mapPgError(orig)
	if !errors.Is(got, orig) {
		t.Errorf("domain.Error not passed through: got %v", got)
	}
}
