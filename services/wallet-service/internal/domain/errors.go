package domain

import (
	"errors"
	"fmt"
	"net/http"
)

// Error is the canonical domain error. It carries:
//   - Code: stable canonical name (REVERSAL_WINDOW_EXPIRED, ...) used for
//     internal routing (httpStatusFor, codeMeta lookup, log grep).
//   - SQLState: the SQLSTATE the response should expose as `errorCode`. For
//     PG-raised errors this is the real pgErr.Code (P0060, 40001, 23505, ...);
//     for Go-constructed errors it is synthesized from MetaFor(code).InternalCode
//     (E####). Surfaced verbatim to the client when the code is in the
//     client-safe whitelist; replaced with "999999" otherwise.
//   - HTTPStatus: how the HTTP layer should respond.
//   - Detail: dynamic context (safe for client display when whitelisted).
//   - RawMessage: full original "CODE: detail" text. For PG errors this is
//     pgErr.Message verbatim; for Go-constructed errors it is synthesized as
//     "Code: Detail". Surfaced as `errorMessage` in the response (whitelisted
//     codes only).
//   - Cause: wrapped underlying error for log/trace.
type Error struct {
	Code       string
	SQLState   string
	HTTPStatus int
	Detail     string
	RawMessage string
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
	CodeAcctRoleInvalid      = "ACCT_ROLE_INVALID" // posting targeted a non-STANDALONE (SHARD/SETTLEMENT) wallet
	CodeBatchUnbalanced      = "BATCH_UNBALANCED"  // double-entry invariant ΣDR≠ΣCR (constraint trigger) — internal bug, never client
	CodeTierInsufficient     = "TIER_INSUFFICIENT"
	CodeAmountOutOfRange     = "AMOUNT_OUT_OF_RANGE"
	CodeDRRestraintActive    = "DR_RESTRAINT_ACTIVE"
	CodeCRRestraintActive    = "CR_RESTRAINT_ACTIVE"
	CodeGroupRestrained      = "GROUP_RESTRAINED" // merchant-withdraw blocked by group-level DR restraint (P0025)
	CodeInsufficientFunds    = "INSUFFICIENT_FUNDS"
	CodeTierLimitExceeded    = "TIER_LIMIT_EXCEEDED"
	CodeVersionConflict      = "VERSION_CONFLICT"
	CodePIIDekNotSet         = "PII_DEK_NOT_SET"
	CodeWDNotFound           = "WD_NOT_FOUND"
	CodeWDAlreadyCompleted   = "WD_ALREADY_COMPLETED"
	CodeWDInvalidState       = "WD_INVALID_STATE"
	CodeWDAlreadyReversed    = "WD_ALREADY_REVERSED"
	CodeReversalWindowExpired = "REVERSAL_WINDOW_EXPIRED" // orig posted outside the per-tran-type allowed window (P0060)
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
	// Client master CRUD
	CodeInvalidClientType   = "INVALID_CLIENT_TYPE"
	CodeClientAlreadyExists = "CLIENT_ALREADY_EXISTS"
	CodeClientNotFound      = "CLIENT_NOT_FOUND"
	// Onboarding (US-1.1/1.2/1.7) — OTP-free 4-step flow
	CodePhoneAlreadyRegistered = "PHONE_ALREADY_REGISTERED" // duplicate phone_no_hash
	CodeInvalidPhoneFormat     = "INVALID_PHONE_FORMAT"
	CodeKycNotFound            = "KYC_NOT_FOUND"
	CodeOrgFieldsRequired      = "ORG_FIELDS_REQUIRED" // CORP/MER need business_reg_no + legal_rep (BR-09)
	// Client linked-bank management (BANK_LINK_NOT_FOUND → 404 via _NOT_FOUND family)
	CodeBankLinkNotFound = "BANK_LINK_NOT_FOUND"
	// Account (wallet) lifecycle
	CodeInvalidAcctType     = "INVALID_ACCT_TYPE"
	CodeMaxWalletExceeded   = "MAX_WALLET_PER_CLIENT_EXCEEDED"
	CodeAcctCloseNonzeroBal = "ACCT_CLOSE_NONZERO_BAL"
	// Merchant hot-wallet group lifecycle (activate_hot_wallet / provision_acct_group
	// / rescale_hot_wallet, P0052–P0057). GROUP_NOT_FOUND (P0050) /
	// SETTLEMENT_NOT_FOUND (P0054) map to 404, and GROUP_NOT_ACTIVE (P0022) to 403,
	// via the _NOT_FOUND / _NOT_ACTIVE family fallbacks — no explicit constant here.
	CodeInvalidShardCount     = "INVALID_SHARD_COUNT"
	CodeGroupAlreadyActivated = "GROUP_ALREADY_ACTIVATED"
	CodeInvalidGroupType      = "INVALID_GROUP_TYPE"   // provision: group_type not in MERCHANT/AGENT/NOSTRO_HOT (P0055)
	CodeGroupAlreadyExists    = "GROUP_ALREADY_EXISTS" // provision: group_id already taken (P0056)
	CodeGroupNotActivated     = "GROUP_NOT_ACTIVATED"  // rescale: group is still cold — activate first (P0057)
	// EOD period locking (US-6.1) — a posting/reversal dated into a closed
	// business period is rejected by the write-freeze trigger (SQLSTATE P0092).
	CodePeriodClosed = "PERIOD_CLOSED"
	// Manual journal entry — maker-checker (US-6.5). create/approve/reject SPs
	// raise these (P00B0–P00B6). MJE_NOT_FOUND → 404 via the _NOT_FOUND family.
	CodeMJEReasonRequired   = "MJE_REASON_REQUIRED"    // create: reason mandatory (P00B0)
	CodeMJEInvalidLines     = "MJE_INVALID_LINES"      // create: <2 lines / bad nature / amount ≤ 0 (P00B1)
	CodeMJEGLInvalid        = "MJE_GL_INVALID"         // create: gl_code unknown/inactive (P00B2)
	CodeMJEUnbalanced       = "MJE_UNBALANCED"         // create: ΣDR ≠ ΣCR (P00B3)
	CodeMJENotFound         = "MJE_NOT_FOUND"          // approve/reject: unknown je_id (P00B4)
	CodeMJEInvalidState     = "MJE_INVALID_STATE"      // approve/reject: not PENDING (P00B5)
	CodeMJEMakerCannotCheck = "MJE_MAKER_CANNOT_CHECK" // approve: checker == maker (P00B6)
)

// Helpers for constructing errors at boundaries. SQLState + RawMessage are
// synthesized from the canonical code so Go-side errors carry the same shape
// as PG-raised ones (mapPgError overrides both with the real pgErr values).
func NewError(code string, status int, detail string, cause error) *Error {
	e := &Error{Code: code, HTTPStatus: status, Detail: detail, Cause: cause}
	e.SQLState = MetaFor(code).InternalCode // E#### synthetic SQLSTATE; "" if code unknown
	if detail == "" {
		e.RawMessage = code
	} else {
		e.RawMessage = code + ": " + detail
	}
	return e
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
