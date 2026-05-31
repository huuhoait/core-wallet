package domain

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
