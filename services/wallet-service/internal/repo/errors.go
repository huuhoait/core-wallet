package repo

import (
	"context"
	"errors"
	"net/http"
	"strings"

	"github.com/jackc/pgx/v5/pgconn"

	"github.com/ewallet-pg/wallet-service/internal/domain"
)

// mapPgError translates a pgx / driver error into a *domain.Error.
//
// Order of checks (more specific → general):
//  1. Already a *domain.Error (e.g. from a nested call): pass through.
//  2. context.DeadlineExceeded: caller's ctx fired before PG responded
//     → TIMEOUT / 504 Gateway Timeout.
//  3. context.Canceled: client disconnected mid-flight → CodeTimeout / 499.
//  4. *pgconn.PgError with SP-raised ERRCODE 'P00xx': parse the leading
//     token of the message as the canonical code (ACCT_NOT_FOUND, ...).
//  5. Standard PG SQLSTATEs (55P03 lock_timeout, 57014 query_canceled,
//     23505 unique_violation, ...): map to the closest domain code.
//  6. Anything else → INTERNAL with the cause preserved.
func mapPgError(err error) error {
	if err == nil {
		return nil
	}
	// 1. Pass-through existing domain errors so we don't double-wrap.
	var de *domain.Error
	if errors.As(err, &de) {
		return de
	}
	// 2 + 3. Context errors are NOT *pgconn.PgError — handle them up-front.
	if errors.Is(err, context.DeadlineExceeded) {
		return domain.NewError(domain.CodeTimeout, http.StatusGatewayTimeout,
			"request deadline exceeded", err)
	}
	if errors.Is(err, context.Canceled) {
		return domain.NewError(domain.CodeTimeout, 499, // nginx "Client Closed Request"
			"request canceled by client", err)
	}
	var pgErr *pgconn.PgError
	if !errors.As(err, &pgErr) {
		return domain.Internal(err)
	}

	// SP-raised exceptions all use ERRCODE classes 'P0' (PL/pgSQL custom).
	// The first token of MESSAGE is the canonical domain code.
	code, detail := parseSPMessage(pgErr.Message)

	switch pgErr.Code {
	case "40001": // serialization_failure — optimistic VERSION-CAS lost a race.
		// The SP raises VERSION_CONFLICT with this SQLSTATE; the work is safe to
		// re-run (fresh snapshot + idempotency gate), so surface it as a
		// RETRYABLE 409 rather than a terminal 500. withTx also retries it
		// server-side so most never reach the client.
		return pgDomainError(domain.CodeVersionConflict, http.StatusConflict,
			"version conflict: "+detail, pgErr)
	case "40P01": // deadlock_detected — PG aborted one TX to break a cycle.
		// Also safe to retry the whole operation; treat as a retryable conflict.
		return pgDomainError(domain.CodeVersionConflict, http.StatusConflict,
			"deadlock detected: "+detail, pgErr)
	case "55P03": // lock_not_available — lock_timeout fired
		return pgDomainError(domain.CodeTimeout, http.StatusServiceUnavailable,
			"lock timeout: "+detail, pgErr)
	case "57014": // query_canceled — statement_timeout fired
		return pgDomainError(domain.CodeTimeout, http.StatusGatewayTimeout,
			"statement timeout: "+detail, pgErr)
	case "23505": // unique_violation — usually idempotency-key race
		return pgDomainError(domain.CodeDuplicateReference, http.StatusConflict,
			"duplicate reference: "+detail, pgErr)
	case "23503": // foreign_key_violation
		return pgDomainError(domain.CodeInvalidRequest, http.StatusBadRequest,
			"foreign key violation: "+detail, pgErr)
	case "23514": // check_violation
		return pgDomainError(domain.CodeInvalidRequest, http.StatusBadRequest,
			"check violation: "+detail, pgErr)
	}

	// Only PL/pgSQL RAISE (custom 'P0' SQLSTATE class) carries a canonical code
	// in its message. Anything else (42501 permission, 08006 connection, …) must
	// NOT leak its raw text as a public code (§3.3) → INTERNAL_ERROR.
	if code == "" || !strings.HasPrefix(pgErr.Code, "P0") {
		return domain.Internal(err)
	}
	return pgDomainError(code, httpStatusFor(code), detail, pgErr)
}

// pgDomainError builds a domain.Error and overrides SQLState + RawMessage with
// the real values from *pgconn.PgError so the response surfaces the SP's actual
// SQLSTATE (P0060, 40001, ...) and full RAISE text. Cause stays the pg error
// so logs keep the full pg context (severity, hint, position).
func pgDomainError(canonical string, status int, detail string, pgErr *pgconn.PgError) *domain.Error {
	e := domain.NewError(canonical, status, detail, pgErr)
	e.SQLState = pgErr.Code
	e.RawMessage = pgErr.Message
	return e
}

