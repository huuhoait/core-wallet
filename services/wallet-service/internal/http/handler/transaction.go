package handler

import (
	"net/http"
	"strconv"
	"time"

	"github.com/gin-gonic/gin"
	"go.opentelemetry.io/otel/attribute"

	"github.com/ewallet-pg/wallet-service/internal/domain"
	"github.com/ewallet-pg/wallet-service/internal/http/dto"
)

// GetAccount godoc
//
//	@Summary		Get account profile
//	@Description	Account profile (no client PII).
//	@Tags			accounts
//	@Produce		json
//	@Param			acct_no	path		string				true	"Account number"
//	@Success		200		{object}	dto.SuccessEnvelope{data=dto.AccountResponse}	"OK"
//	@Failure		404		{object}	dto.ProblemDetails	"Account not found"
//	@Failure		500		{object}	dto.ProblemDetails	"Internal error"
//	@Router			/v1/accounts/{acct_no} [get]
func (h *Wallet) GetAccount(c *gin.Context) {
	res, err := h.svc.GetAccount(c.Request.Context(), c.Param("acct_no"))
	if err != nil {
		renderError(c, err)
		return
	}
	writeOK(c, http.StatusOK, dto.AccountRespFrom(res))
}

// ListTransactions godoc
//
//	@Summary		Account statement (transaction list)
//	@Description	List ledger legs for an account, newest-first, keyset-paginated. Optional post_date range. Pass next_cursor as ?before_seq= for the next page.
//	@Tags			finance
//	@Produce		json
//	@Param			acct_no		query		string				true	"Account number"
//	@Param			from		query		string				false	"post_date >= (YYYY-MM-DD)"
//	@Param			to			query		string				false	"post_date <= (YYYY-MM-DD)"
//	@Param			limit		query		int					false	"Page size (1..200, default 200)"
//	@Param			before_seq	query		int					false	"Keyset cursor: return rows with seq_no < before_seq"
//	@Success		200			{object}	dto.SuccessEnvelope{data=dto.TxListResponse}	"OK"
//	@Failure		400			{object}	dto.ProblemDetails	"Validation error"
//	@Failure		404			{object}	dto.ProblemDetails	"Account not found"
//	@Failure		500			{object}	dto.ProblemDetails	"Internal error"
//	@Router			/v1/finance/transactions [get]
func (h *Wallet) ListTransactions(c *gin.Context) {
	ctx, span := startSpan(c, "ListTransactions",
		attribute.String("wallet.acct_no", c.Query("acct_no")),
		attribute.String("wallet.limit", c.Query("limit")),
	)
	defer span.End()
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

	entries, err := h.svc.ListTransactions(ctx, q)
	if err != nil {
		failSpan(span, err)
		renderError(c, err)
		return
	}
	span.SetAttributes(attribute.Int("wallet.result_count", len(entries)))
	writeOK(c, http.StatusOK, dto.TxListRespFrom(q, entries))
}

// GetTransaction godoc
//
//	@Summary		Transaction detail (all legs)
//	@Description	Return every ledger leg of one transaction, primary-leg first.
//	@Tags			finance
//	@Produce		json
//	@Param			tran_key	path		int						true	"Transaction internal key (tran_internal_key)"
//	@Success		200			{object}	dto.SuccessEnvelope{data=dto.TxDetailResponse}	"OK"
//	@Failure		400			{object}	dto.ProblemDetails		"Invalid transaction id"
//	@Failure		404			{object}	dto.ProblemDetails		"Transaction not found"
//	@Failure		500			{object}	dto.ProblemDetails		"Internal error"
//	@Router			/v1/finance/transactions/{tran_key} [get]
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
	writeOK(c, http.StatusOK, dto.TxDetailRespFrom(tranKey, legs))
}
