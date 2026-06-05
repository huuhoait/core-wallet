package handler

import (
	"net/http"

	"github.com/gin-gonic/gin"

	"github.com/ewallet-pg/wallet-service/internal/domain"
	"github.com/ewallet-pg/wallet-service/internal/http/dto"
	"github.com/ewallet-pg/wallet-service/internal/http/middleware"
)

// POST /v1/accounts — open a wallet (zero balance) for a client.
func (h *Wallet) OpenAccount(c *gin.Context) {
	var req dto.OpenAccountRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		renderValidationError(c, err)
		return
	}
	ccy := req.Ccy
	if ccy == "" {
		ccy = "VND"
	}
	res, err := h.svc.OpenAccount(c.Request.Context(), domain.AccountOpenInput{
		ClientNo: req.ClientNo,
		AcctType: req.AcctType,
		Ccy:      req.Ccy,
		Audit:    middleware.FromGin(c),
	})
	if err != nil {
		renderError(c, err)
		return
	}
	writeOK(c, http.StatusCreated, dto.AccountOpenResponse{
		AcctNo:     res.AcctNo,
		ClientNo:   req.ClientNo,
		AcctType:   req.AcctType,
		Ccy:        ccy,
		AcctStatus: res.AcctStatus,
	})
}

// PATCH /v1/accounts/:acct_no — block / close / re-activate an account.
func (h *Wallet) UpdateAccountStatus(c *gin.Context) {
	var req dto.UpdateAccountStatusRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		renderValidationError(c, err)
		return
	}
	res, err := h.svc.UpdateAccountStatus(c.Request.Context(), domain.AccountStatusInput{
		AcctNo: c.Param("acct_no"),
		Status: req.Status,
		Audit:  middleware.FromGin(c),
	})
	if err != nil {
		renderError(c, err)
		return
	}
	writeOK(c, http.StatusOK, dto.AccountStatusRespFrom(res))
}
