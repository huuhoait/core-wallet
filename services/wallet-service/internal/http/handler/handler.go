// Package handler holds gin HTTP handlers. Each handler binds + validates
// the request DTO, calls the usecase, and renders the response (or maps a
// *domain.Error into the canonical error envelope).
package handler

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"

	"github.com/gin-gonic/gin"
	"github.com/go-playground/validator/v10"

	"github.com/ewallet-pg/wallet-service/internal/domain"
	"github.com/ewallet-pg/wallet-service/internal/http/dto"
	"github.com/ewallet-pg/wallet-service/internal/http/middleware"
	"github.com/ewallet-pg/wallet-service/internal/usecase"
)

type Wallet struct {
	svc *usecase.WalletService
}

func New(svc *usecase.WalletService) *Wallet { return &Wallet{svc: svc} }

// Topup godoc
//
//	@Summary		Top up a wallet
//	@Description	Internal credit to a wallet; settles immediately. Idempotent on `reference` — a duplicate returns 200 with the original result.
//	@Tags			finance
//	@Accept			json
//	@Produce		json
//	@Param			request	body		dto.TopupRequest	true	"Top-up request"
//	@Success		201		{object}	dto.SuccessEnvelope{data=dto.TopupResponse}	"Posted"
//	@Success		200		{object}	dto.SuccessEnvelope{data=dto.TopupResponse}	"Duplicate idempotent replay"
//	@Failure		400		{object}	dto.ProblemDetails	"Validation error"
//	@Failure		422		{object}	dto.ProblemDetails	"Business rule violation"
//	@Failure		500		{object}	dto.ProblemDetails	"Internal error"
//	@Router			/v1/finance/topup [post]
func (h *Wallet) Topup(c *gin.Context) {
	var req dto.TopupRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		renderValidationError(c, err)
		return
	}
	res, err := h.svc.Topup(c.Request.Context(), domain.TopupInput{
		AcctNo:    req.AcctNo,
		Amount:    req.Amount,
		Reference: req.Reference,
		Narrative: req.Narrative,
		Metadata:  req.Metadata,
		Audit:     middleware.FromGin(c),
	})
	if err != nil {
		renderError(c, err)
		return
	}
	writeOK(c, statusFor(res.Status), dto.TopupRespFrom(res))
}

// Transfer godoc
//
//	@Summary		Transfer between wallets
//	@Description	In-book transfer (settles immediately, fee/VAT applied). Idempotent on `reference` — a duplicate returns 200.
//	@Tags			finance
//	@Accept			json
//	@Produce		json
//	@Param			request	body		dto.TransferRequest		true	"Transfer request"
//	@Success		201		{object}	dto.SuccessEnvelope{data=dto.TransferResponse}	"Posted"
//	@Success		200		{object}	dto.SuccessEnvelope{data=dto.TransferResponse}	"Duplicate idempotent replay"
//	@Failure		400		{object}	dto.ProblemDetails		"Validation error"
//	@Failure		409		{object}	dto.ProblemDetails		"Concurrency conflict (retryable)"
//	@Failure		422		{object}	dto.ProblemDetails		"Business rule violation (e.g. insufficient funds)"
//	@Failure		500		{object}	dto.ProblemDetails		"Internal error"
//	@Router			/v1/finance/transfer [post]
func (h *Wallet) Transfer(c *gin.Context) {
	var req dto.TransferRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		renderValidationError(c, err)
		return
	}
	res, err := h.svc.Transfer(c.Request.Context(), domain.TransferInput{
		FromAcctNo: req.FromAcctNo,
		ToAcctNo:   req.ToAcctNo,
		Amount:     req.Amount,
		Reference:  req.Reference,
		TranType:   req.TranType,
		Narrative:  req.Narrative,
		Metadata:   req.Metadata,
		Audit:      middleware.FromGin(c),
	})
	if err != nil {
		renderError(c, err)
		return
	}
	writeOK(c, statusFor(res.Status), dto.TransferRespFrom(res))
}

