package handler

import (
	"context"
	"errors"
	"io"
	"net/http"
	"strconv"

	"github.com/gin-gonic/gin"
	"go.opentelemetry.io/otel/attribute"

	"github.com/ewallet-pg/wallet-service/internal/domain"
	"github.com/ewallet-pg/wallet-service/internal/http/dto"
	"github.com/ewallet-pg/wallet-service/internal/http/middleware"
)

// CreateManualJE godoc
//
//	@Summary		Draft a manual journal entry (maker)
//	@Description	Maker drafts a balanced GL adjusting entry (suspense/clearing/corrections). Status PENDING until a different checker approves. GL-only — does not touch customer balances.
//	@Tags			accounting
//	@Accept			json
//	@Produce		json
//	@Param			request	body		dto.CreateManualJERequest	true	"Journal entry"
//	@Success		201		{object}	dto.SuccessEnvelope{data=dto.ManualJECreateResponse}	"Drafted (PENDING)"
//	@Failure		400		{object}	dto.ProblemDetails	"Validation error"
//	@Failure		409		{object}	dto.ProblemDetails	"Duplicate reference"
//	@Failure		422		{object}	dto.ProblemDetails	"Unbalanced / unknown GL code"
//	@Failure		500		{object}	dto.ProblemDetails	"Internal error"
//	@Router			/v1/ops/gl/journal-entries [post]
func (h *Wallet) CreateManualJE(c *gin.Context) {
	var req dto.CreateManualJERequest
	if err := c.ShouldBindJSON(&req); err != nil {
		renderValidationError(c, err)
		return
	}

	ctx, span := startSpan(c, "accounting.manual_je.create",
		attribute.String("wallet.reference", req.Reference),
		attribute.String("wallet.ccy", req.Ccy),
		attribute.Int("wallet.je_line_count", len(req.Lines)),
	)
	defer span.End()

	res, err := h.svc.CreateManualJE(ctx, req.ToInput(middleware.FromGin(c)))
	if err != nil {
		failSpan(span, err)
		renderError(c, err)
		return
	}
	span.SetAttributes(attribute.Int64("wallet.je_id", res.JEID), attribute.String("wallet.status", res.Status))
	writeOK(c, http.StatusCreated, dto.ManualJECreateRespFrom(res))
}

// ApproveManualJE godoc
//
//	@Summary		Approve + post a manual journal entry (checker)
//	@Description	A different checker approves a PENDING JE, posting its balanced lines into the GL batch. Checker must not be the maker; the target period must be open.
//	@Tags			accounting
//	@Accept			json
//	@Produce		json
//	@Param			je_id	path		int							true	"Journal entry id"
//	@Param			request	body		dto.ManualJEDecisionRequest	false	"Approval note (optional)"
//	@Success		200		{object}	dto.SuccessEnvelope{data=dto.ManualJEApproveResponse}	"Posted"
//	@Failure		403		{object}	dto.ProblemDetails	"Maker cannot approve own JE"
//	@Failure		404		{object}	dto.ProblemDetails	"JE not found"
//	@Failure		409		{object}	dto.ProblemDetails	"Not PENDING / period closed"
//	@Failure		500		{object}	dto.ProblemDetails	"Internal error"
//	@Router			/v1/ops/gl/journal-entries/{je_id}/approve [post]
func (h *Wallet) ApproveManualJE(c *gin.Context) {
	h.decideManualJE(c, "accounting.manual_je.approve", func(ctx context.Context, in domain.ManualJEDecisionInput) (any, error) {
		res, err := h.svc.ApproveManualJE(ctx, in)
		if err != nil {
			return nil, err
		}
		return dto.ManualJEApproveRespFrom(res), nil
	})
}

// RejectManualJE godoc
//
//	@Summary		Reject a manual journal entry
//	@Description	Decline a PENDING JE (no GL posting). The maker may cancel their own draft; a checker may reject another maker's.
//	@Tags			accounting
//	@Accept			json
//	@Produce		json
//	@Param			je_id	path		int							true	"Journal entry id"
//	@Param			request	body		dto.ManualJEDecisionRequest	false	"Rejection note (optional)"
//	@Success		200		{object}	dto.SuccessEnvelope{data=dto.ManualJERejectResponse}	"Rejected"
//	@Failure		404		{object}	dto.ProblemDetails	"JE not found"
//	@Failure		409		{object}	dto.ProblemDetails	"Not PENDING"
//	@Failure		500		{object}	dto.ProblemDetails	"Internal error"
//	@Router			/v1/ops/gl/journal-entries/{je_id}/reject [post]
func (h *Wallet) RejectManualJE(c *gin.Context) {
	h.decideManualJE(c, "accounting.manual_je.reject", func(ctx context.Context, in domain.ManualJEDecisionInput) (any, error) {
		res, err := h.svc.RejectManualJE(ctx, in)
		if err != nil {
			return nil, err
		}
		return dto.ManualJERejectRespFrom(res), nil
	})
}

