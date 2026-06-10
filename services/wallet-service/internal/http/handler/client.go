package handler

import (
	"net/http"
	"strconv"

	"github.com/gin-gonic/gin"

	"github.com/ewallet-pg/wallet-service/internal/domain"
	"github.com/ewallet-pg/wallet-service/internal/http/dto"
	"github.com/ewallet-pg/wallet-service/internal/http/middleware"
)

// CreateClient godoc
//
//	@Summary		Create a client
//	@Description	Create a client master record (identity only; no KYC flow). client_type is IND | CORP | MER.
//	@Tags			clients
//	@Accept			json
//	@Produce		json
//	@Param			request	body		dto.CreateClientRequest	true	"Client create request"
//	@Success		201		{object}	dto.SuccessEnvelope{data=dto.ClientResponse}		"Created"
//	@Failure		400		{object}	dto.ProblemDetails		"Validation error"
//	@Failure		422		{object}	dto.ProblemDetails		"Business rule violation (e.g. invalid client type)"
//	@Failure		500		{object}	dto.ProblemDetails		"Internal error"
//	@Router			/v1/clients [post]
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
	writeOK(c, http.StatusCreated, dto.ClientRespFrom(res))
}

// Onboard godoc
//
//	@Summary		Onboard a client (OTP-free)
//	@Description	US-1.1/1.7 — create client + KYC + first zero-balance wallet in one TX. CORP/MER require extra_data.business_reg_no + legal_rep (BR-09).
//	@Tags			clients
//	@Accept			json
//	@Produce		json
//	@Param			request	body		dto.OnboardRequest	true	"Onboard request"
//	@Success		201		{object}	dto.SuccessEnvelope{data=dto.OnboardResponse}	"Created"
//	@Failure		400		{object}	dto.ProblemDetails	"Validation error"
//	@Failure		422		{object}	dto.ProblemDetails	"Business rule violation (e.g. ORG_FIELDS_REQUIRED)"
//	@Failure		500		{object}	dto.ProblemDetails	"Internal error"
//	@Router			/v1/onboard [post]
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
		BirthDate:      req.BirthDate,
		Sex:            req.Sex,
		DateIssue:      req.DateIssue,
		ExpireDate:     req.ExpireDate,
		PlaceIssue:     req.PlaceIssue,
		ExtraData:      req.ExtraData,
		Audit:          middleware.FromGin(c),
	})
	if err != nil {
		renderError(c, err)
		return
	}
	writeOK(c, http.StatusCreated, dto.OnboardRespFrom(res))
}

// UpdateKYC godoc
//
//	@Summary		Update client KYC
//	@Description	Submit/update eKYC info and raise the KYC tier (US-1.2). Reaching tier >= 2 stamps verified_at.
//	@Tags			clients
//	@Accept			json
//	@Produce		json
//	@Param			client_no	path		string					true	"Client number"
//	@Param			request		body		dto.KycUpdateRequest	true	"KYC update request"
//	@Success		200			{object}	dto.SuccessEnvelope{data=dto.KycResponse}			"OK"
//	@Failure		400			{object}	dto.ProblemDetails		"Validation error"
//	@Failure		404			{object}	dto.ProblemDetails		"Client not found"
//	@Failure		422			{object}	dto.ProblemDetails		"Business rule violation"
//	@Failure		500			{object}	dto.ProblemDetails		"Internal error"
//	@Router			/v1/clients/{client_no}/kyc [post]
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
	writeOK(c, http.StatusOK, dto.KycRespFrom(res))
}

// ListClients godoc
//
//	@Summary		List clients (masked)
//	@Description	Masked client list (PII masked), keyset-paginated by client_no ascending. Optional status / client_type filters. Pass next_cursor as ?after= for the next page.
//	@Tags			clients
//	@Produce		json
//	@Param			status		query		string					false	"Filter by status (A|B|C)"
//	@Param			client_type	query		string					false	"Filter by client_type (IND|CORP|MER)"
//	@Param			limit		query		int						false	"Page size (1..200, default 100)"
//	@Param			after		query		string					false	"Keyset cursor: return rows with client_no > after"
//	@Success		200			{object}	dto.SuccessEnvelope{data=dto.ClientListResponse}	"OK"
//	@Failure		400			{object}	dto.ProblemDetails		"Validation error"
//	@Failure		500			{object}	dto.ProblemDetails		"Internal error"
//	@Router			/v1/clients [get]
func (h *Wallet) ListClients(c *gin.Context) {
	q, ok := parseClientListQuery(c)
	if !ok {
		return
	}
	res, err := h.svc.ListClients(c.Request.Context(), q)
	if err != nil {
		renderError(c, err)
		return
	}
	writeOK(c, http.StatusOK, dto.ClientListRespFrom(q, res))
}

