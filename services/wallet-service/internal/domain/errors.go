package domain

import (
	"errors"
	"fmt"
	"net/http"
)

// Error is the canonical domain error. It carries:
//   - Code: stable identifier (mirrors SP ERRCODEs)
//   - HTTPStatus: how the HTTP layer should respond
//   - Detail: human-readable context (safe for client display)
//   - Cause: wrapped underlying error for log/trace
type Error struct {
	Code       string
	HTTPStatus int
	Detail     string
	Cause      error
}

func (e *Error) Error() string {
	if e.Cause != nil {
		return fmt.Sprintf("%s: %s (cause: %v)", e.Code, e.Detail, e.Cause)
	}
	return fmt.Sprintf("%s: %s", e.Code, e.Detail)
}

func (e *Error) Unwrap() error { return e.Cause }

// IsRetriable returns true for errors the caller is permitted to retry (e.g.
// version conflict where state may have changed in the meantime).
func (e *Error) IsRetriable() bool {
	return e.Code == CodeVersionConflict
}

// Canonical error codes — keep in sync with wallet_sp.sql RAISE EXCEPTION codes.
// HTTPStatus mapping reflects which side of the bus is at fault.
const (
	CodeInvalidAmount        = "INVALID_AMOUNT"
	CodeMetadataTooLarge     = "METADATA_TOO_LARGE"
	CodeMetadataHasP1        = "METADATA_HAS_P1"
	CodeSameAccount          = "SAME_ACCOUNT"
	CodeTranTypeInactive     = "TRAN_TYPE_INACTIVE"
	CodeAcctNotFound         = "ACCT_NOT_FOUND"
	CodeAcctNotActive        = "ACCT_NOT_ACTIVE"
	CodeTierInsufficient     = "TIER_INSUFFICIENT"
	CodeAmountOutOfRange     = "AMOUNT_OUT_OF_RANGE"
	CodeDRRestraintActive    = "DR_RESTRAINT_ACTIVE"
	CodeCRRestraintActive    = "CR_RESTRAINT_ACTIVE"
	CodeInsufficientFunds    = "INSUFFICIENT_FUNDS"
	CodeTierLimitExceeded    = "TIER_LIMIT_EXCEEDED"
	CodeVersionConflict      = "VERSION_CONFLICT"
	CodePIIDekNotSet         = "PII_DEK_NOT_SET"
	CodeWDNotFound           = "WD_NOT_FOUND"
	CodeWDAlreadyCompleted   = "WD_ALREADY_COMPLETED"
	CodeWDInvalidState       = "WD_INVALID_STATE"
	CodeWDAlreadyReversed    = "WD_ALREADY_REVERSED"
	CodeInternal             = "INTERNAL_ERROR"
	CodeTimeout              = "TIMEOUT"
	CodeUnauthorized         = "UNAUTHORIZED"
	CodeForbidden            = "FORBIDDEN"
	CodeInvalidRequest       = "INVALID_REQUEST"
	CodeDuplicateReference   = "DUPLICATE_REFERENCE"
	// Balance query (Get Balance §9)
	CodeInvalidDate          = "INVALID_DATE"
	CodeGoneOnline           = "GONE_ONLINE"
	CodeBatchSizeExceeded    = "BATCH_SIZE_EXCEEDED"
	// Restraint management (§4.9)
	CodeRestraintNotFound            = "RESTRAINT_NOT_FOUND"
	CodeRestraintAlreadyRemoved      = "RESTRAINT_ALREADY_REMOVED"
	CodeRestraintTypeInvalid         = "RESTRAINT_TYPE_INVALID"
	CodeRestraintPurposeInvalid      = "RESTRAINT_PURPOSE_INVALID"
	CodeRestraintTypePurposeConflict = "RESTRAINT_TYPE_PURPOSE_CONFLICT"
	CodeRestraintAmtExceedsBalance   = "RESTRAINT_AMT_EXCEEDS_BALANCE"
	CodeRestraintDateInvalid         = "RESTRAINT_DATE_INVALID"
	CodeCourtOrderRemoveRequiresDoc  = "COURT_ORDER_REMOVE_REQUIRES_DOC"
)

// Helpers for constructing errors at boundaries.
func NewError(code string, status int, detail string, cause error) *Error {
	return &Error{Code: code, HTTPStatus: status, Detail: detail, Cause: cause}
}

func NotFound(detail string, cause error) *Error {
	return NewError(CodeAcctNotFound, http.StatusNotFound, detail, cause)
}

func InvalidRequest(detail string, cause error) *Error {
	return NewError(CodeInvalidRequest, http.StatusBadRequest, detail, cause)
}

func Conflict(code, detail string, cause error) *Error {
	return NewError(code, http.StatusConflict, detail, cause)
}

func Internal(cause error) *Error {
	return NewError(CodeInternal, http.StatusInternalServerError, "internal server error", cause)
}

// AsDomain extracts the *Error from an arbitrary error chain.
func AsDomain(err error) (*Error, bool) {
	var de *Error
	if errors.As(err, &de) {
		return de, true
	}
	return nil, false
}
