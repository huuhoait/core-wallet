package domain

import "github.com/google/uuid"

// TransferReversalInput reverses an in-book transfer by its original reference.
type TransferReversalInput struct {
	OrigReference string
	Reason        string
	Initiator     string // 'OPS_MANUAL' | 'FRAUD' | 'DISPUTE' | 'SYSTEM'
	Audit         AuditContext
}

// TransferReversalResult is what post_transfer_reversal returns.
type TransferReversalResult struct {
	ReversalTranKey     int64
	WasAlreadyReversed bool
	NewBalanceFrom     string // sender after refund
	NewBalanceTo       string // receiver after claw-back
	EventUUID          uuid.UUID
}

// TopupReversalInput reverses a topup by its original reference (claw back the
// credited funds from the wallet).
type TopupReversalInput struct {
	OrigReference string
	Reason        string
	Initiator     string // 'OPS_MANUAL' | 'FRAUD' | 'DISPUTE' | 'SYSTEM'
	Audit         AuditContext
}

// TopupReversalResult is what post_topup_reversal returns.
type TopupReversalResult struct {
	ReversalTranKey     int64
	WasAlreadyReversed bool
	NewBalance         string // wallet after claw-back
	EventUUID          uuid.UUID
}

// MerchantWithdrawReversalInput reverses a merchant settlement withdraw by its
// original reference (credit back principal + fee/VAT to the settlement).
type MerchantWithdrawReversalInput struct {
	OrigReference string
	FailCode      string // e.g. NAPAS_TIMEOUT, BENEF_CLOSED, OPS_MANUAL
	FailReason    string
	Initiator     string // 'OPS_MANUAL' | 'FRAUD' | 'DISPUTE' | 'SYSTEM'
	Audit         AuditContext
}

// MerchantWithdrawReversalResult is what post_merchant_withdraw_reversal returns.
type MerchantWithdrawReversalResult struct {
	ReversalTranKey        int64
	WasAlreadyReversed     bool
	SettlementBalanceAfter string // settlement balance after credit-back
	EventUUID              uuid.UUID
}
