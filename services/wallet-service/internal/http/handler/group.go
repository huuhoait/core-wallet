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

// POST /v1/merchant-groups/:group_id/activate — promote a cold merchant group
// (0 shards) to a hot wallet by creating N empty SHARD sub-accounts.
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
	c.JSON(http.StatusCreated, dto.ActivateHotWalletRespFrom(res))
}

// POST /v1/merchant-groups — provision a NEW cold merchant/agent group: the group
// row + its settlement account in one TX (US-1.10). Defaults: MERCHANT group of a
// MERCHANT-type VND settlement wallet.
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
	c.JSON(http.StatusCreated, dto.ProvisionGroupRespFrom(res))
}

// POST /v1/merchant-groups/:group_id/rescale — grow an already-hot group up a
// tier (4→8→16) and rebalance existing shards back to settlement (US-1.12).
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
	c.JSON(http.StatusOK, dto.RescaleHotWalletRespFrom(res))
}

// POST /v1/finance/merchant-deposit — route an inbound merchant deposit/payment
// into a group: settlement while cold, a reference-hashed shard once hot (US-1.11).
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
	c.JSON(statusFor(res.Status), dto.MerchantDepositRespFrom(res))
}
