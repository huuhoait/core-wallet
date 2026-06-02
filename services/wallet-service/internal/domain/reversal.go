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
