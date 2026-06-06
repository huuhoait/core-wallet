package handler

import (
	"net/http"

	"github.com/gin-gonic/gin"

	"github.com/ewallet-pg/wallet-service/internal/domain"
	"github.com/ewallet-pg/wallet-service/internal/http/dto"
	"github.com/ewallet-pg/wallet-service/internal/http/middleware"
)

// FeeCharge godoc
//
//	@Summary		Charge a standalone fee + VAT
//	@Description	Charge an annual/penalty/service fee (with VAT) against a wallet, not tied to any money movement (US-2.8). Idempotent on `reference`.
//	@Tags			finance
//	@Accept			json
//	@Produce		json
//	@Param			request	body		dto.FeeChargeRequest	true	"Fee charge request"
//	@Success		201		{object}	dto.FeeChargeResponse	"Posted"
//	@Success		200		{object}	dto.FeeChargeResponse	"Duplicate idempotent replay"
//	@Failure		400		{object}	dto.ProblemDetails		"Validation error"
//	@Failure		422		{object}	dto.ProblemDetails		"Business rule violation (e.g. insufficient funds)"
//	@Failure		500		{object}	dto.ProblemDetails		"Internal error"
//	@Router			/v1/finance/fee-charge [post]
func (h *Wallet) FeeCharge(c *gin.Context) {
	var req dto.FeeChargeRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		renderValidationError(c, err)
		return
	}
	res, err := h.svc.PostFeeCharge(c.Request.Context(), domain.FeeChargeInput{
		AcctNo:    req.AcctNo,
		Amount:    req.Amount,
		Reference: req.Reference,
		FeeCode:   req.FeeCode,
		Narrative: req.Narrative,
		Metadata:  req.Metadata,
		Audit:     middleware.FromGin(c),
	})
	if err != nil {
		renderError(c, err)
		return
	}
	c.JSON(statusFor(res.Status), dto.FeeChargeRespFrom(res))
}

// ReverseFeeCharge godoc
//
//	@Summary		Reverse a standalone fee charge
//	@Description	Reverse a fee charge by its original `reference` (US-2.8). Idempotent.
//	@Tags			finance
//	@Accept			json
//	@Produce		json
//	@Param			request	body		dto.FeeChargeReversalRequest	true	"Fee reversal request"
//	@Success		200		{object}	dto.FeeChargeReversalResponse	"OK"
//	@Failure		400		{object}	dto.ProblemDetails				"Validation error"
//	@Failure		404		{object}	dto.ProblemDetails				"Original charge not found"
//	@Failure		422		{object}	dto.ProblemDetails				"Business rule violation"
//	@Failure		500		{object}	dto.ProblemDetails				"Internal error"
//	@Router			/v1/finance/fee-charge/reverse [post]
func (h *Wallet) ReverseFeeCharge(c *gin.Context) {
	var req dto.FeeChargeReversalRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		renderValidationError(c, err)
		return
	}
	initiator := req.Initiator
	if initiator == "" {
		initiator = "OPS_MANUAL"
	}
	res, err := h.svc.ReverseFeeCharge(c.Request.Context(), domain.FeeChargeReversalInput{
		OrigReference: req.Reference,
		Reason:        req.Reason,
		Initiator:     initiator,
		Audit:         middleware.FromGin(c),
	})
	if err != nil {
		renderError(c, err)
		return
	}
	c.JSON(http.StatusOK, dto.FeeChargeReversalRespFrom(res))
}
