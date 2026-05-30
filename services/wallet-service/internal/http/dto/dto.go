// Package dto defines request/response shapes for the HTTP layer.
// Each request uses go-playground/validator tags; the handler delegates
// validation to gin's binding+validation pipeline.
package dto

import (
	"github.com/ewallet-pg/wallet-service/internal/domain"
)

// ----- topup ----------------------------------------------------------------

type TopupRequest struct {
	AcctNo    string         `json:"acct_no"   binding:"required,acct_no"`
	Amount    string         `json:"amount"    binding:"required,money"`
	Reference string         `json:"reference" binding:"required,min=8,max=64"`
	Narrative string         `json:"narrative,omitempty" binding:"omitempty,max=250"`
	Metadata  map[string]any `json:"metadata,omitempty"`
}

type TopupResponse struct {
	TFRInternalKey int64  `json:"tfr_internal_key"`
	Status         string `json:"status"`
	NewBalance     string `json:"new_balance"`
	EventUUID      string `json:"event_uuid"`
}

func TopupRespFrom(r *domain.TopupResult) TopupResponse {
	return TopupResponse{
		TFRInternalKey: r.TFRInternalKey,
		Status:         r.Status,
		NewBalance:     r.NewBalance,
		EventUUID:      r.EventUUID.String(),
	}
}

// ----- transfer -------------------------------------------------------------

type TransferRequest struct {
	FromAcctNo string         `json:"from_acct_no" binding:"required,acct_no"`
	ToAcctNo   string         `json:"to_acct_no"   binding:"required,acct_no,nefield=FromAcctNo"`
	Amount     string         `json:"amount"       binding:"required,money"`
	Reference  string         `json:"reference"    binding:"required,min=8,max=64"`
	TranType   string         `json:"tran_type,omitempty" binding:"omitempty,oneof=TRFOUT TRFOUTF"`
	Narrative  string         `json:"narrative,omitempty" binding:"omitempty,max=250"`
	Metadata   map[string]any `json:"metadata,omitempty"`
}

type TransferResponse struct {
	TFRInternalKey int64  `json:"tfr_internal_key"`
	Status         string `json:"status"`
	NewBalanceFrom string `json:"new_balance_from"`
	NewBalanceTo   string `json:"new_balance_to"`
	FeeGross       string `json:"fee_gross"`
	VATAmount      string `json:"vat_amount"`
	EventUUID      string `json:"event_uuid"`
}

func TransferRespFrom(r *domain.TransferResult) TransferResponse {
	return TransferResponse{
		TFRInternalKey: r.TFRInternalKey,
		Status:         r.Status,
		NewBalanceFrom: r.NewBalanceFrom,
		NewBalanceTo:   r.NewBalanceTo,
		FeeGross:       r.FeeGross,
		VATAmount:      r.VATAmount,
		EventUUID:      r.EventUUID.String(),
	}
}

// ----- withdraw -------------------------------------------------------------

type WithdrawRequest struct {
	AcctNo           string         `json:"acct_no"            binding:"required,acct_no"`
	Amount           string         `json:"amount"             binding:"required,money"`
	Reference        string         `json:"reference"          binding:"required,min=8,max=64"`
	ExtPayoutRef     string         `json:"ext_payout_ref"     binding:"required,min=8,max=64"`
	BeneficiaryBank  string         `json:"beneficiary_bank"   binding:"required,min=3,max=20"`
	BeneficiaryAcct  string         `json:"beneficiary_acct"   binding:"required,min=6,max=40"`
	Narrative        string         `json:"narrative,omitempty" binding:"omitempty,max=250"`
	Metadata         map[string]any `json:"metadata,omitempty"`
}

type WithdrawResponse struct {
	TFRInternalKey int64  `json:"tfr_internal_key"`
	Status         string `json:"status"`
	NewBalance     string `json:"new_balance"`
	FeeGross       string `json:"fee_gross"`
	VATAmount      string `json:"vat_amount"`
	EventUUID      string `json:"event_uuid"`
}

