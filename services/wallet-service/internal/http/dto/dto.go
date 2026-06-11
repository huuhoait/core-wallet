// Package dto defines request/response shapes for the HTTP layer.
// Each request uses go-playground/validator tags; the handler delegates
// validation to gin's binding+validation pipeline.
package dto

import (
	"net/http"
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
	AcctNo          string         `json:"acct_no"            binding:"required,acct_no"`
	Amount          string         `json:"amount"             binding:"required,money"`
	Reference       string         `json:"reference"          binding:"required,min=8,max=64"`
	ExtPayoutRef    string         `json:"ext_payout_ref"     binding:"required,min=8,max=64"`
	BeneficiaryBank string         `json:"beneficiary_bank"   binding:"required,min=3,max=20"`
	BeneficiaryAcct string         `json:"beneficiary_acct"   binding:"required,min=6,max=40"`
	Narrative       string         `json:"narrative,omitempty" binding:"omitempty,max=250"`
	Metadata        map[string]any `json:"metadata,omitempty"`
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
	ReversalTranKey    int64  `json:"reversal_tran_key"`
	WasAlreadyReversed bool   `json:"was_already_reversed"`
	EventUUID          string `json:"event_uuid,omitempty"`
}

func ReversalRespFrom(r *domain.ReversalResult) ReversalResponse {
	out := ReversalResponse{
		ReversalTranKey:    r.ReversalTranKey,
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
	Status int    `json:"-"`                                                            // HTTP status — kept on struct so abortProblem can call c.Status(p.Status); excluded from body (status lives in the HTTP header)
	Detail string `json:"detail,omitempty" example:"available 50000 < required 100000"` // human-readable detail (dynamic context)

	ErrorCode         string         `json:"errorCode" example:"E4022"`                                                    // SQLSTATE-style code: real pg SQLSTATE (P0060/40001/23505) for PG-raised, E#### synthetic for Go-side, "999999" when the canonical name is not whitelisted (§3.3)
	ErrorMessage      string         `json:"errorMessage" example:"INSUFFICIENT_FUNDS: available 50000 < required 100000"` // full raw "CODE: detail" message (pg.Message verbatim for PG errors, synthesized for Go); "Internal Error" when not whitelisted
	ISO20022Reason    string         `json:"iso20022_reason_code,omitempty" example:"AM04"`                                // ISO 20022 External Status Reason (§13.2)
	TransactionStatus string         `json:"transaction_status,omitempty" example:"RJCT"`                                  // pain.002 status (§13.3)
	Timestamp         string         `json:"timestamp,omitempty" example:"2026-06-06T07:30:00Z"`                           // RFC 3339
	Details           map[string]any `json:"details,omitempty"`
	Errors            []FieldError   `json:"errors,omitempty"` // field-level (Berlin Group / OBIE style)
}

// FieldError is one field-level validation failure.
type FieldError struct {
	Path    string `json:"path,omitempty"`
	Code    string `json:"code,omitempty"`
	Message string `json:"message,omitempty"`
}

// nowRFC3339 is overridable in tests.
var nowRFC3339 = func() string { return time.Now().Format(time.RFC3339) }

// FallbackErrorCode + FallbackErrorMessage are the safe defaults emitted when
// the canonical code is NOT in the client-safe whitelist (`domain.IsClientSafeCode`).
// They strip every internal hint (SQLSTATE, raw SP text, internal code, ISO
// reason, tx status) so unknown errors collapse to a uniform 500 envelope.
const (
	FallbackErrorCode    = "999999"
	FallbackErrorMessage = "Internal Error"
)

// SuccessErrorCode + SuccessErrorMessage are the uniform "success" markers
// returned at the top of every 2xx response envelope. "00000" mirrors the
// SQLSTATE for successful_completion, so the client always parses errorCode
// the same way regardless of outcome.
const (
	SuccessErrorCode    = "00000"
	SuccessErrorMessage = "Success!"
)

// SuccessEnvelope is the uniform 2xx response shape. The business payload
// lives under `data`; trace_id + timestamp mirror the error envelope so logs
// and clients can correlate either outcome the same way.
type SuccessEnvelope struct {
	ErrorCode    string `json:"errorCode"`
	ErrorMessage string `json:"errorMessage"`
	Data         any    `json:"data,omitempty"`
	Timestamp    string `json:"timestamp,omitempty"`
}

// Ok wraps the business response in the standard success envelope.
func Ok(data any, traceID string) SuccessEnvelope {
	return SuccessEnvelope{
		ErrorCode:    SuccessErrorCode,
		ErrorMessage: SuccessErrorMessage,
		Data:         data,
		Timestamp:    nowRFC3339(),
	}
}

// NewProblem builds a ProblemDetails from a canonical code + inline detail —
// used by middleware (JWT, RBAC, timeout, recovery) and validation paths where
// no rich *domain.Error is available. The values are synthesized:
//   - errorCode = MetaFor(code).InternalCode (E#### synthetic SQLSTATE)
//   - errorMessage = "code: detail"
//
// The whitelist gate still applies, so an unregistered code returns 999999.
func NewProblem(code string, status int, detail, instance, traceID string) ProblemDetails {
	return NewProblemFromError(&domain.Error{
		Code: code, HTTPStatus: status, Detail: detail,
		SQLState:   domain.MetaFor(code).InternalCode,
		RawMessage: rawMessageFor(code, detail),
	}, instance, traceID)
}

// NewProblemFromError builds a ProblemDetails from a rich *domain.Error,
// preserving the original SQLSTATE + full RAISE message when the error
// originated from PG. Used by handler.renderError for the main fast path.
//
// Whitelist gate (§3.3): when IsClientSafeCode(de.Code) is false the body
// collapses to {errorCode: "999999", errorMessage: "Internal Error"} with
// every internal field stripped — so unknown SP errors, raw pg failures, and
// panics never leak SQLSTATE / message text to the client. HTTP status (500
// in that case) is set on the struct for c.Status(...) only.
//
// The `instance` parameter is accepted for signature stability but no longer
// echoed in the body (the path is observable via the access log + trace_id).
func NewProblemFromError(de *domain.Error, instance, traceID string) ProblemDetails {
	_ = instance
	if !domain.IsClientSafeCode(de.Code) {
		return ProblemDetails{
			Status:       http.StatusInternalServerError,
			ErrorCode:    FallbackErrorCode,
			ErrorMessage: FallbackErrorMessage,
			Timestamp:    nowRFC3339(),
		}
	}
	m := domain.MetaFor(de.Code)
	sqlState := de.SQLState
	if sqlState == "" {
		sqlState = m.InternalCode
	}
	rawMessage := de.RawMessage
	if rawMessage == "" {
		rawMessage = rawMessageFor(de.Code, de.Detail)
	}
	return ProblemDetails{
		Status:            de.HTTPStatus,
		Detail:            de.Detail,
		ErrorCode:         sqlState,
		ErrorMessage:      rawMessage,
		ISO20022Reason:    m.ISOReason,
		TransactionStatus: m.TxStatus,
		Timestamp:         nowRFC3339(),
	}
}

func rawMessageFor(code, detail string) string {
	if detail == "" {
		return code
	}
	return code + ": " + detail
}
