package handler

import (
	"net/http"

	"github.com/gin-gonic/gin"

	"github.com/ewallet-pg/wallet-service/internal/domain"
	"github.com/ewallet-pg/wallet-service/internal/http/dto"
	"github.com/ewallet-pg/wallet-service/internal/http/middleware"
)

// POST /v1/clients — create a client master record (identity only).
func (h *Wallet) CreateClient(c *gin.Context) {
	var req dto.CreateClientRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		renderValidationError(c, err)
		return
	}
	res, err := h.svc.CreateClient(c.Request.Context(), domain.ClientCreateInput{
		ClientName:     req.ClientName,
		ClientType:     req.ClientType,
		GlobalID:       req.GlobalID,
		GlobalIDType:   req.GlobalIDType,
		CountryLoc:     req.CountryLoc,
		CountryCitizen: req.CountryCitizen,
		Surname:        req.Surname,
		GivenName:      req.GivenName,
		BirthDate:      req.BirthDate,
		Sex:            req.Sex,
		Audit:          middleware.FromGin(c),
	})
	if err != nil {
		renderError(c, err)
		return
	}
	c.JSON(http.StatusCreated, dto.ClientRespFrom(res))
}

// PATCH /v1/clients/:client_no — update mutable client fields.
func (h *Wallet) UpdateClient(c *gin.Context) {
	var req dto.UpdateClientRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		renderValidationError(c, err)
		return
	}
	res, err := h.svc.UpdateClient(c.Request.Context(), domain.ClientUpdateInput{
		ClientNo:       c.Param("client_no"),
		ClientName:     req.ClientName,
		Status:         req.Status,
		CountryLoc:     req.CountryLoc,
		CountryCitizen: req.CountryCitizen,
		Surname:        req.Surname,
		GivenName:      req.GivenName,
		BirthDate:      req.BirthDate,
		Sex:            req.Sex,
		Audit:          middleware.FromGin(c),
	})
	if err != nil {
		renderError(c, err)
		return
	}
	c.JSON(http.StatusOK, dto.ClientRespFrom(res))
}
