package handler

import (
	"net/http"

	"github.com/gin-gonic/gin"

	"github.com/ewallet-pg/wallet-service/internal/domain"
	"github.com/ewallet-pg/wallet-service/internal/http/dto"
	"github.com/ewallet-pg/wallet-service/internal/http/middleware"
)

// OpenAccount godoc
//
//	@Summary		Open a wallet
//	@Description	Open a zero-balance wallet for a client (count-limited per currency).
//	@Tags			accounts
//	@Accept			json
//	@Produce		json
//	@Param			request	body		dto.OpenAccountRequest	true	"Open account request"
//	@Success		201		{object}	dto.SuccessEnvelope{data=dto.AccountOpenResponse}	"Created"
//	@Failure		400		{object}	dto.ProblemDetails		"Validation error"
//	@Failure		404		{object}	dto.ProblemDetails		"Client not found"
//	@Failure		422		{object}	dto.ProblemDetails		"Business rule violation (e.g. account count limit)"
//	@Failure		500		{object}	dto.ProblemDetails		"Internal error"
//	@Router			/v1/accounts [post]
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

// UpdateAccountStatus godoc
//
//	@Summary		Update account status
//	@Description	Block / close / re-activate an account (status A | B | C).
//	@Tags			accounts
//	@Accept			json
//	@Produce		json
//	@Param			acct_no	path		string							true	"Account number"
//	@Param			request	body		dto.UpdateAccountStatusRequest	true	"Status update request"
//	@Success		200		{object}	dto.SuccessEnvelope{data=dto.AccountStatusResponse}		"OK"
//	@Failure		400		{object}	dto.ProblemDetails				"Validation error"
//	@Failure		404		{object}	dto.ProblemDetails				"Account not found"
//	@Failure		422		{object}	dto.ProblemDetails				"Business rule violation (e.g. illegal transition)"
//	@Failure		500		{object}	dto.ProblemDetails				"Internal error"
//	@Router			/v1/accounts/{acct_no} [patch]
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
