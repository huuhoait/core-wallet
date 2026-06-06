package handler

import (
	"errors"
	"io"
	"net/http"

	"github.com/gin-gonic/gin"

	"github.com/ewallet-pg/wallet-service/internal/domain"
	"github.com/ewallet-pg/wallet-service/internal/http/dto"
	"github.com/ewallet-pg/wallet-service/internal/http/middleware"
)

// defaultHotShardCount is the shard fan-out applied when a request omits
// shard_count — the hot-tier default (groups are created cold with 0 shards).
const defaultHotShardCount int16 = 4

// ActivateHotWallet godoc
//
//	@Summary		Activate hot wallet
//	@Description	Promote a cold merchant group (0 shards) to a hot wallet by creating N empty SHARD sub-accounts (US-1.9). Body optional; defaults to 4 shards.
//	@Tags			merchant-groups
//	@Accept			json
//	@Produce		json
//	@Param			group_id	path		string							true	"Merchant group id"
//	@Param			request		body		dto.ActivateHotWalletRequest	false	"Activation payload (optional; default 4 shards)"
//	@Success		201			{object}	dto.SuccessEnvelope{data=dto.ActivateHotWalletResponse}	"Created"
//	@Failure		400			{object}	dto.ProblemDetails				"Validation error"
//	@Failure		404			{object}	dto.ProblemDetails				"Group not found"
//	@Failure		422			{object}	dto.ProblemDetails				"Business rule violation (e.g. already hot)"
//	@Failure		500			{object}	dto.ProblemDetails				"Internal error"
//	@Router			/v1/merchant-groups/{group_id}/activate [post]
func (h *Wallet) ActivateHotWallet(c *gin.Context) {
	var req dto.ActivateHotWalletRequest
	// Body is optional: an empty body (io.EOF) means "use the hot default"; a
	// present-but-invalid body still fails validation.
	if err := c.ShouldBindJSON(&req); err != nil && !errors.Is(err, io.EOF) {
		renderValidationError(c, err)
		return
	}
	shards := req.ShardCount
	if shards == 0 {
		shards = defaultHotShardCount
	}
	res, err := h.svc.ActivateHotWallet(c.Request.Context(), domain.ActivateHotWalletInput{
		GroupID:    c.Param("group_id"),
		ShardCount: shards,
		Audit:      middleware.FromGin(c),
	})
	if err != nil {
		renderError(c, err)
		return
	}
	writeOK(c, http.StatusCreated, dto.ActivateHotWalletRespFrom(res))
}

// ProvisionAcctGroup godoc
//
//	@Summary		Provision a merchant group
//	@Description	Provision a new COLD merchant/agent group: the group row + its settlement account in one TX (US-1.10). Defaults: MERCHANT group of a MERCHANT-type VND settlement wallet.
//	@Tags			merchant-groups
//	@Accept			json
//	@Produce		json
//	@Param			request	body		dto.ProvisionGroupRequest	true	"Provision group request"
//	@Success		201		{object}	dto.SuccessEnvelope{data=dto.ProvisionGroupResponse}	"Created"
//	@Failure		400		{object}	dto.ProblemDetails			"Validation error"
//	@Failure		422		{object}	dto.ProblemDetails			"Business rule violation"
//	@Failure		500		{object}	dto.ProblemDetails			"Internal error"
//	@Router			/v1/merchant-groups [post]
func (h *Wallet) ProvisionAcctGroup(c *gin.Context) {
	var req dto.ProvisionGroupRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		renderValidationError(c, err)
		return
	}
	groupType := req.GroupType
	if groupType == "" {
		groupType = "MERCHANT"
	}
	acctType := req.AcctType
	if acctType == "" {
		acctType = "MERCHANT"
	}
	ccy := req.CCY
	if ccy == "" {
		ccy = "VND"
	}
	res, err := h.svc.ProvisionAcctGroup(c.Request.Context(), domain.ProvisionGroupInput{
		ClientNo:         req.ClientNo,
		GroupID:          req.GroupID,
		GroupType:        groupType,
		AcctType:         acctType,
		CCY:              ccy,
		ShardThreshold:   req.ShardThreshold,
		ShardBuffer:      req.ShardBuffer,
		SweepIntervalSec: req.SweepIntervalSec,
		Audit:            middleware.FromGin(c),
	})
	if err != nil {
		renderError(c, err)
		return
	}
	writeOK(c, http.StatusCreated, dto.ProvisionGroupRespFrom(res))
}

// RescaleHotWallet godoc
//
//	@Summary		Rescale hot wallet
//	@Description	Grow an already-hot group up a tier (4->8->16) and rebalance existing shards back to settlement first (US-1.12).
//	@Tags			merchant-groups
//	@Accept			json
//	@Produce		json
//	@Param			group_id	path		string							true	"Merchant group id"
//	@Param			request		body		dto.RescaleHotWalletRequest		true	"Rescale request"
//	@Success		200			{object}	dto.SuccessEnvelope{data=dto.RescaleHotWalletResponse}	"OK"
//	@Failure		400			{object}	dto.ProblemDetails				"Validation error"
//	@Failure		404			{object}	dto.ProblemDetails				"Group not found"
//	@Failure		422			{object}	dto.ProblemDetails				"Business rule violation"
//	@Failure		500			{object}	dto.ProblemDetails				"Internal error"
//	@Router			/v1/merchant-groups/{group_id}/rescale [post]
func (h *Wallet) RescaleHotWallet(c *gin.Context) {
	var req dto.RescaleHotWalletRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		renderValidationError(c, err)
		return
	}
	res, err := h.svc.RescaleHotWallet(c.Request.Context(), domain.RescaleHotWalletInput{
		GroupID:       c.Param("group_id"),
		NewShardCount: req.NewShardCount,
		Audit:         middleware.FromGin(c),
	})
	if err != nil {
		renderError(c, err)
		return
	}
	writeOK(c, http.StatusOK, dto.RescaleHotWalletRespFrom(res))
}

// MerchantDeposit godoc
//
//	@Summary		Merchant deposit
//	@Description	Route an inbound merchant deposit/payment into a group: settlement while cold, a reference-hashed shard once hot (US-1.11). Idempotent on `reference`.
//	@Tags			finance
//	@Accept			json
//	@Produce		json
//	@Param			request	body		dto.MerchantDepositRequest	true	"Merchant deposit request"
//	@Success		201		{object}	dto.SuccessEnvelope{data=dto.MerchantDepositResponse}	"Posted"
//	@Success		200		{object}	dto.SuccessEnvelope{data=dto.MerchantDepositResponse}	"Duplicate idempotent replay"
//	@Failure		400		{object}	dto.ProblemDetails			"Validation error"
//	@Failure		404		{object}	dto.ProblemDetails			"Group not found"
//	@Failure		422		{object}	dto.ProblemDetails			"Business rule violation"
//	@Failure		500		{object}	dto.ProblemDetails			"Internal error"
//	@Router			/v1/finance/merchant-deposit [post]
func (h *Wallet) MerchantDeposit(c *gin.Context) {
	var req dto.MerchantDepositRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		renderValidationError(c, err)
		return
	}
	res, err := h.svc.MerchantDeposit(c.Request.Context(), domain.MerchantDepositInput{
		GroupID:   req.GroupID,
		Amount:    req.Amount,
		Reference: req.Reference,
		Metadata:  req.Metadata,
		Audit:     middleware.FromGin(c),
	})
	if err != nil {
		renderError(c, err)
		return
	}
	writeOK(c, statusFor(res.Status), dto.MerchantDepositRespFrom(res))
}
