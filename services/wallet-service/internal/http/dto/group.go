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

// ProvisionGroupRequest — POST /v1/merchant-groups (US-1.10). Creates a cold
// group + its settlement account. group_type / acct_type / ccy default when
// omitted; the sizing fields use the SP defaults when omitted.
type ProvisionGroupRequest struct {
	ClientNo         string `json:"client_no"                    binding:"required,min=2,max=48"`
	GroupID          string `json:"group_id"                     binding:"required,min=2,max=20"`
	GroupType        string `json:"group_type,omitempty"         binding:"omitempty,oneof=MERCHANT AGENT NOSTRO_HOT"`
	AcctType         string `json:"acct_type,omitempty"          binding:"omitempty,max=12"`
	CCY              string `json:"ccy,omitempty"                binding:"omitempty,len=3"`
	ShardThreshold   string `json:"shard_threshold,omitempty"    binding:"omitempty,money"`
	ShardBuffer      string `json:"shard_buffer,omitempty"       binding:"omitempty,money"`
	SweepIntervalSec int16  `json:"sweep_interval_sec,omitempty" binding:"omitempty,min=1,max=3600"`
}

type ProvisionGroupResponse struct {
	GroupID               string `json:"group_id"`
	SettlementAcctNo      string `json:"settlement_acct_no"`
	SettlementInternalKey int64  `json:"settlement_internal_key"`
	GroupType             string `json:"group_type"`
	GroupStatus           string `json:"group_status"`
}

func ProvisionGroupRespFrom(r *domain.ProvisionGroupResult) ProvisionGroupResponse {
	return ProvisionGroupResponse{
		GroupID:               r.GroupID,
		SettlementAcctNo:      r.SettlementAcctNo,
		SettlementInternalKey: r.SettlementInternalKey,
		GroupType:             r.GroupType,
		GroupStatus:           r.GroupStatus,
	}
}

// RescaleHotWalletRequest — POST /v1/merchant-groups/:group_id/rescale (US-1.12).
// new_shard_count must be a larger hot tier than the group's current count.
type RescaleHotWalletRequest struct {
	NewShardCount int16 `json:"new_shard_count" binding:"required,oneof=8 16"`
}

type RescaleHotWalletResponse struct {
	GroupID          string   `json:"group_id"`
	OldShardCount    int16    `json:"old_shard_count"`
	NewShardCount    int16    `json:"new_shard_count"`
	SettlementAcctNo string   `json:"settlement_acct_no"`
	AddedAcctNos     []string `json:"added_acct_nos"`
	RebalancedAmount string   `json:"rebalanced_amount"`
}

func RescaleHotWalletRespFrom(r *domain.RescaleHotWalletResult) RescaleHotWalletResponse {
	return RescaleHotWalletResponse{
		GroupID:          r.GroupID,
		OldShardCount:    r.OldShardCount,
		NewShardCount:    r.NewShardCount,
		SettlementAcctNo: r.SettlementAcctNo,
		AddedAcctNos:     r.AddedAcctNos,
		RebalancedAmount: r.RebalancedAmount,
	}
}

// MerchantDepositRequest — POST /v1/finance/merchant-deposit (US-1.11). Routes an
// inbound deposit/payment into a group (settlement while cold, a shard once hot).
type MerchantDepositRequest struct {
	GroupID   string         `json:"group_id"           binding:"required,min=2,max=20"`
	Amount    string         `json:"amount"             binding:"required,money"`
	Reference string         `json:"reference"          binding:"required,min=8,max=64"`
	Metadata  map[string]any `json:"metadata,omitempty"`
}

type MerchantDepositResponse struct {
	TranInternalID int64  `json:"tran_internal_key,omitempty"`
	Status         string `json:"status"`
	TargetAcctNo   string `json:"target_acct_no"`
	ShardIndex     *int16 `json:"shard_index,omitempty"` // null when routed to settlement (cold group)
	NewBalance     string `json:"new_balance"`
	EventUUID      string `json:"event_uuid,omitempty"`
}

func MerchantDepositRespFrom(r *domain.MerchantDepositResult) MerchantDepositResponse {
	out := MerchantDepositResponse{
		TranInternalID: r.TranInternalID,
		Status:         r.Status,
		TargetAcctNo:   r.TargetAcctNo,
		ShardIndex:     r.ShardIndex,
		NewBalance:     r.NewBalance,
	}
	if r.EventUUID.String() != "00000000-0000-0000-0000-000000000000" {
		out.EventUUID = r.EventUUID.String()
	}
	return out
}
