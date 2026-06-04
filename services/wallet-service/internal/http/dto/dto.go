// Package dto defines request/response shapes for the HTTP layer.
// Each request uses go-playground/validator tags; the handler delegates
// validation to gin's binding+validation pipeline.
package dto

import (
	"time"

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
	TranInternalID    int64  `json:"tran_internal_key"`
	Status            string `json:"status"`
	TransactionStatus string `json:"transaction_status,omitempty"` // ISO 20022 (§13.3)
	NewBalance        string `json:"new_balance"`
	EventUUID         string `json:"event_uuid"`
}

func TopupRespFrom(r *domain.TopupResult) TopupResponse {
	return TopupResponse{
		TranInternalID:    r.TranInternalID,
		Status:            r.Status,
		TransactionStatus: domain.TxStatusSettled, // internal credit settles immediately
		NewBalance:        r.NewBalance,
		EventUUID:         r.EventUUID.String(),
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
	TranInternalID    int64  `json:"tran_internal_key"`
	Status            string `json:"status"`
	TransactionStatus string `json:"transaction_status,omitempty"` // ISO 20022 (§13.3)
	NewBalanceFrom    string `json:"new_balance_from"`
	NewBalanceTo      string `json:"new_balance_to"`
	FeeGross          string `json:"fee_gross"`
	VATAmount         string `json:"vat_amount"`
	EventUUID         string `json:"event_uuid"`
}

func TransferRespFrom(r *domain.TransferResult) TransferResponse {
	return TransferResponse{
		TranInternalID:    r.TranInternalID,
		Status:            r.Status,
		TransactionStatus: domain.TxStatusSettled, // in-book transfer settles immediately
		NewBalanceFrom:    r.NewBalanceFrom,
		NewBalanceTo:      r.NewBalanceTo,
		FeeGross:          r.FeeGross,
		VATAmount:         r.VATAmount,
		EventUUID:         r.EventUUID.String(),
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
	TranInternalID    int64  `json:"tran_internal_key"`
	Status            string `json:"status"`
	TransactionStatus string `json:"transaction_status,omitempty"` // ISO 20022 (§13.3)
	NewBalance        string `json:"new_balance"`
	FeeGross          string `json:"fee_gross"`
	VATAmount         string `json:"vat_amount"`
	EventUUID         string `json:"event_uuid"`
}

func WithdrawRespFrom(r *domain.WithdrawResult) WithdrawResponse {
	return WithdrawResponse{
		TranInternalID: r.TranInternalID,
		Status:         r.Status,
		// Ledger committed; external disbursement still pending (Treasury). The
		// status advances via the treasury state machine (ACSP → ACSC).
		TransactionStatus: domain.TxStatusAcceptedTechnical,
		NewBalance:        r.NewBalance,
		FeeGross:          r.FeeGross,
		VATAmount:         r.VATAmount,
		EventUUID:         r.EventUUID.String(),
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
	TranInternalID         int64  `json:"tran_internal_key,omitempty"`
	Status                 string `json:"status"`
	TransactionStatus      string `json:"transaction_status,omitempty"` // ISO 20022 (§13.3)
	Amount                 string `json:"amount"`
	FeeGross               string `json:"fee_gross"`
	VATAmount              string `json:"vat_amount"`
	TotalDeducted          string `json:"total_deducted"`
	SettlementBalanceAfter string `json:"settlement_balance_after"`
	EventUUID              string `json:"event_uuid,omitempty"`
}

func MerchantWithdrawRespFrom(r *domain.MerchantWithdrawResult) MerchantWithdrawResponse {
	out := MerchantWithdrawResponse{
		TranInternalID:         r.TranInternalID,
		Status:                 r.Status,
		TransactionStatus:      domain.TxStatusAcceptedTechnical, // disbursement pending (Treasury)
		Amount:                 r.Amount,
		FeeGross:               r.FeeGross,
		VATAmount:              r.VATAmount,
		TotalDeducted:          r.TotalDeducted,
		SettlementBalanceAfter: r.SettlementBalanceAfter,
	}
	if r.Status == "SETTLEMENT_SWEEP_REQUIRED" {
		out.TransactionStatus = domain.TxStatusPending // caller must sweep shards first
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
	AcctNo            string `json:"acct_no"`
	Status            string `json:"status"`
	TransactionStatus string `json:"transaction_status,omitempty"` // ISO 20022 (§13.3)
	EventUUID         string `json:"event_uuid,omitempty"`
}

func MarkRespFrom(r *domain.MarkResult) MarkResponse {
	out := MarkResponse{
		AcctNo:            r.AcctNo,
		Status:            r.Status,
		TransactionStatus: domain.TxStatusForMark(r.Status),
	}
	if r.EventUUID.String() != "00000000-0000-0000-0000-000000000000" {
		out.EventUUID = r.EventUUID.String()
	}
	return out
}

type ReversalResponse struct {
	ReversalTranKey     int64  `json:"reversal_tran_key"`
	WasAlreadyReversed bool   `json:"was_already_reversed"`
	EventUUID          string `json:"event_uuid,omitempty"`
}

func ReversalRespFrom(r *domain.ReversalResult) ReversalResponse {
	out := ReversalResponse{
		ReversalTranKey:     r.ReversalTranKey,
		WasAlreadyReversed: r.WasAlreadyReversed,
	}
	if r.EventUUID.String() != "00000000-0000-0000-0000-000000000000" {
		out.EventUUID = r.EventUUID.String()
	}
	return out
}

// ----- error envelope (RFC 7807 / RFC 9457 + bank extensions, §13.5) ---------

// ProblemTypeBase is the documentation base for the RFC 7807 `type` URI.
// Placeholder host — point it at the real error-docs site when published.
const ProblemTypeBase = "https://docs.wallet.example/errors/"

// ProblemDetails is the canonical error body, served as
// `application/problem+json`. The first five fields are RFC 7807; the rest are
// bank extensions documented in error_management.md §3 / §13.
type ProblemDetails struct {
	Type     string `json:"type,omitempty"`     // RFC7807: URI to error doc
	Title    string `json:"title"`              // RFC7807: short human title
	Status   int    `json:"status"`             // RFC7807: HTTP status code
	Detail   string `json:"detail,omitempty"`   // RFC7807: human-readable detail (dynamic context)
	Instance string `json:"instance,omitempty"` // RFC7807: request path

	ErrorCode         string         `json:"errorCode"`                      // stable business error code (canonical contract)
	ErrorMessage      string         `json:"errorMessage"`                   // stable human message for this code (i18n source, safe for end-user)
	InternalCode      string         `json:"internal_code,omitempty"`        // E#### for log/alert (§5)
	ISO20022Reason    string         `json:"iso20022_reason_code,omitempty"` // ISO 20022 External Status Reason (§13.2)
	TransactionStatus string         `json:"transaction_status,omitempty"`   // pain.002 status (§13.3)
	TraceID           string         `json:"trace_id,omitempty"`             // = X-Request-Id
	Timestamp         string         `json:"timestamp,omitempty"`            // RFC 3339
	Retry             *RetryInfo     `json:"retry,omitempty"`
	Details           map[string]any `json:"details,omitempty"`
	Errors            []FieldError   `json:"errors,omitempty"` // field-level (Berlin Group / OBIE style)
}

// RetryInfo tells the caller whether/when a retry is permitted.
type RetryInfo struct {
	Retryable bool   `json:"retryable"`
	AfterMs   *int64 `json:"after_ms"`
}

// FieldError is one field-level validation failure.
type FieldError struct {
	Path    string `json:"path,omitempty"`
	Code    string `json:"code,omitempty"`
	Message string `json:"message,omitempty"`
}

// nowRFC3339 is overridable in tests.
var nowRFC3339 = func() string { return time.Now().Format(time.RFC3339) }

// NewProblem builds a ProblemDetails from a canonical code, enriching it from
// the domain standards registry (title, internal code, ISO 20022 reason, tx
// status). Used by both the handler and middleware so the envelope is uniform.
func NewProblem(code string, status int, detail, instance, traceID string) ProblemDetails {
	m := domain.MetaFor(code)
	title := m.Title
	if title == "" {
		title = code
	}
	errorMessage := m.Message
	if errorMessage == "" {
		errorMessage = title
	}
	return ProblemDetails{
		Type:              ProblemTypeBase + code,
		Title:             title,
		Status:            status,
		Detail:            detail,
		Instance:          instance,
		ErrorCode:         code,
		ErrorMessage:      errorMessage,
		InternalCode:      m.InternalCode,
		ISO20022Reason:    m.ISOReason,
		TransactionStatus: m.TxStatus,
		TraceID:           traceID,
		Timestamp:         nowRFC3339(),
	}
}
