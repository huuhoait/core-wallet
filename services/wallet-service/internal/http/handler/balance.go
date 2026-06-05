package handler

import (
	"net/http"
	"time"

	"github.com/gin-gonic/gin"

	"github.com/ewallet-pg/wallet-service/internal/http/dto"
)

// GET /v1/wallets/:acct_no/balance[?as_of_date=YYYY-MM-DD]
//
// Without as_of_date → customer realtime balance (§9.3.1).
// With as_of_date    → historical end-of-day snapshot (§9.3.3).
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

// GET /v1/ops/wallets/:acct_no/balance — ops/internal full view (§9.3.2).
func (h *Wallet) GetBalanceOps(c *gin.Context) {
	res, err := h.svc.GetBalanceOps(c.Request.Context(), c.Param("acct_no"))
	if err != nil {
		renderError(c, err)
		return
	}
	writeOK(c, http.StatusOK, dto.BalanceOpsRespFrom(res))
}

// POST /v1/ops/wallets/balance/batch — batch query, max 100 (§9.3.4).
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