// Withdraw godoc
//
//	@Summary		Withdraw from a wallet
//	@Description	Debit a wallet for external disbursement. Ledger commits immediately; disbursement is then driven by the Treasury state machine. Idempotent on `reference`.
//	@Tags			finance
//	@Accept			json
//	@Produce		json
//	@Param			request	body		dto.WithdrawRequest		true	"Withdraw request"
//	@Success		201		{object}	dto.SuccessEnvelope{data=dto.WithdrawResponse}	"Posted"
//	@Success		200		{object}	dto.SuccessEnvelope{data=dto.WithdrawResponse}	"Duplicate idempotent replay"
//	@Failure		400		{object}	dto.ProblemDetails		"Validation error"
//	@Failure		409		{object}	dto.ProblemDetails		"Concurrency conflict (retryable)"
//	@Failure		422		{object}	dto.ProblemDetails		"Business rule violation (e.g. insufficient funds)"
//	@Failure		500		{object}	dto.ProblemDetails		"Internal error"
//	@Router			/v1/finance/withdraw [post]
func (h *Wallet) Withdraw(c *gin.Context) {
	var req dto.WithdrawRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		renderValidationError(c, err)
		return
	}
	res, err := h.svc.Withdraw(c.Request.Context(), domain.WithdrawInput{
		AcctNo:          req.AcctNo,
		Amount:          req.Amount,
		Reference:       req.Reference,
		ExtPayoutRef:    req.ExtPayoutRef,
		BeneficiaryBank: req.BeneficiaryBank,
		BeneficiaryAcct: req.BeneficiaryAcct,
		Narrative:       req.Narrative,
		Metadata:        req.Metadata,
		Audit:           middleware.FromGin(c),
	})
	if err != nil {
		renderError(c, err)
		return
	}
	writeOK(c, statusFor(res.Status), dto.WithdrawRespFrom(res))
}

// MerchantWithdraw godoc
//
//	@Summary		Merchant settlement withdraw
//	@Description	Withdraw from a merchant group settlement account, sweeping hot shards first when `auto_sweep` is true (default).
//	@Tags			finance
//	@Accept			json
//	@Produce		json
//	@Param			request	body		dto.MerchantWithdrawRequest		true	"Merchant withdraw request"
//	@Success		201		{object}	dto.SuccessEnvelope{data=dto.MerchantWithdrawResponse}	"Posted"
//	@Success		200		{object}	dto.SuccessEnvelope{data=dto.MerchantWithdrawResponse}	"Duplicate idempotent replay"
//	@Failure		400		{object}	dto.ProblemDetails				"Validation error"
//	@Failure		409		{object}	dto.ProblemDetails				"Concurrency conflict (retryable)"
//	@Failure		422		{object}	dto.ProblemDetails				"Business rule violation"
//	@Failure		500		{object}	dto.ProblemDetails				"Internal error"
//	@Router			/v1/finance/merchant-withdraw [post]
func (h *Wallet) MerchantWithdraw(c *gin.Context) {
	var req dto.MerchantWithdrawRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		renderValidationError(c, err)
		return
	}
	autoSweep := true // default when omitted
	if req.AutoSweep != nil {
		autoSweep = *req.AutoSweep
	}
	res, err := h.svc.MerchantWithdraw(c.Request.Context(), domain.MerchantWithdrawInput{
		GroupID:      req.GroupID,
		Amount:       req.Amount,
		Reference:    req.Reference,
		ExtPayoutRef: req.ExtPayoutRef,
		AutoSweep:    autoSweep,
		Audit:        middleware.FromGin(c),
	})
	if err != nil {
		renderError(c, err)
		return
	}
	writeOK(c, statusFor(res.Status), dto.MerchantWithdrawRespFrom(res))
}

