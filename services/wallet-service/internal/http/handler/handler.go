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

// POST /v1/transactions/topup
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
	c.JSON(statusForTopup(res), dto.TopupRespFrom(res))
}

// POST /v1/transactions/transfer
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
	c.JSON(statusFor(res.Status), dto.TransferRespFrom(res))
}

// POST /v1/transactions/withdraw
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
	c.JSON(statusFor(res.Status), dto.WithdrawRespFrom(res))
}

// POST /v1/transactions/merchant-withdraw
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
	c.JSON(statusFor(res.Status), dto.MerchantWithdrawRespFrom(res))
}

// POST /v1/treasury/withdrawals/:ext_payout_ref/acked
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
	c.JSON(http.StatusOK, dto.MarkRespFrom(res))
}

// POST /v1/treasury/withdrawals/:ext_payout_ref/disbursing
func (h *Wallet) MarkDisbursing(c *gin.Context) {
	res, err := h.svc.MarkDisbursing(c.Request.Context(), domain.DisbursingInput{
		ExtPayoutRef: c.Param("ext_payout_ref"),
		Audit:        middleware.FromGin(c),
	})
	if err != nil {
		renderError(c, err)
		return
	}
	c.JSON(http.StatusOK, dto.MarkRespFrom(res))
}

// POST /v1/treasury/withdrawals/:ext_payout_ref/completed
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
	c.JSON(http.StatusOK, dto.MarkRespFrom(res))
}

// POST /v1/treasury/withdrawals/:ext_payout_ref/reverse
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
	c.JSON(http.StatusOK, dto.ReversalRespFrom(res))
}

// GET /healthz
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

func statusFor(s string) int {
	if s == "DUPLICATE" {
		return http.StatusOK
	}
	return http.StatusCreated
}

func statusForTopup(r *domain.TopupResult) int { return statusFor(r.Status) }
