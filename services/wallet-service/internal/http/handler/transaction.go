package handler

import (
	"net/http"
	"strconv"

	"github.com/gin-gonic/gin"

	"github.com/ewallet-pg/wallet-service/internal/domain"
	"github.com/ewallet-pg/wallet-service/internal/http/dto"
)

// GET /v1/accounts/:acct_no — account profile (no client PII).
func (h *Wallet) GetAccount(c *gin.Context) {
	res, err := h.svc.GetAccount(c.Request.Context(), c.Param("acct_no"))
	if err != nil {
		renderError(c, err)
		return
	}
	c.JSON(http.StatusOK, dto.AccountRespFrom(res))
}

// GET /v1/finance/transactions?acct_no=&limit=&before_seq= — account statement.
func (h *Wallet) ListTransactions(c *gin.Context) {
	acctNo := c.Query("acct_no")
	if acctNo == "" {
		renderError(c, domain.InvalidRequest("acct_no query parameter is required", nil))
		return
	}

	limit := 20
	if v := c.Query("limit"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n <= 0 {
			renderError(c, domain.InvalidRequest("invalid limit (positive integer)", nil))
			return
		}
		limit = n
	}
	if limit > domain.MaxTxPageSize {
		limit = domain.MaxTxPageSize
	}

	q := domain.TxListQuery{AcctNo: acctNo, Limit: limit}
	if v := c.Query("before_seq"); v != "" {
		n, err := strconv.ParseInt(v, 10, 64)
		if err != nil || n < 0 {
			renderError(c, domain.InvalidRequest("invalid before_seq (non-negative integer)", nil))
			return
		}
		q.BeforeSeq = &n
	}

	entries, err := h.svc.ListTransactions(c.Request.Context(), q)
	if err != nil {
		renderError(c, err)
		return
	}
	c.JSON(http.StatusOK, dto.TxListRespFrom(acctNo, entries, limit))
}

// GET /v1/finance/transactions/:tfr_key — all legs of one transaction.
func (h *Wallet) GetTransaction(c *gin.Context) {
	tfrKey, err := strconv.ParseInt(c.Param("tfr_key"), 10, 64)
	if err != nil {
		renderError(c, domain.InvalidRequest("invalid transaction id (numeric tfr_internal_key)", nil))
		return
	}
	legs, err := h.svc.GetTransaction(c.Request.Context(), tfrKey)
	if err != nil {
		renderError(c, err)
		return
	}
	c.JSON(http.StatusOK, dto.TxDetailRespFrom(tfrKey, legs))
}