// MarkAcked godoc
//
//	@Summary		Treasury: mark withdrawal acknowledged
//	@Description	S2S callback — Treasury accepted the payout into a batch.
//	@Tags			treasury
//	@Accept			json
//	@Produce		json
//	@Param			ext_payout_ref	path		string				true	"External payout reference"
//	@Param			request			body		dto.AckRequest		true	"Ack payload"
//	@Success		200				{object}	dto.SuccessEnvelope{data=dto.MarkResponse}	"OK"
//	@Failure		400				{object}	dto.ProblemDetails	"Validation error"
//	@Failure		404				{object}	dto.ProblemDetails	"Unknown payout reference"
//	@Failure		422				{object}	dto.ProblemDetails	"Illegal state transition"
//	@Failure		500				{object}	dto.ProblemDetails	"Internal error"
//	@Router			/v1/treasury/withdrawals/{ext_payout_ref}/acked [post]
func (h *Wallet) MarkAcked(c *gin.Context) {
	ref := c.Param("ext_payout_ref")
	var req dto.AckRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		renderValidationError(c, err)
		return
	}
	res, err := h.svc.MarkAcked(c.Request.Context(), domain.AckInput{
		ExtPayoutRef:    ref,
		TreasuryBatchID: req.TreasuryBatchID,
		Audit:           middleware.FromGin(c),
	})
	if err != nil {
		renderError(c, err)
		return
	}
	writeOK(c, http.StatusOK, dto.MarkRespFrom(res))
}

// MarkDisbursing godoc
//
//	@Summary		Treasury: mark withdrawal disbursing
//	@Description	S2S callback — Treasury has submitted the payout to the rail.
//	@Tags			treasury
//	@Produce		json
//	@Param			ext_payout_ref	path		string				true	"External payout reference"
//	@Success		200				{object}	dto.SuccessEnvelope{data=dto.MarkResponse}	"OK"
//	@Failure		404				{object}	dto.ProblemDetails	"Unknown payout reference"
//	@Failure		422				{object}	dto.ProblemDetails	"Illegal state transition"
//	@Failure		500				{object}	dto.ProblemDetails	"Internal error"
//	@Router			/v1/treasury/withdrawals/{ext_payout_ref}/disbursing [post]
func (h *Wallet) MarkDisbursing(c *gin.Context) {
	res, err := h.svc.MarkDisbursing(c.Request.Context(), domain.DisbursingInput{
		ExtPayoutRef: c.Param("ext_payout_ref"),
		Audit:        middleware.FromGin(c),
	})
	if err != nil {
		renderError(c, err)
		return
	}
	writeOK(c, http.StatusOK, dto.MarkRespFrom(res))
}

// MarkCompleted godoc
//
//	@Summary		Treasury: mark withdrawal completed
//	@Description	S2S callback — payout settled at the rail (NAPAS ref captured).
//	@Tags			treasury
//	@Accept			json
//	@Produce		json
//	@Param			ext_payout_ref	path		string					true	"External payout reference"
//	@Param			request			body		dto.CompletedRequest	true	"Completion payload"
//	@Success		200				{object}	dto.SuccessEnvelope{data=dto.MarkResponse}		"OK"
//	@Failure		400				{object}	dto.ProblemDetails		"Validation error"
//	@Failure		404				{object}	dto.ProblemDetails		"Unknown payout reference"
//	@Failure		422				{object}	dto.ProblemDetails		"Illegal state transition"
//	@Failure		500				{object}	dto.ProblemDetails		"Internal error"
//	@Router			/v1/treasury/withdrawals/{ext_payout_ref}/completed [post]
func (h *Wallet) MarkCompleted(c *gin.Context) {
	ref := c.Param("ext_payout_ref")
	var req dto.CompletedRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		renderValidationError(c, err)
		return
	}
	res, err := h.svc.MarkCompleted(c.Request.Context(), domain.CompletedInput{
		ExtPayoutRef: ref,
		NapasRef:     req.NapasRef,
		Audit:        middleware.FromGin(c),
	})
	if err != nil {
		renderError(c, err)
		return
	}
	writeOK(c, http.StatusOK, dto.MarkRespFrom(res))
}