// decideManualJE is the shared approve/reject flow: parse je_id, bind the
// optional decision body, span, call the supplied service action, render.
func (h *Wallet) decideManualJE(c *gin.Context, span string, action func(context.Context, domain.ManualJEDecisionInput) (any, error)) {
	jeID, err := strconv.ParseInt(c.Param("je_id"), 10, 64)
	if err != nil {
		renderError(c, domain.InvalidRequest("invalid je_id (numeric)", nil))
		return
	}
	var req dto.ManualJEDecisionRequest
	if err := c.ShouldBindJSON(&req); err != nil && !errors.Is(err, io.EOF) {
		renderValidationError(c, err)
		return
	}
	ctx, sp := startSpan(c, span, attribute.Int64("wallet.je_id", jeID))
	defer sp.End()

	data, err := action(ctx, domain.ManualJEDecisionInput{
		JEID:  jeID,
		Reason: req.Reason,
		Audit: middleware.FromGin(c),
	})
	if err != nil {
		failSpan(sp, err)
		renderError(c, err)
		return
	}
	writeOK(c, http.StatusOK, data)
}

// ListManualJE godoc
//
//	@Summary		List manual journal entries
//	@Description	List JE headers, newest-first, keyset-paginated. Optional ?status=PENDING|POSTED|REJECTED filter. Pass next_cursor as ?before_id= for the next page.
//	@Tags			accounting
//	@Produce		json
//	@Param			status		query		string	false	"Filter: PENDING|POSTED|REJECTED"
//	@Param			limit		query		int		false	"Page size (1..200, default 100)"
//	@Param			before_id	query		int		false	"Keyset cursor: rows with je_id < before_id"
//	@Success		200			{object}	dto.SuccessEnvelope{data=dto.ManualJEListResponse}	"OK"
//	@Failure		400			{object}	dto.ProblemDetails	"Validation error"
//	@Failure		500			{object}	dto.ProblemDetails	"Internal error"
//	@Router			/v1/ops/gl/journal-entries [get]
func (h *Wallet) ListManualJE(c *gin.Context) {
	q := domain.ManualJEListQuery{Limit: domain.DefaultManualJEPageSize}

	if s := c.Query("status"); s != "" {
		if s != "PENDING" && s != "POSTED" && s != "REJECTED" {
			renderError(c, domain.InvalidRequest("invalid status (PENDING|POSTED|REJECTED)", nil))
			return
		}
		q.Status = s
	}
	if v := c.Query("limit"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n <= 0 {
			renderError(c, domain.InvalidRequest("invalid limit (positive integer)", nil))
			return
		}
		q.Limit = n
	}
	if v := c.Query("before_id"); v != "" {
		n, err := strconv.ParseInt(v, 10, 64)
		if err != nil || n < 0 {
			renderError(c, domain.InvalidRequest("invalid before_id (non-negative integer)", nil))
			return
		}
		q.BeforeID = &n
	}

	views, err := h.svc.ListManualJE(c.Request.Context(), q)
	if err != nil {
		renderError(c, err)
		return
	}
	writeOK(c, http.StatusOK, dto.ManualJEListRespFrom(q, views))
}

// GetManualJE godoc
//
//	@Summary	Get a manual journal entry (header + lines)
//	@Tags		accounting
//	@Produce	json
//	@Param		je_id	path		int							true	"Journal entry id"
//	@Success	200		{object}	dto.SuccessEnvelope{data=dto.ManualJEViewResponse}	"OK"
//	@Failure	400		{object}	dto.ProblemDetails			"Invalid id"
//	@Failure	404		{object}	dto.ProblemDetails			"JE not found"
//	@Failure	500		{object}	dto.ProblemDetails			"Internal error"
//	@Router		/v1/ops/gl/journal-entries/{je_id} [get]
func (h *Wallet) GetManualJE(c *gin.Context) {
	jeID, err := strconv.ParseInt(c.Param("je_id"), 10, 64)
	if err != nil {
		renderError(c, domain.InvalidRequest("invalid je_id (numeric)", nil))
		return
	}
	v, err := h.svc.GetManualJE(c.Request.Context(), jeID)
	if err != nil {
		renderError(c, err)
		return
	}
	writeOK(c, http.StatusOK, dto.ManualJEViewRespFrom(v))
}
