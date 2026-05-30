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
	case "55P03": // lock_not_available — lock_timeout fired
		return domain.NewError(domain.CodeTimeout, http.StatusServiceUnavailable,
			"lock timeout: "+detail, err)
	case "57014": // query_canceled — statement_timeout fired
		return domain.NewError(domain.CodeTimeout, http.StatusGatewayTimeout,
			"statement timeout: "+detail, err)
	case "23505": // unique_violation — usually idempotency-key race
		return domain.NewError("DUPLICATE_REQUEST", http.StatusConflict,
			"duplicate request: "+detail, err)
	case "23503": // foreign_key_violation
		return domain.NewError(domain.CodeInvalidRequest, http.StatusBadRequest,
			"foreign key violation: "+detail, err)
	case "23514": // check_violation
		return domain.NewError(domain.CodeInvalidRequest, http.StatusBadRequest,
			"check violation: "+detail, err)
	}

	if code == "" {
		return domain.Internal(err)
	}
	return domain.NewError(code, httpStatusFor(code), detail, err)
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
		domain.CodeInvalidRequest:
		return http.StatusBadRequest
	case domain.CodeDRRestraintActive,
		domain.CodeCRRestraintActive,
		domain.CodeTierInsufficient:
		return http.StatusForbidden
	case domain.CodeInsufficientFunds:
		return http.StatusPaymentRequired
	case domain.CodeTierLimitExceeded:
		return http.StatusTooManyRequests
	case domain.CodeVersionConflict,
		domain.CodeWDAlreadyCompleted,
		domain.CodeWDAlreadyReversed,
		domain.CodeWDInvalidState:
		return http.StatusConflict
	case domain.CodePIIDekNotSet:
		return http.StatusInternalServerError
	case domain.CodeInvalidDate, domain.CodeBatchSizeExceeded:
		return http.StatusUnprocessableEntity
	case domain.CodeGoneOnline:
		return http.StatusGone
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
