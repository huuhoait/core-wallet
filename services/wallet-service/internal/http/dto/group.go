package dto

import "github.com/ewallet-pg/wallet-service/internal/domain"

// ActivateHotWalletRequest — POST /v1/merchant-groups/:group_id/activate.
// shard_count must be a supported hot tier; omitted → 4 (the hot default).
type ActivateHotWalletRequest struct {
	ShardCount int16 `json:"shard_count,omitempty" binding:"omitempty,oneof=4 8 16"`
}

type ActivateHotWalletResponse struct {
	GroupID          string   `json:"group_id"`
	ShardCount       int16    `json:"shard_count"`
	SettlementAcctNo string   `json:"settlement_acct_no"`
	ShardAcctNos     []string `json:"shard_acct_nos"`
}

func ActivateHotWalletRespFrom(r *domain.ActivateHotWalletResult) ActivateHotWalletResponse {
	return ActivateHotWalletResponse{
		GroupID:          r.GroupID,
		ShardCount:       r.ShardCount,
		SettlementAcctNo: r.SettlementAcctNo,
		ShardAcctNos:     r.ShardAcctNos,
	}
}