// Reverse godoc
//
//	@Summary		Treasury: reverse a failed withdrawal
//	@Description	S2S callback — payout failed/timed out; reverse the ledger debit. Idempotent (re-reversal returns was_already_reversed=true).
//	@Tags			treasury
//	@Accept			json
//	@Produce		json
//	@Param			ext_payout_ref	path		string					true	"External payout reference"
//	@Param			request			body		dto.ReversalRequest		true	"Reversal payload"
//	@Success		200				{object}	dto.SuccessEnvelope{data=dto.ReversalResponse}	"OK"
//	@Failure		400				{object}	dto.ProblemDetails		"Validation error"
//	@Failure		404				{object}	dto.ProblemDetails		"Unknown payout reference"
//	@Failure		422				{object}	dto.ProblemDetails		"Illegal state transition"
//	@Failure		500				{object}	dto.ProblemDetails		"Internal error"
//	@Router			/v1/treasury/withdrawals/{ext_payout_ref}/reverse [post]
func (h *Wallet) Reverse(c *gin.Context) {
	ref := c.Param("ext_payout_ref")
	var req dto.ReversalRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		renderValidationError(c, err)
		return
	}
	res, err := h.svc.Reverse(c.Request.Context(), domain.ReversalInput{
		ExtPayoutRef: ref,
		FailCode:     req.FailCode,
		FailReason:   req.FailReason,
		Initiator:    req.Initiator,
		Audit:        middleware.FromGin(c),
	})
	if err != nil {
		renderError(c, err)
		return
	}
	writeOK(c, http.StatusOK, dto.ReversalRespFrom(res))
}

// Healthz godoc
//
//	@Summary		Health check
//	@Description	Cheap liveness probe (no DB round-trip).
//	@Tags			health
//	@Produce		json
//	@Success		200	{object}	map[string]string	"status: ok"
//	@Router			/healthz [get]
func (h *Wallet) Healthz(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{"status": "ok"})
}

// ---- helpers --------------------------------------------------------------

// renderValidationError emits a 400 problem+json with field-level details.
func renderValidationError(c *gin.Context, err error) {
	p := dto.NewProblem(
		domain.CodeInvalidRequest,
		http.StatusBadRequest,
		"request validation failed",
		c.Request.URL.Path,
		c.GetString(middleware.CtxKeyRequestID),
	)
	p.Errors = fieldErrors(err)
	abortProblem(c, p)
}

// renderError maps any error to the canonical problem+json envelope. Non-domain
// errors collapse to INTERNAL_ERROR so internals (stack/SQL) never leak (§3.3).
//
// Uses NewProblemFromError to preserve the original SQLSTATE + full RAISE text
// for PG-originated errors (errorCode = pgErr.Code, errorMessage = pgErr.Message).
// The whitelist gate inside NewProblemFromError replaces unknown canonical
// codes with the generic "999999 / Internal Error" envelope.
func renderError(c *gin.Context, err error) {
	var de *domain.Error
	if !errors.As(err, &de) {
		de = domain.Internal(err)
	}
	p := dto.NewProblemFromError(de, c.Request.URL.Path,
		c.GetString(middleware.CtxKeyRequestID))
	abortProblem(c, p)
}

// writeOK wraps the business response in the standard success envelope and
// emits it as application/json. All 2xx handlers (except /healthz) go through
// this helper so every response shares the {errorCode, errorMessage, data}
// shape regardless of outcome.
func writeOK(c *gin.Context, status int, data any) {
	c.JSON(status, dto.Ok(data, c.GetString(middleware.CtxKeyRequestID)))
}

// abortProblem writes p as application/problem+json and stops the chain.
// (gin's JSON renderer forces application/json, so we marshal+write directly.)
func abortProblem(c *gin.Context, p dto.ProblemDetails) {
	body, err := json.Marshal(p)
	if err != nil { // ProblemDetails is plain data — marshalling cannot realistically fail
		c.AbortWithStatus(p.Status)
		return
	}
	c.Header("Content-Type", "application/problem+json")
	c.Status(p.Status)
	_, _ = c.Writer.Write(body)
	c.Abort()
}

// fieldErrors converts go-playground validator errors into problem entries.
func fieldErrors(err error) []dto.FieldError {
	var ve validator.ValidationErrors
	if !errors.As(err, &ve) {
		return nil
	}
	out := make([]dto.FieldError, 0, len(ve))
	for _, fe := range ve {
		out = append(out, dto.FieldError{
			Path:    fe.Field(),
			Code:    fe.Tag(),
			Message: fmt.Sprintf("failed '%s' validation", fe.Tag()),
		})
	}
	return out
}

// statusFor maps a posting SP's status string to an HTTP status: an idempotent
// replay ("DUPLICATE") is 200, a freshly-posted transaction is 201. All three
// finance ops (topup/transfer/withdraw) route through this — keep it uniform.
func statusFor(s string) int {
	if s == "DUPLICATE" {
		return http.StatusOK
	}
	return http.StatusCreated
}
