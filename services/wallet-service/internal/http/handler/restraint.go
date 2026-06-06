package handler

import (
	"errors"
	"io"
	"net/http"
	"strconv"

	"github.com/gin-gonic/gin"

	"github.com/ewallet-pg/wallet-service/internal/domain"
	"github.com/ewallet-pg/wallet-service/internal/http/dto"
	"github.com/ewallet-pg/wallet-service/internal/http/middleware"
)

// AddRestraint godoc
//
//	@Summary		Add a restraint (hold/lien)
//	@Description	Place a hold/lien on an account; reduces available balance.
//	@Tags			finance
//	@Accept			json
//	@Produce		json
//	@Param			request	body		dto.AddRestraintRequest	true	"Restraint request"
//	@Success		201		{object}	dto.RestraintResponse	"Created"
//	@Failure		400		{object}	dto.ProblemDetails		"Validation error"
//	@Failure		404		{object}	dto.ProblemDetails		"Account not found"
//	@Failure		422		{object}	dto.ProblemDetails		"Business rule violation"
//	@Failure		500		{object}	dto.ProblemDetails		"Internal error"
//	@Router			/v1/finance/restraints [post]
func (h *Wallet) AddRestraint(c *gin.Context) {
	var req dto.AddRestraintRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		renderValidationError(c, err)
		return
	}
	res, err := h.svc.AddRestraint(c.Request.Context(), domain.RestraintInput{
		AcctNo:       req.AcctNo,
		Type:         req.RestraintType,
		Purpose:      req.RestraintPurpose,
		PledgedAmt:   req.PledgedAmt,
		StartDate:    req.StartDate,
		EndDate:      req.EndDate,
		Narrative:    req.Narrative,
		ReferenceDoc: req.ReferenceDoc,
		Audit:        middleware.FromGin(c),
	})
	if err != nil {
		renderError(c, err)
		return
	}
	c.JSON(http.StatusCreated, dto.RestraintRespFrom(res))
}

// ListRestraints godoc
//
//	@Summary		List account restraints
//	@Description	List an account's restraints (all statuses), newest-first, keyset-paginated. Pass next_cursor as ?before_seq= for the next page.
//	@Tags			finance
//	@Produce		json
//	@Param			acct_no		query		string						true	"Account number"
//	@Param			limit		query		int							false	"Page size (1..200, default 100)"
//	@Param			before_seq	query		int							false	"Keyset cursor: return rows with seq_no < before_seq"
//	@Success		200			{object}	dto.RestraintListResponse	"OK"
//	@Failure		400			{object}	dto.ProblemDetails			"Validation error"
//	@Failure		500			{object}	dto.ProblemDetails			"Internal error"
//	@Router			/v1/finance/restraints [get]
func (h *Wallet) ListRestraints(c *gin.Context) {
	acctNo := c.Query("acct_no")
	if acctNo == "" {
		renderError(c, domain.InvalidRequest("acct_no query parameter is required", nil))
		return
	}

	limit := domain.DefaultRestraintPageSize
	if v := c.Query("limit"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n <= 0 {
			renderError(c, domain.InvalidRequest("invalid limit (positive integer)", nil))
			return
		}
		limit = n
	}
	if limit > domain.MaxRestraintPageSize {
		limit = domain.MaxRestraintPageSize
	}

	q := domain.RestraintListQuery{AcctNo: acctNo, Limit: limit}
	if v := c.Query("before_seq"); v != "" {
		n, err := strconv.ParseInt(v, 10, 64)
		if err != nil || n < 0 {
			renderError(c, domain.InvalidRequest("invalid before_seq (non-negative integer)", nil))
			return
		}
		q.BeforeSeq = &n
	}

	views, err := h.svc.ListRestraints(c.Request.Context(), q)
	if err != nil {
		renderError(c, err)
		return
	}
	c.JSON(http.StatusOK, dto.RestraintListRespFrom(q, views))
}

// GetRestraint godoc
//
//	@Summary	Get a restraint by id
//	@Tags		finance
//	@Produce	json
//	@Param		id	path		int							true	"Restraint id (seq_no)"
//	@Success	200	{object}	dto.RestraintViewResponse	"OK"
//	@Failure	400	{object}	dto.ProblemDetails			"Invalid id"
//	@Failure	404	{object}	dto.ProblemDetails			"Restraint not found"
//	@Failure	500	{object}	dto.ProblemDetails			"Internal error"
//	@Router		/v1/finance/restraints/{id} [get]
func (h *Wallet) GetRestraint(c *gin.Context) {
	id, err := strconv.ParseInt(c.Param("id"), 10, 64)
	if err != nil {
		renderError(c, domain.InvalidRequest("invalid restraint id (numeric)", nil))
		return
	}
	v, err := h.svc.GetRestraint(c.Request.Context(), id)
	if err != nil {
		renderError(c, err)
		return
	}
	c.JSON(http.StatusOK, dto.RestraintViewRespFrom(v))
}

// ReleaseRestraint godoc
//
//	@Summary		Release a restraint
//	@Description	Release an active restraint. Body is optional (reason required only for court/tax restraints, enforced by the SP).
//	@Tags			finance
//	@Accept			json
//	@Produce		json
//	@Param			id		path		int							true	"Restraint id (seq_no)"
//	@Param			request	body		dto.ReleaseRestraintRequest	false	"Release payload (optional)"
//	@Success		200		{object}	dto.RestraintResponse		"OK"
//	@Failure		400		{object}	dto.ProblemDetails			"Validation error"
//	@Failure		404		{object}	dto.ProblemDetails			"Restraint not found"
//	@Failure		422		{object}	dto.ProblemDetails			"Business rule violation"
//	@Failure		500		{object}	dto.ProblemDetails			"Internal error"
//	@Router			/v1/finance/restraints/{id}/release [post]
func (h *Wallet) ReleaseRestraint(c *gin.Context) {
	id, err := strconv.ParseInt(c.Param("id"), 10, 64)
	if err != nil {
		renderError(c, domain.InvalidRequest("invalid restraint id (numeric)", nil))
		return
	}
	var req dto.ReleaseRestraintRequest
	// Body is optional (reason only required for court/tax — enforced by the SP).
	if err := c.ShouldBindJSON(&req); err != nil && !errors.Is(err, io.EOF) {
		renderValidationError(c, err)
		return
	}
	res, err := h.svc.ReleaseRestraint(c.Request.Context(), domain.ReleaseRestraintInput{
		RestraintID: id,
		Reason:      req.Reason,
		Audit:       middleware.FromGin(c),
	})
	if err != nil {
		renderError(c, err)
		return
	}
	c.JSON(http.StatusOK, dto.RestraintRespFrom(res))
}
