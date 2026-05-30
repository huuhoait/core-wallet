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

// POST /v1/finance/restraints — add a hold/lien on an account.
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

// POST /v1/finance/restraints/:id/release — release an active restraint.
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
