package handler

import (
	"net/http"

	"github.com/gin-gonic/gin"

	"github.com/ewallet-pg/wallet-service/internal/domain"
	"github.com/ewallet-pg/wallet-service/internal/http/dto"
	"github.com/ewallet-pg/wallet-service/internal/http/middleware"
)

// POST /v1/finance/fee-charge — charge a standalone fee + VAT against a wallet
// (annual / penalty / service fee), not tied to any money movement (US-2.8).
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
	writeOK(c, statusFor(res.Status), dto.FeeChargeRespFrom(res))
}

// POST /v1/finance/fee-charge/reverse — reverse a standalone fee charge by its
// original reference (US-2.8).
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
	writeOK(c, http.StatusOK, dto.FeeChargeReversalRespFrom(res))
}
