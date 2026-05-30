// Package handler holds gin HTTP handlers. Each handler binds + validates
// the request DTO, calls the usecase, and renders the response (or maps a
// *domain.Error into the canonical error envelope).
package handler

import (
	"errors"
	"net/http"

	"github.com/gin-gonic/gin"

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

func renderValidationError(c *gin.Context, err error) {
	c.AbortWithStatusJSON(http.StatusBadRequest, dto.ErrorResponse{
		Code:      domain.CodeInvalidRequest,
		Message:   err.Error(),
		RequestID: c.GetString(middleware.CtxKeyRequestID),
	})
}

func renderError(c *gin.Context, err error) {
	var de *domain.Error
	if errors.As(err, &de) {
		c.AbortWithStatusJSON(de.HTTPStatus, dto.ErrorResponse{
			Code:      de.Code,
			Message:   de.Detail,
			RequestID: c.GetString(middleware.CtxKeyRequestID),
		})
		return
	}
	c.AbortWithStatusJSON(http.StatusInternalServerError, dto.ErrorResponse{
		Code:      domain.CodeInternal,
		Message:   err.Error(),
		RequestID: c.GetString(middleware.CtxKeyRequestID),
	})
}

func statusFor(s string) int {
	if s == "DUPLICATE" {
		return http.StatusOK
	}
	return http.StatusCreated
}

func statusForTopup(r *domain.TopupResult) int { return statusFor(r.Status) }
