package handler

import (
	"net/http"
	"strconv"
	"time"

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

// GET /v1/finance/transactions?acct_no=&from=&to=&limit=&before_seq= — account
// statement: filter by account + optional post_date range (YYYY-MM-DD), paged at
// 200 items/page (keyset via next_cursor → ?before_seq=).
func (h *Wallet) ListTransactions(c *gin.Context) {
	acctNo := c.Query("acct_no")
	if acctNo == "" {
		renderError(c, domain.InvalidRequest("acct_no query parameter is required", nil))
		return
	}

	limit := domain.DefaultTxPageSize
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
	if v := c.Query("from"); v != "" {
		t, err := time.Parse("2006-01-02", v)
		if err != nil {
			renderError(c, domain.InvalidRequest("invalid from date (expected YYYY-MM-DD)", nil))
			return
		}
		q.From = &t
	}
	if v := c.Query("to"); v != "" {
		t, err := time.Parse("2006-01-02", v)
		if err != nil {
			renderError(c, domain.InvalidRequest("invalid to date (expected YYYY-MM-DD)", nil))
			return
		}
		q.To = &t
	}
	if q.From != nil && q.To != nil && q.From.After(*q.To) {
		renderError(c, domain.InvalidRequest("from must be on or before to", nil))
		return
	}

	entries, err := h.svc.ListTransactions(c.Request.Context(), q)
	if err != nil {
		renderError(c, err)
		return
	}
	c.JSON(http.StatusOK, dto.TxListRespFrom(q, entries))
}

// GET /v1/finance/transactions/:tran_key — all legs of one transaction.
func (h *Wallet) GetTransaction(c *gin.Context) {
	tranKey, err := strconv.ParseInt(c.Param("tran_key"), 10, 64)
	if err != nil {
		renderError(c, domain.InvalidRequest("invalid transaction id (numeric tran_internal_key)", nil))
		return
	}
	legs, err := h.svc.GetTransaction(c.Request.Context(), tranKey)
	if err != nil {
		renderError(c, err)
		return
	}
	c.JSON(http.StatusOK, dto.TxDetailRespFrom(tranKey, legs))
}
