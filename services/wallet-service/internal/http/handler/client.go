package handler

import (
	"net/http"
	"strconv"

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

// POST /v1/onboard — OTP-free step 1 (US-1.1/1.7): create client + KYC + first
// zero-balance wallet in one TX. CORP/MER require extra_data.business_reg_no +
// legal_rep (BR-09 → 422 ORG_FIELDS_REQUIRED).
func (h *Wallet) Onboard(c *gin.Context) {
	var req dto.OnboardRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		renderValidationError(c, err)
		return
	}
	res, err := h.svc.OnboardClient(c.Request.Context(), domain.OnboardInput{
		ClientName:     req.ClientName,
		ClientType:     req.ClientType,
		Phone:          req.Phone,
		GlobalID:       req.GlobalID,
		GlobalIDType:   req.GlobalIDType,
		Email:          req.Email,
		CountryLoc:     req.CountryLoc,
		CountryCitizen: req.CountryCitizen,
		AcctType:       req.AcctType,
		Ccy:            req.Ccy,
		ExtraData:      req.ExtraData,
		Audit:          middleware.FromGin(c),
	})
	if err != nil {
		renderError(c, err)
		return
	}
	c.JSON(http.StatusCreated, dto.OnboardRespFrom(res))
}

// POST /v1/clients/:client_no/kyc — update KYC info / eKYC + raise tier (US-1.2).
func (h *Wallet) UpdateKYC(c *gin.Context) {
	var req dto.KycUpdateRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		renderValidationError(c, err)
		return
	}
	res, err := h.svc.UpdateKYC(c.Request.Context(), domain.KycUpdateInput{
		ClientNo:       c.Param("client_no"),
		KycTier:        req.KycTier,
		Status:         req.Status,
		RiskLevel:      req.RiskLevel,
		EkycProvider:   req.EkycProvider,
		EkycRef:        req.EkycRef,
		FaceMatchScore: req.FaceMatchScore,
		LivenessResult: req.LivenessResult,
		ExtraData:      req.ExtraData,
		Audit:          middleware.FromGin(c),
	})
	if err != nil {
		renderError(c, err)
		return
	}
	c.JSON(http.StatusOK, dto.KycRespFrom(res))
}

// GET /v1/clients/:client_no — MASKED client profile (wallet_app via
// v_client_masked). Name + CCCD/passport masked; unknown client_no → 404.
func (h *Wallet) GetClient(c *gin.Context) {
	res, err := h.svc.GetClient(c.Request.Context(), c.Param("client_no"))
	if err != nil {
		renderError(c, err)
		return
	}
	c.JSON(http.StatusOK, dto.ClientProfileRespFrom(res))
}

// GET /v1/ops/clients/:client_no — UNMASKED client profile (privileged,
// wallet_pii_ro pool). Returns raw name + CCCD/passport; unknown client_no → 404.
func (h *Wallet) GetClientFull(c *gin.Context) {
	res, err := h.svc.GetClientFull(c.Request.Context(), c.Param("client_no"))
	if err != nil {
		renderError(c, err)
		return
	}
	c.JSON(http.StatusOK, dto.ClientFullRespFrom(res))
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

// POST /v1/clients/:client_no/banks — link a bank account (optionally default).
func (h *Wallet) LinkClientBank(c *gin.Context) {
	var req dto.LinkBankRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		renderValidationError(c, err)
		return
	}
	res, err := h.svc.LinkClientBank(c.Request.Context(), domain.BankLinkInput{
		ClientNo:       c.Param("client_no"),
		BankCode:       req.BankCode,
		AcctNo:         req.AcctNo,
		BankName:       req.BankName,
		AcctHolderName: req.AcctHolderName,
		IsDefault:      req.IsDefault,
		Audit:          middleware.FromGin(c),
	})
	if err != nil {
		renderError(c, err)
		return
	}
	c.JSON(http.StatusCreated, dto.BankLinkRespFrom(res))
}

// PUT /v1/clients/:client_no/banks/:link_id/default — set the default bank.
func (h *Wallet) SetDefaultClientBank(c *gin.Context) {
	linkID, err := strconv.ParseInt(c.Param("link_id"), 10, 64)
	if err != nil {
		renderError(c, domain.InvalidRequest("link_id must be an integer", err))
		return
	}
	res, err := h.svc.SetDefaultClientBank(c.Request.Context(), domain.SetDefaultBankInput{
		ClientNo: c.Param("client_no"),
		LinkID:   linkID,
		Audit:    middleware.FromGin(c),
	})
	if err != nil {
		renderError(c, err)
		return
	}
	c.JSON(http.StatusOK, dto.BankLinkRespFrom(res))
}