// ListClientsFull godoc
//
//	@Summary		List clients (unmasked, ops)
//	@Description	UNMASKED client list — raw name + CCCD + decrypted phone/email (wallet_pii_ro). Same filters/keyset as the masked list. Privileged P1/PII read.
//	@Tags			ops
//	@Produce		json
//	@Param			status		query		string	false	"Filter by status (A|B|C)"
//	@Param			client_type	query		string	false	"Filter by client_type (IND|CORP|MER)"
//	@Param			limit		query		int		false	"Page size (1..200, default 100)"
//	@Param			after		query		string	false	"Keyset cursor: return rows with client_no > after"
//	@Success		200			{object}	dto.SuccessEnvelope{data=dto.ClientFullListResponse}	"OK"
//	@Failure		400			{object}	dto.ProblemDetails	"Validation error"
//	@Failure		500			{object}	dto.ProblemDetails	"Internal error"
//	@Router			/v1/ops/clients [get]
func (h *Wallet) ListClientsFull(c *gin.Context) {
	q, ok := parseClientListQuery(c)
	if !ok {
		return
	}
	res, err := h.svc.ListClientsFull(c.Request.Context(), q)
	if err != nil {
		renderError(c, err)
		return
	}
	writeOK(c, http.StatusOK, dto.ClientFullListRespFrom(q, res))
}

// parseClientListQuery parses the shared ?status=&client_type=&limit=&after=
// pagination params. On a bad value it renders the 400 and returns ok=false.
func parseClientListQuery(c *gin.Context) (domain.ClientListQuery, bool) {
	limit := domain.DefaultClientPageSize
	if v := c.Query("limit"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n <= 0 {
			renderError(c, domain.InvalidRequest("invalid limit (positive integer)", nil))
			return domain.ClientListQuery{}, false
		}
		limit = n
	}
	if limit > domain.MaxClientPageSize {
		limit = domain.MaxClientPageSize
	}
	q := domain.ClientListQuery{Limit: limit}
	if v := c.Query("after"); v != "" {
		q.AfterNo = &v
	}
	if v := c.Query("status"); v != "" {
		q.Status = &v
	}
	if v := c.Query("client_type"); v != "" {
		q.ClientType = &v
	}
	return q, true
}

// GetClient godoc
//
//	@Summary		Get a client (masked)
//	@Description	Masked client profile (name + CCCD/passport masked); raw PII never exposed on this path.
//	@Tags			clients
//	@Produce		json
//	@Param			client_no	path		string						true	"Client number"
//	@Success		200			{object}	dto.SuccessEnvelope{data=dto.ClientProfileResponse}	"OK"
//	@Failure		404			{object}	dto.ProblemDetails			"Client not found"
//	@Failure		500			{object}	dto.ProblemDetails			"Internal error"
//	@Router			/v1/clients/{client_no} [get]
func (h *Wallet) GetClient(c *gin.Context) {
	res, err := h.svc.GetClient(c.Request.Context(), c.Param("client_no"))
	if err != nil {
		renderError(c, err)
		return
	}
	writeOK(c, http.StatusOK, dto.ClientProfileRespFrom(res))
}

// GetClient360 godoc
//
//	@Summary		Client 360 (masked)
//	@Description	Aggregate customer view — masked profile + wallets + linked banks (acct_no masked) + restraints. PII masked (wallet_app). Unknown client → 404.
//	@Tags			clients
//	@Produce		json
//	@Param			client_no	path		string	true	"Client number"
//	@Success		200			{object}	dto.SuccessEnvelope{data=dto.Client360Response}	"OK"
//	@Failure		404			{object}	dto.ProblemDetails	"Client not found"
//	@Failure		500			{object}	dto.ProblemDetails	"Internal error"
//	@Router			/v1/clients/{client_no}/360 [get]
func (h *Wallet) GetClient360(c *gin.Context) {
	res, err := h.svc.GetClient360(c.Request.Context(), c.Param("client_no"), false)
	if err != nil {
		renderError(c, err)
		return
	}
	writeOK(c, http.StatusOK, dto.Client360RespFrom(res))
}

// GetClientFull godoc
//
//	@Summary		Get a client (unmasked, ops)
//	@Description	Privileged P1/PII read — raw name + CCCD/passport (wallet_pii_ro pool). Phone/email stay encrypted at rest.
//	@Tags			ops
//	@Produce		json
//	@Param			client_no	path		string					true	"Client number"
//	@Success		200			{object}	dto.SuccessEnvelope{data=dto.ClientFullResponse}	"OK"
//	@Failure		404			{object}	dto.ProblemDetails		"Client not found"
//	@Failure		500			{object}	dto.ProblemDetails		"Internal error"
//	@Router			/v1/ops/clients/{client_no} [get]
func (h *Wallet) GetClientFull(c *gin.Context) {
	res, err := h.svc.GetClientFull(c.Request.Context(), c.Param("client_no"))
	if err != nil {
		renderError(c, err)
		return
	}
	writeOK(c, http.StatusOK, dto.ClientFullRespFrom(res))
}

