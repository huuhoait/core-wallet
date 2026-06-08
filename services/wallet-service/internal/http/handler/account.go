package handler

import (
	"net/http"
	"strconv"
	"strings"

	"github.com/gin-gonic/gin"

	"github.com/ewallet-pg/wallet-service/internal/domain"
	"github.com/ewallet-pg/wallet-service/internal/http/dto"
	"github.com/ewallet-pg/wallet-service/internal/http/middleware"
)

// ListAccountsByClient godoc
//
//	@Summary		List a client's accounts
//	@Description	List every wallet owned by a client (full account profiles, no client PII), oldest-first. A client with no wallets returns an empty list; unknown client → 404.
//	@Tags			accounts
//	@Produce		json
//	@Param			client_no	path		string	true	"Client number"
//	@Success		200			{object}	dto.SuccessEnvelope{data=dto.AccountListResponse}	"OK"
//	@Failure		404			{object}	dto.ProblemDetails	"Client not found"
//	@Failure		500			{object}	dto.ProblemDetails	"Internal error"
//	@Router			/v1/clients/{client_no}/accounts [get]
func (h *Wallet) ListAccountsByClient(c *gin.Context) {
	clientNo := c.Param("client_no")
	res, err := h.svc.ListAccountsByClient(c.Request.Context(), clientNo)
	if err != nil {
		renderError(c, err)
		return
	}
	writeOK(c, http.StatusOK, dto.AccountListRespFrom(clientNo, res))
}

// SearchAccounts godoc
//
//	@Summary		Search accounts
//	@Description	Find accounts whose account number or client number contains the query (case-insensitive, substring). Returns acct_no + client_no + the MASKED client name. The query must be at least 6 characters (cheap-enumeration guard).
//	@Tags			accounts
//	@Produce		json
//	@Param			q		query		string	true	"Search term (min 6 chars) — matched against acct_no / client_no"
//	@Param			limit	query		int		false	"Max results (1..200, default 50)"
//	@Success		200		{object}	dto.SuccessEnvelope{data=dto.AccountSearchResponse}	"OK"
//	@Failure		400		{object}	dto.ProblemDetails	"Missing or too-short query (< 6 chars)"
//	@Failure		500		{object}	dto.ProblemDetails	"Internal error"
//	@Router			/v1/accounts/search [get]
func (h *Wallet) SearchAccounts(c *gin.Context) {
	q := strings.TrimSpace(c.Query("q"))
	if len([]rune(q)) < domain.MinAccountSearchLen {
		renderError(c, domain.InvalidRequest("q must be at least 6 characters", nil))
		return
	}
	limit := domain.DefaultAccountSearchSize
	if v := c.Query("limit"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n <= 0 {
			renderError(c, domain.InvalidRequest("invalid limit (positive integer)", nil))
			return
		}
		limit = n
	}
	if limit > domain.MaxAccountSearchSize {
		limit = domain.MaxAccountSearchSize
	}
	res, err := h.svc.SearchAccounts(c.Request.Context(), q, limit)
	if err != nil {
		renderError(c, err)
		return
	}
	writeOK(c, http.StatusOK, dto.AccountSearchRespFrom(q, res))
}

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
