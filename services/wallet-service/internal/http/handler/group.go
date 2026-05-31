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