// parseSPMessage extracts the token before the first ":" as the code.
//
//	"ACCT_NOT_FOUND: 9701..."   → code="ACCT_NOT_FOUND", detail="9701..."
//	"INSUFFICIENT_FUNDS: ..."   → code="INSUFFICIENT_FUNDS"
//	"VERSION_CONFLICT"          → code="VERSION_CONFLICT", detail=""
func parseSPMessage(msg string) (code, detail string) {
	idx := strings.IndexByte(msg, ':')
	if idx < 0 {
		return msg, ""
	}
	return strings.TrimSpace(msg[:idx]), strings.TrimSpace(msg[idx+1:])
}

// httpStatusFor maps the canonical SP code to an HTTP status.
// Family suffixes (*_NOT_FOUND, *_NOT_ACTIVE, *_CONFLICT) catch variants
// like FROM_ACCT_NOT_FOUND, TO_ACCT_NOT_ACTIVE without enumerating each.
func httpStatusFor(code string) int {
	switch code {
	case domain.CodeInvalidAmount,
		domain.CodeMetadataTooLarge,
		domain.CodeMetadataHasP1,
		domain.CodeSameAccount,
		domain.CodeAmountOutOfRange,
		domain.CodeTranTypeInactive,
		domain.CodeInvalidPhoneFormat,
		domain.CodeInvalidRequest:
		return http.StatusBadRequest
	case domain.CodeTierInsufficient:
		// KYC tier too low — auth/permission failure.
		return http.StatusForbidden
	case domain.CodeDRRestraintActive,
		domain.CodeCRRestraintActive,
		domain.CodeGroupRestrained:
		// Account/group is restrained/held → 423 Locked (error_management.md §2.1).
		return http.StatusLocked
	case domain.CodeInsufficientFunds,
		domain.CodeTierLimitExceeded,
		domain.CodeAcctRoleInvalid,
		domain.CodeReversalWindowExpired:
		// Schema valid, business rule fails → 422 Unprocessable Entity.
		// (ACCT_ROLE_INVALID: caller addressed an internal SHARD/SETTLEMENT wallet.)
		// (REVERSAL_WINDOW_EXPIRED: orig is older than WLT_TRAN_DEF window — use GL adjustment instead.)
		return http.StatusUnprocessableEntity
	case domain.CodeVersionConflict,
		domain.CodeWDAlreadyCompleted,
		domain.CodeWDAlreadyReversed,
		domain.CodeWDInvalidState,
		domain.CodeRestraintAlreadyRemoved,
		domain.CodeClientAlreadyExists,
		domain.CodePhoneAlreadyRegistered,
		domain.CodeMaxWalletExceeded,
		domain.CodeGroupAlreadyActivated,
		domain.CodeGroupAlreadyExists,
		domain.CodeGroupNotActivated:
		// Group lifecycle state conflicts: already hot / group_id taken / still
		// cold when a rescale needs it hot — all conflict with current state.
		return http.StatusConflict
	case domain.CodeRestraintTypeInvalid,
		domain.CodeRestraintPurposeInvalid,
		domain.CodeRestraintTypePurposeConflict,
		domain.CodeRestraintAmtExceedsBalance,
		domain.CodeRestraintDateInvalid,
		domain.CodeCourtOrderRemoveRequiresDoc,
		domain.CodeInvalidClientType,
		domain.CodeInvalidAcctType,
		domain.CodeAcctCloseNonzeroBal,
		domain.CodeOrgFieldsRequired,
		domain.CodeInvalidShardCount,
		domain.CodeInvalidGroupType:
		// Schema-valid request but a business rule fails (e.g. shard count not a
		// supported hot tier, or group_type not in the allowed set).
		return http.StatusUnprocessableEntity
	case domain.CodePIIDekNotSet,
		domain.CodeBatchUnbalanced:
		// Internal invariant violations (key not set / unbalanced posting): the
		// client did nothing wrong and the TX is aborted → 500, no detail leak.
		return http.StatusInternalServerError
	case domain.CodeInvalidDate, domain.CodeBatchSizeExceeded:
		return http.StatusUnprocessableEntity
	case domain.CodeGoneOnline:
		return http.StatusGone
	case domain.CodePeriodClosed:
		// Backdated posting into a sealed business period — request conflicts with
		// the closed state of the ledger; re-post against an open date.
		return http.StatusConflict
	}
	// Family-based fallbacks for from/to-prefixed variants.
	switch {
	case strings.HasSuffix(code, "_NOT_FOUND"):
		return http.StatusNotFound
	case strings.HasSuffix(code, "_NOT_ACTIVE"):
		return http.StatusForbidden
	case strings.HasSuffix(code, "_CONFLICT"):
		return http.StatusConflict
	}
	return http.StatusInternalServerError
}
