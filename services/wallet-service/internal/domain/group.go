package domain

import "github.com/google/uuid"

// ProvisionGroupInput provisions a NEW cold merchant/agent group — the group row
// plus its SETTLEMENT account, atomically in one TX (provision_acct_group SP,
// US-1.10). The group starts cold (0 shards); promote it with ActivateHotWallet.
// Optional sizing fields use the SP defaults when empty/zero.
type ProvisionGroupInput struct {
	ClientNo         string
	GroupID          string
	GroupType        string // MERCHANT | AGENT | NOSTRO_HOT
	AcctType         string // settlement account type (e.g. MERCHANT)
	CCY              string
	ShardThreshold   string // optional decimal; "" → SP default
	ShardBuffer      string // optional decimal; "" → SP default
	SweepIntervalSec int16  // optional; 0 → SP default
	Audit            AuditContext
}

// ProvisionGroupResult is what provision_acct_group returns.
type ProvisionGroupResult struct {
	GroupID               string
	SettlementAcctNo      string
	SettlementInternalKey int64
	GroupType             string
	GroupStatus           string
}

// RescaleHotWalletInput rescales an already-hot group up a tier (4→8 or 8→16)
// and rebalances by draining existing shards back to settlement
// (rescale_hot_wallet SP, US-1.12). NewShardCount must be strictly larger.
type RescaleHotWalletInput struct {
	GroupID       string
	NewShardCount int16 // 8 | 16, > current
	Audit         AuditContext
}

// RescaleHotWalletResult is what rescale_hot_wallet returns: the tier change, the
// newly-added shard accounts, and the total amount swept back to settlement.
type RescaleHotWalletResult struct {
	GroupID          string
	OldShardCount    int16
	NewShardCount    int16
	SettlementAcctNo string
	AddedAcctNos     []string
	RebalancedAmount string
}

// MerchantDepositInput routes an inbound merchant deposit/payment into a group
// (post_merchant_deposit SP, US-1.11): credits the SETTLEMENT account while the
// group is cold, or a reference-hashed SHARD once it is hot.
type MerchantDepositInput struct {
	GroupID   string
	Amount    string
	Reference string // idempotency key
	Metadata  map[string]any
	Audit     AuditContext
}

// MerchantDepositResult is what post_merchant_deposit returns. ShardIndex is nil
// when the deposit was routed to the settlement account (cold group).
type MerchantDepositResult struct {
	TranInternalID int64
	Status         string // "Success" | "DUPLICATE"
	TargetAcctNo   string
	ShardIndex     *int16
	NewBalance     string
	EventUUID      uuid.UUID
}

// ActivateHotWalletInput promotes a cold merchant/agent group (0 shards) to a
// hot wallet by materialising ShardCount empty SHARD sub-accounts
// (activate_hot_wallet SP). ShardCount must be a supported hot tier (4/8/16);
// the handler defaults an omitted value to 4.
type ActivateHotWalletInput struct {
	GroupID    string
	ShardCount int16 // 4 | 8 | 16
	Audit      AuditContext
}

// ActivateHotWalletResult is what activate_hot_wallet returns: the new shard
// count, the settlement account, and the freshly-created shard account numbers.
type ActivateHotWalletResult struct {
	GroupID          string
	ShardCount       int16
	SettlementAcctNo string
	ShardAcctNos     []string
}
