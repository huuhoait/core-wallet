package domain

import "strings"

// ISO 20022 payment-transaction status codes (ExternalPaymentTransactionStatus1Code),
// reused by Berlin Group NextGenPSD2 as `transactionStatus`. See
// docs/specs/error_management.md §13.3.
const (
	TxStatusReceived          = "RCVD" // received, not yet validated
	TxStatusAcceptedTechnical = "ACTC" // accepted technical validation (ledger committed, awaiting settlement)
	TxStatusInProcess         = "ACSP" // accepted, settlement in process
	TxStatusSettled           = "ACSC" // accepted, settlement completed
	TxStatusRejected          = "RJCT" // rejected
	TxStatusPending           = "PDNG" // pending / outcome unknown (e.g. timeout)
)

// CodeMeta is the standards metadata attached to a canonical error Code,
// used to build the RFC 7807 problem+json envelope (§13.5).
type CodeMeta struct {
	Title        string // short human title (RFC 7807 "title")
	InternalCode string // E#### for logs/alerts (error_management.md §5)
	ISOReason    string // ISO 20022 External Status Reason (§13.2); "" if none
	TxStatus     string // pain.002 transactionStatus for this error; "" if N/A
}

// codeMeta maps each canonical (implemented) error code to its standards
// metadata. Canonical names are the ones raised by the SPs / domain layer —
// docs follow code (decision 2026-05-30, §14.2). Crosswalk: §14.1.
var codeMeta = map[string]CodeMeta{
	CodeInvalidAmount:      {"Invalid amount", "E4024", "AM12", TxStatusRejected},
	CodeAmountOutOfRange:   {"Amount out of range", "E4024", "AM02", TxStatusRejected},
	CodeMetadataTooLarge:   {"Metadata too large", "E4007", "", TxStatusRejected},
	CodeMetadataHasP1:      {"Metadata contains restricted (P1) data", "E4008", "", TxStatusRejected},
	CodeSameAccount:        {"Source and destination are the same account", "E4002", "BE01", TxStatusRejected},
	CodeTranTypeInactive:   {"Transaction type not active", "E4003", "AG02", TxStatusRejected},
	CodeAcctNotFound:       {"Account not found", "E3001", "AC01", TxStatusRejected},
	CodeAcctNotActive:      {"Account not active", "E3004", "AC04", TxStatusRejected},
	CodeTierInsufficient:   {"KYC tier insufficient", "E2007", "RR04", TxStatusRejected},
	CodeDRRestraintActive:  {"Account is debit-restrained", "E3005", "AC06", TxStatusRejected},
	CodeCRRestraintActive:  {"Account is credit-restrained", "E3006", "AC06", TxStatusRejected},
	CodeInsufficientFunds:  {"Insufficient funds", "E4022", "AM04", TxStatusRejected},
	CodeTierLimitExceeded:  {"Transaction limit exceeded", "E4023", "AM02", TxStatusRejected},
	CodeVersionConflict:    {"Concurrent update conflict", "E4025", "", TxStatusPending},
	CodePIIDekNotSet:       {"PII encryption key not configured", "E5005", "", TxStatusPending},
	CodeWDNotFound:         {"Withdrawal not found", "E6101", "", ""},
	CodeWDAlreadyCompleted: {"Withdrawal already completed", "E6102", "", ""},
	CodeWDInvalidState:     {"Withdrawal in invalid state for this action", "E6103", "", ""},
	CodeWDAlreadyReversed:  {"Withdrawal already reversed", "E6104", "", ""},
	CodeDuplicateReference: {"Duplicate reference", "E4011", "AM05", ""},
	CodeInternal:           {"Internal error", "E9001", "", TxStatusPending},
	CodeTimeout:            {"Request timed out", "E9004", "", TxStatusPending},
	CodeUnauthorized:       {"Unauthorized", "E1001", "", ""},
	CodeForbidden:          {"Forbidden", "E1006", "AG01", ""},
	CodeInvalidRequest:     {"Invalid request", "E4001", "", TxStatusRejected},
	CodeInvalidDate:        {"Invalid date", "E8003", "DT01", ""},
	CodeGoneOnline:         {"Data no longer available online", "E8001", "", ""},
	CodeBatchSizeExceeded:  {"Batch size exceeded", "E8004", "", ""},
	// Restraint management (§4.9)
	CodeRestraintNotFound:            {"Restraint not found", "E3020", "", ""},
	CodeRestraintAlreadyRemoved:      {"Restraint already removed", "E3021", "", ""},
	CodeRestraintTypeInvalid:         {"Invalid restraint type", "E3022", "", ""},
	CodeRestraintPurposeInvalid:      {"Invalid restraint purpose", "E3023", "", ""},
	CodeRestraintTypePurposeConflict: {"Restraint type/purpose conflict", "E3024", "", ""},
	CodeRestraintAmtExceedsBalance:   {"Pledged amount exceeds balance", "E3025", "AM04", ""},
	CodeRestraintDateInvalid:         {"Invalid restraint date range", "E3026", "DT01", ""},
	CodeCourtOrderRemoveRequiresDoc:  {"Court/tax-lien removal requires a documented reason", "E3027", "RR04", ""},
}

// MetaFor returns the standards metadata for a canonical code. Unknown codes
// fall back to family suffixes (FROM_ACCT_NOT_FOUND, TO_ACCT_NOT_ACTIVE, …) so
// SP-prefixed variants still resolve a reason; otherwise Title defaults to the
// code itself.
func MetaFor(code string) CodeMeta {
	if m, ok := codeMeta[code]; ok {
		return m
	}
	switch {
	case strings.HasSuffix(code, "_NOT_FOUND"):
		return CodeMeta{Title: "Resource not found", ISOReason: "AC01", TxStatus: TxStatusRejected}
	case strings.HasSuffix(code, "_NOT_ACTIVE"):
		return CodeMeta{Title: "Resource not active", ISOReason: "AC04", TxStatus: TxStatusRejected}
	case strings.HasSuffix(code, "_RESTRAINT_ACTIVE"):
		return CodeMeta{Title: "Account restrained", ISOReason: "AC06", TxStatus: TxStatusRejected}
	}
	return CodeMeta{Title: code}
}

// ReasonFor is a convenience accessor for the ISO 20022 reason code.
func ReasonFor(code string) string { return MetaFor(code).ISOReason }

// TxStatusForMark maps a treasury withdraw state-machine status to the ISO 20022
// transactionStatus reported on the success response (§13.3).
func TxStatusForMark(status string) string {
	switch status {
	case "ACKED":
		return TxStatusAcceptedTechnical
	case "DISBURSING":
		return TxStatusInProcess
	case "COMPLETED":
		return TxStatusSettled
	}
	return ""
}
