package dto

import "github.com/ewallet-pg/wallet-service/internal/domain"

// TransferReversalRequest reverses an in-book transfer by its original reference.
type TransferReversalRequest struct {
	Reference string `json:"reference" binding:"required,min=8,max=64"`
	Reason    string `json:"reason"    binding:"required,min=3,max=500"`
	Initiator string `json:"initiator" binding:"omitempty,oneof=OPS_MANUAL FRAUD DISPUTE SYSTEM"`
}

type TransferReversalResponse struct {
	ReversalTranKey     int64  `json:"reversal_tran_key"`
	WasAlreadyReversed bool   `json:"was_already_reversed"`
	NewBalanceFrom     string `json:"new_balance_from"`
	NewBalanceTo       string `json:"new_balance_to"`
	EventUUID          string `json:"event_uuid,omitempty"`
}

func TransferReversalRespFrom(r *domain.TransferReversalResult) TransferReversalResponse {
	out := TransferReversalResponse{
		ReversalTranKey:     r.ReversalTranKey,
		WasAlreadyReversed: r.WasAlreadyReversed,
		NewBalanceFrom:     r.NewBalanceFrom,
		NewBalanceTo:       r.NewBalanceTo,
	}
	if r.EventUUID.String() != "00000000-0000-0000-0000-000000000000" {
		out.EventUUID = r.EventUUID.String()
	}
	return out
}

// TopupReversalRequest reverses a topup by its original reference.
type TopupReversalRequest struct {
	Reference string `json:"reference" binding:"required,min=8,max=64"`
	Reason    string `json:"reason"    binding:"required,min=3,max=500"`
	Initiator string `json:"initiator" binding:"omitempty,oneof=OPS_MANUAL FRAUD DISPUTE SYSTEM"`
}

type TopupReversalResponse struct {
	ReversalTranKey     int64  `json:"reversal_tran_key"`
	WasAlreadyReversed bool   `json:"was_already_reversed"`
	NewBalance         string `json:"new_balance"`
	EventUUID          string `json:"event_uuid,omitempty"`
}

func TopupReversalRespFrom(r *domain.TopupReversalResult) TopupReversalResponse {
	out := TopupReversalResponse{
		ReversalTranKey:     r.ReversalTranKey,
		WasAlreadyReversed: r.WasAlreadyReversed,
		NewBalance:         r.NewBalance,
	}
	if r.EventUUID.String() != "00000000-0000-0000-0000-000000000000" {
		out.EventUUID = r.EventUUID.String()
	}
	return out
}
