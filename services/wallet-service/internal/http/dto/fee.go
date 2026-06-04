package dto

import "github.com/ewallet-pg/wallet-service/internal/domain"

// FeeChargeRequest — POST /v1/finance/fee-charge (US-2.8). Charges a standalone
// fee + VAT against a wallet. amount is the gross (VAT-inclusive) figure.
type FeeChargeRequest struct {
	AcctNo    string         `json:"acct_no"            binding:"required,acct_no"`
	Amount    string         `json:"amount"             binding:"required,money"`
	Reference string         `json:"reference"          binding:"required,min=8,max=64"`
	FeeCode   string         `json:"fee_code,omitempty" binding:"omitempty,min=2,max=16"`
	Narrative string         `json:"narrative,omitempty" binding:"omitempty,max=250"`
	Metadata  map[string]any `json:"metadata,omitempty"`
}

type FeeChargeResponse struct {
	TranInternalID int64  `json:"tran_internal_key,omitempty"`
	Status         string `json:"status"`
	FeeGross       string `json:"fee_gross"`
	VATAmount      string `json:"vat_amount"`
	NewBalance     string `json:"new_balance"`
	EventUUID      string `json:"event_uuid,omitempty"`
}

func FeeChargeRespFrom(r *domain.FeeChargeResult) FeeChargeResponse {
	out := FeeChargeResponse{
		TranInternalID: r.TranInternalID,
		Status:         r.Status,
		FeeGross:       r.FeeGross,
		VATAmount:      r.VATAmount,
		NewBalance:     r.NewBalance,
	}
	if r.EventUUID.String() != "00000000-0000-0000-0000-000000000000" {
		out.EventUUID = r.EventUUID.String()
	}
	return out
}

// FeeChargeReversalRequest — POST /v1/finance/fee-charge/reverse (US-2.8).
type FeeChargeReversalRequest struct {
	Reference string `json:"reference" binding:"required,min=8,max=64"`
	Reason    string `json:"reason"    binding:"required,min=3,max=500"`
	Initiator string `json:"initiator" binding:"omitempty,oneof=OPS_MANUAL FRAUD DISPUTE SYSTEM"`
}

type FeeChargeReversalResponse struct {
	ReversalTranKey    int64  `json:"reversal_tran_key"`
	WasAlreadyReversed bool   `json:"was_already_reversed"`
	NewBalance         string `json:"new_balance"`
	EventUUID          string `json:"event_uuid,omitempty"`
}

func FeeChargeReversalRespFrom(r *domain.FeeChargeReversalResult) FeeChargeReversalResponse {
	out := FeeChargeReversalResponse{
		ReversalTranKey:    r.ReversalTranKey,
		WasAlreadyReversed: r.WasAlreadyReversed,
		NewBalance:         r.NewBalance,
	}
	if r.EventUUID.String() != "00000000-0000-0000-0000-000000000000" {
		out.EventUUID = r.EventUUID.String()
	}
	return out
}
