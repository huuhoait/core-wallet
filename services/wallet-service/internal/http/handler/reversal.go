package handler

import (
	"net/http"

	"github.com/gin-gonic/gin"

	"github.com/ewallet-pg/wallet-service/internal/domain"
	"github.com/ewallet-pg/wallet-service/internal/http/dto"
	"github.com/ewallet-pg/wallet-service/internal/http/middleware"
)

// ReverseTransfer godoc
//
//	@Summary		Reverse an in-book transfer
//	@Description	Reverse a completed transfer by its original `reference`. Idempotent (re-reversal returns was_already_reversed=true).
//	@Tags			finance
//	@Accept			json
//	@Produce		json
//	@Param			request	body		dto.TransferReversalRequest		true	"Transfer reversal request"
//	@Success		200		{object}	dto.SuccessEnvelope{data=dto.TransferReversalResponse}	"OK"
//	@Failure		400		{object}	dto.ProblemDetails				"Validation error"
//	@Failure		404		{object}	dto.ProblemDetails				"Original transfer not found"
//	@Failure		422		{object}	dto.ProblemDetails				"Business rule violation"
//	@Failure		500		{object}	dto.ProblemDetails				"Internal error"
//	@Router			/v1/finance/reverse [post]
func (h *Wallet) ReverseTransfer(c *gin.Context) {
	var req dto.TransferReversalRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		renderValidationError(c, err)
		return
	}
	initiator := req.Initiator
	if initiator == "" {
		initiator = "OPS_MANUAL"
	}
	res, err := h.svc.ReverseTransfer(c.Request.Context(), domain.TransferReversalInput{
		OrigReference: req.Reference,
		Reason:        req.Reason,
		Initiator:     initiator,
		Audit:         middleware.FromGin(c),
	})
	if err != nil {
		renderError(c, err)
		return
	}
	writeOK(c, http.StatusOK, dto.TransferReversalRespFrom(res))
}

// ReverseTopup godoc
//
//	@Summary		Reverse a top-up
//	@Description	Reverse a completed top-up by its original `reference`. Idempotent.
//	@Tags			finance
//	@Accept			json
//	@Produce		json
//	@Param			request	body		dto.TopupReversalRequest	true	"Top-up reversal request"
//	@Success		200		{object}	dto.SuccessEnvelope{data=dto.TopupReversalResponse}	"OK"
//	@Failure		400		{object}	dto.ProblemDetails			"Validation error"
//	@Failure		404		{object}	dto.ProblemDetails			"Original top-up not found"
//	@Failure		422		{object}	dto.ProblemDetails			"Business rule violation"
//	@Failure		500		{object}	dto.ProblemDetails			"Internal error"
//	@Router			/v1/finance/topup/reverse [post]
func (h *Wallet) ReverseTopup(c *gin.Context) {
	var req dto.TopupReversalRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		renderValidationError(c, err)
		return
	}
	initiator := req.Initiator
	if initiator == "" {
		initiator = "OPS_MANUAL"
	}
	res, err := h.svc.ReverseTopup(c.Request.Context(), domain.TopupReversalInput{
		OrigReference: req.Reference,
		Reason:        req.Reason,
		Initiator:     initiator,
		Audit:         middleware.FromGin(c),
	})
	if err != nil {
		renderError(c, err)
		return
	}
	writeOK(c, http.StatusOK, dto.TopupReversalRespFrom(res))
}

// ReverseMerchantWithdraw godoc
//
//	@Summary		Reverse a merchant-settlement withdraw
//	@Description	Reverse a merchant-settlement withdraw by its original reference, crediting principal + fee/VAT back to the settlement account. Idempotent. Ops-only — requires role wallet.finance.reverse.
//	@Tags			finance
//	@Accept			json
//	@Produce		json
//	@Param			request	body		dto.MerchantWithdrawReversalRequest	true	"Merchant withdraw reversal request"
//	@Success		200		{object}	dto.SuccessEnvelope{data=dto.MerchantWithdrawReversalResponse}	"OK"
//	@Failure		400		{object}	dto.ProblemDetails	"Validation error"
//	@Failure		403		{object}	dto.ProblemDetails	"Missing wallet.finance.reverse role"
//	@Failure		404		{object}	dto.ProblemDetails	"Original withdraw not found"
//	@Failure		422		{object}	dto.ProblemDetails	"Business rule violation"
//	@Failure		500		{object}	dto.ProblemDetails	"Internal error"
//	@Router			/v1/finance/merchant-withdraw/reverse [post]
func (h *Wallet) ReverseMerchantWithdraw(c *gin.Context) {
	var req dto.MerchantWithdrawReversalRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		renderValidationError(c, err)
		return
	}
	initiator := req.Initiator
	if initiator == "" {
		initiator = "OPS_MANUAL"
	}
	res, err := h.svc.ReverseMerchantWithdraw(c.Request.Context(), domain.MerchantWithdrawReversalInput{
		OrigReference: req.Reference,
		FailCode:      req.FailCode,
		FailReason:    req.FailReason,
		Initiator:     initiator,
		Audit:         middleware.FromGin(c),
	})
	if err != nil {
		renderError(c, err)
		return
	}
	writeOK(c, http.StatusOK, dto.MerchantWithdrawReversalRespFrom(res))
}
