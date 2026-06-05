package handler

import (
	"net/http"

	"github.com/gin-gonic/gin"

	"github.com/ewallet-pg/wallet-service/internal/domain"
	"github.com/ewallet-pg/wallet-service/internal/http/dto"
	"github.com/ewallet-pg/wallet-service/internal/http/middleware"
)

// POST /v1/transactions/reverse — reverse an in-book transfer by reference.
// (reference is in the body to avoid a gin wildcard clash with the static
// /transactions/{topup,transfer,withdraw} routes.)
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

// POST /v1/transactions/topup/reverse — reverse a topup by reference.
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

// POST /v1/finance/merchant-withdraw/reverse — reverse a merchant-settlement
// withdraw by reference. Credits principal + fee/VAT back to the settlement
// account; idempotent on the original reference.
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
