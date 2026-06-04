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
	Message      string // stable human-readable error message (i18n key source; safe for end-user display)
	InternalCode string // E#### for logs/alerts (error_management.md §5)
	ISOReason    string // ISO 20022 External Status Reason (§13.2); "" if none
	TxStatus     string // pain.002 transactionStatus for this error; "" if N/A
}

// codeMeta maps each canonical (implemented) error code to its standards
// metadata. Canonical names are the ones raised by the SPs / domain layer —
// docs follow code (decision 2026-05-30, §14.2). Crosswalk: §14.1.
//
// The Message field is the stable, user-safe message for each error code.
// It serves as the i18n key source and is always returned in the response
// envelope as `error_message`. The `detail` field provides dynamic context.
var codeMeta = map[string]CodeMeta{
	// ── Transaction posting ──
	CodeInvalidAmount:    {"Invalid amount", "The transaction amount is invalid or missing", "E4024", "AM12", TxStatusRejected},
	CodeAmountOutOfRange: {"Amount out of range", "The amount is outside the allowed range for this transaction type", "E4024", "AM02", TxStatusRejected},
	CodeMetadataTooLarge: {"Metadata too large", "The metadata payload exceeds the maximum allowed size (1 KB)", "E4007", "", TxStatusRejected},
	CodeMetadataHasP1:    {"Metadata contains restricted data", "The metadata contains forbidden PII keys (phone, email, cccd, passport, full_name, bank_acct_no)", "E4008", "", TxStatusRejected},
	CodeSameAccount:      {"Same account", "Source and destination accounts must be different", "E4002", "BE01", TxStatusRejected},
	CodeTranTypeInactive: {"Transaction type not active", "The requested transaction type is inactive or does not exist", "E4003", "AG02", TxStatusRejected},
	CodeAcctNotFound:     {"Account not found", "The specified account does not exist", "E3001", "AC01", TxStatusRejected},
	CodeAcctNotActive:    {"Account not active", "The account is blocked or closed and cannot process transactions", "E3004", "AC04", TxStatusRejected},
	CodeAcctRoleInvalid:  {"Account role invalid", "This operation is only allowed on standalone wallets, not SHARD or SETTLEMENT accounts", "E3008", "", TxStatusRejected},
	CodeBatchUnbalanced:  {"Batch unbalanced", "Internal double-entry invariant violated (sum of debits does not equal sum of credits)", "E5003", "", TxStatusRejected},
	CodeTierInsufficient: {"KYC tier insufficient", "Your KYC tier does not permit this operation; please upgrade your verification level", "E2007", "RR04", TxStatusRejected},
	CodeDRRestraintActive: {"Debit restraint active", "The account has an active debit restraint (hold/lien) preventing this withdrawal or transfer", "E3005", "AC06", TxStatusRejected},
	CodeCRRestraintActive: {"Credit restraint active", "The account has an active credit restraint preventing incoming funds", "E3006", "AC06", TxStatusRejected},
	CodeInsufficientFunds: {"Insufficient funds", "The account balance is not sufficient to cover this transaction", "E4022", "AM04", TxStatusRejected},
	CodeTierLimitExceeded: {"Transaction limit exceeded", "The transaction exceeds the daily or monthly limit for this account tier", "E4023", "AM02", TxStatusRejected},
	CodeVersionConflict:   {"Concurrent update conflict", "Another transaction updated this account simultaneously; the operation can be retried", "E4025", "", TxStatusPending},
	CodeDuplicateReference: {"Duplicate reference", "A transaction with this reference has already been processed", "E4011", "AM05", ""},

	// ── PII & encryption ──
	CodePIIDekNotSet: {"PII encryption key not configured", "The server PII data-encryption key (DEK) is not set; contact system administrator", "E5005", "", TxStatusPending},

	// ── Withdrawal disbursement ──
	CodeWDNotFound:         {"Withdrawal not found", "No withdrawal record found for the given payout reference", "E6101", "", ""},
	CodeWDAlreadyCompleted: {"Withdrawal already completed", "This withdrawal has already reached COMPLETED status", "E6102", "", ""},
	CodeWDInvalidState:     {"Withdrawal invalid state", "The withdrawal is in a state that does not permit this transition", "E6103", "", ""},
	CodeWDAlreadyReversed:  {"Withdrawal already reversed", "This withdrawal has already been reversed", "E6104", "", ""},

	// ── System / infra ──
	CodeInternal:     {"Internal error", "An unexpected error occurred; please retry or contact support", "E9001", "", TxStatusPending},
	CodeTimeout:      {"Request timed out", "The request exceeded the allowed processing time; you may retry", "E9004", "", TxStatusPending},
	CodeUnauthorized: {"Unauthorized", "Authentication is required or the provided credentials are invalid", "E1001", "", ""},
	CodeForbidden:    {"Forbidden", "You do not have permission to perform this operation", "E1006", "AG01", ""},
	CodeInvalidRequest: {"Invalid request", "The request body is malformed or missing required fields", "E4001", "", TxStatusRejected},

	// ── Balance & history ──
	CodeInvalidDate:       {"Invalid date", "The as_of_date parameter is invalid or refers to a future date", "E8003", "DT01", ""},
	CodeGoneOnline:        {"Data no longer available online", "Historical data beyond the online retention period; request an archive extract", "E8001", "", ""},
	CodeBatchSizeExceeded: {"Batch size exceeded", "The batch request exceeds the maximum number of items (100)", "E8004", "", ""},

	// ── EOD period locking ──
	CodePeriodClosed: {"Posting period is closed", "The target accounting date is sealed; post against the current open period", "E8005", "DT01", TxStatusRejected},

	// ── Restraint management (§4.9) ──
	CodeRestraintNotFound:            {"Restraint not found", "No restraint exists with the specified ID", "E3020", "", ""},
	CodeRestraintAlreadyRemoved:      {"Restraint already removed", "This restraint has already been released or expired", "E3021", "", ""},
	CodeRestraintTypeInvalid:         {"Invalid restraint type", "Restraint type must be one of: DEBIT, CREDIT, ALL, INFO", "E3022", "", ""},
	CodeRestraintPurposeInvalid:      {"Invalid restraint purpose", "Restraint purpose is not a recognized value", "E3023", "", ""},
	CodeRestraintTypePurposeConflict: {"Restraint type/purpose conflict", "The combination of restraint type and purpose is not allowed (e.g. COURT_ORDER must be ALL)", "E3024", "", ""},
	CodeRestraintAmtExceedsBalance:   {"Pledged amount exceeds balance", "The pledged amount cannot exceed the current account balance", "E3025", "AM04", ""},
	CodeRestraintDateInvalid:         {"Invalid restraint date range", "The end_date must be on or after the start_date", "E3026", "DT01", ""},
	CodeCourtOrderRemoveRequiresDoc:  {"Court order removal requires documentation", "Removing a COURT_ORDER or TAX_LIEN restraint requires a reference_doc", "E3027", "RR04", ""},

	// ── Client master CRUD ──
	CodeInvalidClientType:   {"Invalid client type", "Client type must be one of: IND, CORP, MER", "E2010", "", ""},
	CodeClientAlreadyExists: {"Client already exists", "A client with this identity document already exists", "E2009", "AM05", ""},
	CodeClientNotFound:      {"Client not found", "No client record found for the specified client number", "E2011", "", ""},

	// ── Onboarding (US-1.1/1.2/1.7) ──
	CodePhoneAlreadyRegistered: {"Phone already registered", "This phone number is already associated with an existing account", "E2002", "AM05", ""},
	CodeInvalidPhoneFormat:     {"Invalid phone format", "Phone number must match Vietnam format: 0XXXXXXXXX (10 digits)", "E2001", "", TxStatusRejected},
	CodeKycNotFound:            {"KYC record not found", "No KYC record exists for this client", "E2012", "", ""},
	CodeOrgFieldsRequired:      {"Organization fields required", "Corporate/merchant clients must provide business_reg_no and legal_rep in extra_data", "E2013", "", TxStatusRejected},

	// ── Client linked-bank ──
	CodeBankLinkNotFound: {"Bank link not found", "No linked bank account found with the specified ID", "E2014", "", ""},

	// ── Account (wallet) lifecycle ──
	CodeInvalidAcctType:     {"Invalid account type", "The specified account type does not exist in the system", "E3007", "", ""},
	CodeMaxWalletExceeded:   {"Wallet count limit exceeded", "You have reached the maximum number of wallets allowed (CONSUMER: 3 per currency, MERCHANT: 10)", "E3002", "", ""},
	CodeAcctCloseNonzeroBal: {"Cannot close account with balance", "Account closure requires a zero balance; transfer or withdraw all funds first", "E3003", "", ""},

	// ── Merchant hot-wallet group lifecycle ──
	CodeInvalidShardCount:     {"Invalid shard count", "Shard count must be 4, 8, or 16", "E3030", "", ""},
	CodeGroupAlreadyActivated: {"Group already activated", "This merchant group has already been activated with shards", "E3031", "", ""},
	CodeInvalidGroupType:      {"Invalid group type", "Group type must be one of: MERCHANT, AGENT, NOSTRO_HOT", "E3032", "", ""},
	CodeGroupAlreadyExists:    {"Group already exists", "A group with this ID already exists", "E3033", "AM05", ""},
	CodeGroupNotActivated:     {"Group not activated", "This group is still cold (0 shards); activate it before rescaling", "E3034", "", ""},
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
		return CodeMeta{Title: "Resource not found", Message: "The requested resource does not exist", ISOReason: "AC01", TxStatus: TxStatusRejected}
	case strings.HasSuffix(code, "_NOT_ACTIVE"):
		return CodeMeta{Title: "Resource not active", Message: "The resource is not in an active state", ISOReason: "AC04", TxStatus: TxStatusRejected}
	case strings.HasSuffix(code, "_RESTRAINT_ACTIVE"):
		return CodeMeta{Title: "Account restrained", Message: "The account has an active restraint preventing this operation", ISOReason: "AC06", TxStatus: TxStatusRejected}
	}
	return CodeMeta{Title: code, Message: code}
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