// GetClientFull360 godoc
//
//	@Summary		Client 360 (unmasked, ops)
//	@Description	Aggregate customer view — raw profile with decrypted phone/email + wallets + linked banks (acct_no decrypted) + restraints. Privileged P1/PII read (wallet_pii_ro). Unknown client → 404.
//	@Tags			ops
//	@Produce		json
//	@Param			client_no	path		string	true	"Client number"
//	@Success		200			{object}	dto.SuccessEnvelope{data=dto.Client360Response}	"OK"
//	@Failure		404			{object}	dto.ProblemDetails	"Client not found"
//	@Failure		500			{object}	dto.ProblemDetails	"Internal error"
//	@Router			/v1/ops/clients/{client_no}/360 [get]
func (h *Wallet) GetClientFull360(c *gin.Context) {
	res, err := h.svc.GetClient360(c.Request.Context(), c.Param("client_no"), true)
	if err != nil {
		renderError(c, err)
		return
	}
	writeOK(c, http.StatusOK, dto.Client360RespFrom(res))
}

// UpdateClient godoc
//
//	@Summary		Update a client
//	@Description	Patch mutable identity fields of an existing client (all fields optional).
//	@Tags			clients
//	@Accept			json
//	@Produce		json
//	@Param			client_no	path		string					true	"Client number"
//	@Param			request		body		dto.UpdateClientRequest	true	"Client update request"
//	@Success		200			{object}	dto.SuccessEnvelope{data=dto.ClientResponse}		"OK"
//	@Failure		400			{object}	dto.ProblemDetails		"Validation error"
//	@Failure		404			{object}	dto.ProblemDetails		"Client not found"
//	@Failure		422			{object}	dto.ProblemDetails		"Business rule violation"
//	@Failure		500			{object}	dto.ProblemDetails		"Internal error"
//	@Router			/v1/clients/{client_no} [patch]
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
	writeOK(c, http.StatusOK, dto.ClientRespFrom(res))
}

// LinkClientBank godoc
//
//	@Summary		Link a bank account to a client
//	@Description	Link a bank account (optionally as default). acct_no is plaintext in; the SP encrypts it at rest and never echoes it in clear.
//	@Tags			clients
//	@Accept			json
//	@Produce		json
//	@Param			client_no	path		string					true	"Client number"
//	@Param			request		body		dto.LinkBankRequest		true	"Bank link request"
//	@Success		201			{object}	dto.SuccessEnvelope{data=dto.BankLinkResponse}	"Created"
//	@Failure		400			{object}	dto.ProblemDetails		"Validation error"
//	@Failure		404			{object}	dto.ProblemDetails		"Client not found"
//	@Failure		422			{object}	dto.ProblemDetails		"Business rule violation"
//	@Failure		500			{object}	dto.ProblemDetails		"Internal error"
//	@Router			/v1/clients/{client_no}/banks [post]
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
	writeOK(c, http.StatusCreated, dto.BankLinkRespFrom(res))
}

// AttachClientDocument godoc
//
//	@Summary		Attach or update a related document
//	@Description	Onboarding step 3: attach a related document (CCCD images, business licence, UBO proofs) to a client's KYC. `link` is an object-store URL/handle — file bytes are never sent here. Re-attaching the same `doc_type` replaces the prior entry. Defaults `status` to PENDING.
//	@Tags			clients
//	@Accept			json
//	@Produce		json
//	@Param			client_no	path		string						true	"Client number"
//	@Param			request		body		dto.AttachDocumentRequest	true	"Document to attach"
//	@Success		200			{object}	dto.SuccessEnvelope{data=dto.AttachDocumentResponse}	"OK"
//	@Failure		400			{object}	dto.ProblemDetails		"Validation error"
//	@Failure		404			{object}	dto.ProblemDetails		"Client or KYC record not found"
//	@Failure		500			{object}	dto.ProblemDetails		"Internal error"
//	@Router			/v1/clients/{client_no}/documents [post]
func (h *Wallet) AttachClientDocument(c *gin.Context) {
	var req dto.AttachDocumentRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		renderValidationError(c, err)
		return
	}
	res, err := h.svc.AttachClientDocument(c.Request.Context(), domain.AttachDocumentInput{
		ClientNo: c.Param("client_no"),
		DocType:  req.DocType,
		Link:     req.Link,
		Status:   req.Status,
		Audit:    middleware.FromGin(c),
	})
	if err != nil {
		renderError(c, err)
		return
	}
	writeOK(c, http.StatusOK, dto.AttachDocumentRespFrom(res))
}

// SetDefaultClientBank godoc
//
//	@Summary		Set default linked bank
//	@Description	Make an existing linked bank the client's default.
//	@Tags			clients
//	@Produce		json
//	@Param			client_no	path		string					true	"Client number"
//	@Param			link_id		path		int						true	"Bank link id"
//	@Success		200			{object}	dto.SuccessEnvelope{data=dto.BankLinkResponse}	"OK"
//	@Failure		400			{object}	dto.ProblemDetails		"Invalid link id"
//	@Failure		404			{object}	dto.ProblemDetails		"Client or link not found"
//	@Failure		500			{object}	dto.ProblemDetails		"Internal error"
//	@Router			/v1/clients/{client_no}/banks/{link_id}/default [put]
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
	writeOK(c, http.StatusOK, dto.BankLinkRespFrom(res))
}
