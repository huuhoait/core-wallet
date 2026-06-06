package handler

import (
	"net/http"
	"time"

	"github.com/gin-gonic/gin"

	"github.com/ewallet-pg/wallet-service/internal/http/dto"
)

// GetBalance godoc
//
//	@Summary		Get account balance
//	@Description	Without as_of_date → customer realtime balance (§9.3.1). With as_of_date → historical end-of-day snapshot (§9.3.3, returns BalanceAsOfResponse).
//	@Tags			accounts
//	@Produce		json
//	@Param			acct_no		path		string				true	"Account number"
//	@Param			as_of_date	query		string				false	"Historical EOD snapshot date (YYYY-MM-DD)"
//	@Success		200			{object}	dto.SuccessEnvelope{data=dto.BalanceResponse}	"Realtime balance (or BalanceAsOfResponse when as_of_date is set)"
//	@Failure		400			{object}	dto.ProblemDetails	"Validation error"
//	@Failure		404			{object}	dto.ProblemDetails	"Account not found"
//	@Failure		500			{object}	dto.ProblemDetails	"Internal error"
//	@Router			/v1/accounts/{acct_no}/balance [get]
func (h *Wallet) GetBalance(c *gin.Context) {
	acctNo := c.Param("acct_no")

	if raw := c.Query("as_of_date"); raw != "" {
		asOf, err := time.Parse("2006-01-02", raw)
		if err != nil {
			renderValidationError(c, err)
			return
		}
		res, err := h.svc.GetBalanceAsOf(c.Request.Context(), acctNo, asOf)
		if err != nil {
			renderError(c, err)
			return
		}
		writeOK(c, http.StatusOK, dto.BalanceAsOfRespFrom(res))
		return
	}

	res, err := h.svc.GetBalance(c.Request.Context(), acctNo)
	if err != nil {
		renderError(c, err)
		return
	}
	writeOK(c, http.StatusOK, dto.BalanceRespFrom(res))
}

// GetBalanceOps godoc
//
//	@Summary		Get account balance (ops full view)
//	@Description	Ops/internal full balance view incl. ledger/calc/restrained breakdown and active restraints (§9.3.2).
//	@Tags			ops
//	@Produce		json
//	@Param			acct_no	path		string					true	"Account number"
//	@Success		200		{object}	dto.SuccessEnvelope{data=dto.BalanceOpsResponse}	"OK"
//	@Failure		404		{object}	dto.ProblemDetails		"Account not found"
//	@Failure		500		{object}	dto.ProblemDetails		"Internal error"
//	@Router			/v1/ops/accounts/{acct_no}/balance [get]
func (h *Wallet) GetBalanceOps(c *gin.Context) {
	res, err := h.svc.GetBalanceOps(c.Request.Context(), c.Param("acct_no"))
	if err != nil {
		renderError(c, err)
		return
	}
	writeOK(c, http.StatusOK, dto.BalanceOpsRespFrom(res))
}

// GetBalanceBatch godoc
//
//	@Summary		Batch balance query
//	@Description	Query up to 100 account balances at once. Unknown accounts are returned per-item with error=ACCT_NOT_FOUND (§9.3.4).
//	@Tags			ops
//	@Accept			json
//	@Produce		json
//	@Param			request	body		dto.BalanceBatchRequest		true	"Batch balance request (max 100 accounts)"
//	@Success		200		{object}	dto.SuccessEnvelope{data=dto.BalanceBatchResponse}	"OK"
//	@Failure		400		{object}	dto.ProblemDetails			"Validation error"
//	@Failure		500		{object}	dto.ProblemDetails			"Internal error"
//	@Router			/v1/ops/accounts/balance/batch [post]
func (h *Wallet) GetBalanceBatch(c *gin.Context) {
	var req dto.BalanceBatchRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		renderValidationError(c, err)
		return
	}
	found, err := h.svc.GetBalanceBatch(c.Request.Context(), req.AcctNos)
	if err != nil {
		renderError(c, err)
		return
	}
	writeOK(c, http.StatusOK, dto.BalanceBatchRespFrom(req.AcctNos, found, time.Now()))
}
