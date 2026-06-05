package domain

import "github.com/google/uuid"

// FeeChargeInput charges a STANDALONE fee + VAT against a wallet (annual /
// penalty / service fee) with no principal money movement (post_fee_charge SP,
// US-2.8). Amount is the gross, VAT-inclusive figure.
type FeeChargeInput struct {
	AcctNo    string
	Amount    string // gross (VAT-inclusive) decimal string
	Reference string // idempotency key
	FeeCode   string // tran-def supplying VAT rate + revenue GL; empty → 'FEECHG'
	Narrative string
	Metadata  map[string]any
	Audit     AuditContext
}

// FeeChargeResult is what post_fee_charge returns.
type FeeChargeResult struct {
	TranInternalID int64
	Status         string // "Success" | "DUPLICATE"
	FeeGross       string
	VATAmount      string
	NewBalance     string
	EventUUID      uuid.UUID
}

// FeeChargeReversalInput reverses a standalone fee charge by its original
// reference (post_fee_charge_reversal SP) — refunds the gross + flips revenue/VAT.
type FeeChargeReversalInput struct {
	OrigReference string
	Reason        string
	Initiator     string // 'OPS_MANUAL' | 'FRAUD' | 'DISPUTE' | 'SYSTEM'
	Audit         AuditContext
}

// FeeChargeReversalResult is what post_fee_charge_reversal returns.
type FeeChargeReversalResult struct {
	ReversalTranKey    int64
	WasAlreadyReversed bool
	NewBalance         string // wallet after refund
	EventUUID          uuid.UUID
}