func WithdrawRespFrom(r *domain.WithdrawResult) WithdrawResponse {
	return WithdrawResponse{
		TFRInternalKey: r.TFRInternalKey,
		Status:         r.Status,
		NewBalance:     r.NewBalance,
		FeeGross:       r.FeeGross,
		VATAmount:      r.VATAmount,
		EventUUID:      r.EventUUID.String(),
	}
}

// ----- merchant withdraw ----------------------------------------------------

type MerchantWithdrawRequest struct {
	GroupID      string `json:"group_id"                 binding:"required,min=2,max=32"`
	Amount       string `json:"amount"                   binding:"required,money"`
	Reference    string `json:"reference"                binding:"required,min=8,max=64"`
	ExtPayoutRef string `json:"ext_payout_ref,omitempty" binding:"omitempty,min=8,max=64"`
	// AutoSweep defaults to true (pointer distinguishes "omitted" from "false").
	AutoSweep *bool `json:"auto_sweep,omitempty"`
}

type MerchantWithdrawResponse struct {
	TFRInternalKey         int64  `json:"tfr_internal_key,omitempty"`
	Status                 string `json:"status"`
	Amount                 string `json:"amount"`
	FeeGross               string `json:"fee_gross"`
	VATAmount              string `json:"vat_amount"`
	TotalDeducted          string `json:"total_deducted"`
	SettlementBalanceAfter string `json:"settlement_balance_after"`
	EventUUID              string `json:"event_uuid,omitempty"`
}

func MerchantWithdrawRespFrom(r *domain.MerchantWithdrawResult) MerchantWithdrawResponse {
	out := MerchantWithdrawResponse{
		TFRInternalKey:         r.TFRInternalKey,
		Status:                 r.Status,
		Amount:                 r.Amount,
		FeeGross:               r.FeeGross,
		VATAmount:              r.VATAmount,
		TotalDeducted:          r.TotalDeducted,
		SettlementBalanceAfter: r.SettlementBalanceAfter,
	}
	if r.EventUUID.String() != "00000000-0000-0000-0000-000000000000" {
		out.EventUUID = r.EventUUID.String()
	}
	return out
}

// ----- treasury callbacks ---------------------------------------------------

type AckRequest struct {
	TreasuryBatchID string `json:"treasury_batch_id" binding:"required,min=4,max=64"`
}

type CompletedRequest struct {
	NapasRef string `json:"napas_ref" binding:"required,min=4,max=64"`
}

type ReversalRequest struct {
	FailCode   string `json:"fail_code"   binding:"required,oneof=NAPAS_INSUFFICIENT_FUNDS BENEF_CLOSED NAPAS_TIMEOUT SLA_TIMEOUT OPS_MANUAL UNKNOWN"`
	FailReason string `json:"fail_reason" binding:"required,min=4,max=500"`
	Initiator  string `json:"initiator"   binding:"required,oneof=TREASURY_FAILED SLA_TIMEOUT OPS_MANUAL"`
}

type MarkResponse struct {
	AcctNo    string `json:"acct_no"`
	Status    string `json:"status"`
	EventUUID string `json:"event_uuid,omitempty"`
}

func MarkRespFrom(r *domain.MarkResult) MarkResponse {
	out := MarkResponse{AcctNo: r.AcctNo, Status: r.Status}
	if r.EventUUID.String() != "00000000-0000-0000-0000-000000000000" {
		out.EventUUID = r.EventUUID.String()
	}
	return out
}

type ReversalResponse struct {
	ReversalTFRKey     int64  `json:"reversal_tfr_key"`
	WasAlreadyReversed bool   `json:"was_already_reversed"`
	EventUUID          string `json:"event_uuid,omitempty"`
}

func ReversalRespFrom(r *domain.ReversalResult) ReversalResponse {
	out := ReversalResponse{
		ReversalTFRKey:     r.ReversalTFRKey,
		WasAlreadyReversed: r.WasAlreadyReversed,
	}
	if r.EventUUID.String() != "00000000-0000-0000-0000-000000000000" {
		out.EventUUID = r.EventUUID.String()
	}
	return out
}

// ----- error envelope -------------------------------------------------------

type ErrorResponse struct {
	Code      string         `json:"code"`
	Message   string         `json:"message"`
	RequestID string         `json:"request_id,omitempty"`
	Details   map[string]any `json:"details,omitempty"`
}
