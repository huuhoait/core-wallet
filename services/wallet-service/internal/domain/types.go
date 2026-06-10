// Package domain holds business entities and value objects shared across
// usecases. It has zero dependencies on frameworks (no gin, no pgx).
package domain

import (
	"time"

	"github.com/google/uuid"
)

// Channel is the source channel of a transaction.
type Channel string

const (
	ChannelMobile   Channel = "MOBILE"
	ChannelOpsUI    Channel = "OPSUI"
	ChannelAPI      Channel = "API"
	ChannelTreasury Channel = "TREASURY"
	ChannelSys      Channel = "SYS"
	ChannelPartner  Channel = "PARTNER"
)

// AuditContext is the per-request context passed into every business call.
// Repository layer fans this out to the audit.* PG GUCs at TX start so the
// trg_audit_cols trigger and trg_audit_wlt_kyc trigger attribute changes.
type AuditContext struct {
	Actor       string  // user_id / system_id; required
	Channel     Channel // required
	RequestID   string  // correlation id
	TraceID     string  // bare W3C trace-id (32 hex) — for responses/logs/audit
	TraceParent string  // full W3C traceparent (00-trace-span-flags) — stamped into the outbox so the relay/consumer can continue the trace
	IPAddress   string  // optional, used by client-info audit log
	UserAgent   string  // optional
}

// PII access types (US-8.4) — the privileged unmasked-read endpoints whose
// disclosure of RAW client PII is recorded in WLT_PII_ACCESS_LOG. Values mirror
// the chk_pii_access_type CHECK in db/export/schema.sql.
const (
	PIIAccessClientProfile = "CLIENT_PROFILE" // GET /v1/ops/clients/:client_no
	PIIAccessClient360     = "CLIENT_360"     // GET /v1/ops/clients/:client_no/360
	PIIAccessClientList    = "CLIENT_LIST"    // GET /v1/ops/clients
	PIIAccessAccountSearch = "ACCOUNT_SEARCH" // GET /v1/ops/search
)

// PIIAccessEntry is one row appended to WLT_PII_ACCESS_LOG after a privileged
// unmasked read succeeds. ClientNo is empty for list/search; Detail carries
// non-PII context (counts, filters, query) and is marshalled to jsonb.
type PIIAccessEntry struct {
	AccessType string
	ClientNo   string
	Detail     map[string]any
	Audit      AuditContext
}

// Money is a non-negative amount in the smallest unit of the currency.
// For VND we keep 2 decimals server-side (matches WLT_ACCT.ACTUAL_BAL); the
// product treats VND as round-to-đồng at the display layer.
type Money struct {
	Amount   string // decimal string, e.g. "100000.00" — avoid float64 for money
	Currency string // ISO 4217, e.g. "VND"
}

// TopupResult is what post_topup SP returns.
type TopupResult struct {
	TranInternalID int64
	Status         string // "SUCCESS" | "DUPLICATE"
	NewBalance     string
	EventUUID      uuid.UUID
}

// TransferResult is what post_transfer SP returns.
type TransferResult struct {
	TranInternalID int64
	Status         string
	NewBalanceFrom string
	NewBalanceTo   string
	FeeGross       string
	VATAmount      string
	EventUUID      uuid.UUID
}

// WithdrawResult is what post_withdraw SP returns.
type WithdrawResult struct {
	TranInternalID int64
	Status         string
	NewBalance     string
	FeeGross       string
	VATAmount      string
	EventUUID      uuid.UUID
}

// ReversalResult is what post_withdraw_reversal SP returns.
type ReversalResult struct {
	ReversalTranKey    int64
	WasAlreadyReversed bool
	EventUUID          uuid.UUID
}

// MerchantWithdrawResult is what post_merchant_withdraw SP returns.
type MerchantWithdrawResult struct {
	TranInternalID         int64  // 0 when status is SETTLEMENT_SWEEP_REQUIRED (NULL in SP)
	Status                 string // "SUCCESS" | "DUPLICATE" | "SETTLEMENT_SWEEP_REQUIRED"
	Amount                 string
	FeeGross               string
	VATAmount              string
	TotalDeducted          string
	SettlementBalanceAfter string
	EventUUID              uuid.UUID // zero when status is SETTLEMENT_SWEEP_REQUIRED (NULL in SP)
}

// MarkResult is what mark_withdraw_* SPs return.
type MarkResult struct {
	AcctNo    string
	Status    string    // 'ACKED' | 'DISBURSING' | 'COMPLETED'
	EventUUID uuid.UUID // nil if state was already terminal (idempotent no-op)
}

// TopupInput is a request to credit a wallet from Treasury.
type TopupInput struct {
	AcctNo    string
	Amount    string // decimal string
	Reference string // idempotency key
	Narrative string // free-text memo from the request → WLT_TRAN_HIST.NARRATIVE
	Metadata  map[string]any
	Audit     AuditContext
}

// TransferInput is a wallet-to-wallet in-book transfer.
type TransferInput struct {
	FromAcctNo string
	ToAcctNo   string
	Amount     string
	Reference  string
	TranType   string // 'TRFOUT' (fee) | 'TRFOUTF' (free); empty → SP default 'TRFOUT'
	Narrative  string // free-text memo → WLT_TRAN_HIST.NARRATIVE
	Metadata   map[string]any
	Audit      AuditContext
}

// WithdrawInput is a withdraw to an external bank.
type WithdrawInput struct {
	AcctNo          string
	Amount          string
	Reference       string
	ExtPayoutRef    string
	BeneficiaryBank string
	BeneficiaryAcct string // plaintext; SP encrypts via pgcrypto + KMS DEK
	Narrative       string // free-text memo → WLT_TRAN_HIST.NARRATIVE
	Metadata        map[string]any
	Audit           AuditContext
}

// MerchantWithdrawInput withdraws from a merchant group's settlement account,
// auto-sweeping hot shards into settlement first when AutoSweep is true.
type MerchantWithdrawInput struct {
	GroupID      string
	Amount       string
	Reference    string // idempotency key
	ExtPayoutRef string // optional; empty → NULL
	AutoSweep    bool   // true → SP sweeps shards on settlement shortfall
	Audit        AuditContext
}

// ReversalInput is initiated by Treasury callback or SLA janitor.
type ReversalInput struct {
	ExtPayoutRef string
	FailCode     string
	FailReason   string
	Initiator    string // 'TREASURY_FAILED' | 'SLA_TIMEOUT' | 'OPS_MANUAL'
	Audit        AuditContext
}

// AckInput / DisbursingInput / CompletedInput drive the Treasury state machine.
type AckInput struct {
	ExtPayoutRef    string
	TreasuryBatchID string
	Audit           AuditContext
}

type DisbursingInput struct {
	ExtPayoutRef string
	Audit        AuditContext
}

type CompletedInput struct {
	ExtPayoutRef string
	NapasRef     string
	Audit        AuditContext
}

// TimeNow is injected via interface for testing — defaults to time.Now.
type TimeNow func() time.Time
