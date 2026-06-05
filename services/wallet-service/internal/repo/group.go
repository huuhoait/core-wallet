// Merchant hot-wallet group lifecycle write adapter — provision_acct_group,
// activate_hot_wallet, rescale_hot_wallet, post_merchant_deposit SPs. Writes →
// withTx (audit GUCs). The SPs are SECURITY DEFINER because wallet_app holds only
// SELECT on WLT_ACCT_GROUP.
package repo

import (
	"context"
	"encoding/json"

	"github.com/jackc/pgx/v5"

	"github.com/ewallet-pg/wallet-service/internal/domain"
)

// ProvisionAcctGroup creates a cold group row + its settlement account in one TX
// (US-1.10). Optional sizing args are passed as NULL when empty/zero so the SP
// applies its defaults.
func (r *PgWalletRepo) ProvisionAcctGroup(ctx context.Context, in domain.ProvisionGroupInput) (*domain.ProvisionGroupResult, error) {
	var out domain.ProvisionGroupResult
	var threshold, buffer *string
	if in.ShardThreshold != "" {
		threshold = &in.ShardThreshold
	}
	if in.ShardBuffer != "" {
		buffer = &in.ShardBuffer
	}
	var sweepSec *int16
	if in.SweepIntervalSec != 0 {
		sweepSec = &in.SweepIntervalSec
	}
	err := r.withTx(ctx, in.Audit, func(tx pgx.Tx) error {
		const q = `
			SELECT group_id, settlement_acct_no, settlement_internal_key, group_type, group_status
			  FROM provision_acct_group($1, $2, $3, $4, $5, $6::numeric, $7::numeric, $8::smallint, $9, $10)
		`
		return tx.QueryRow(ctx, q,
			in.ClientNo, in.GroupID, in.GroupType, in.AcctType, in.CCY,
			threshold, buffer, sweepSec, string(in.Audit.Channel), in.Audit.Actor).
			Scan(&out.GroupID, &out.SettlementAcctNo, &out.SettlementInternalKey,
				&out.GroupType, &out.GroupStatus)
	})
	if err != nil {
		return nil, mapErrIfPg(err)
	}
	return &out, nil
}

func (r *PgWalletRepo) ActivateHotWallet(ctx context.Context, in domain.ActivateHotWalletInput) (*domain.ActivateHotWalletResult, error) {
	var out domain.ActivateHotWalletResult
	err := r.withTx(ctx, in.Audit, func(tx pgx.Tx) error {
		const q = `
			SELECT group_id, shard_count, settlement_acct_no, shard_acct_nos
			  FROM activate_hot_wallet($1, $2::smallint, $3, $4)
		`
		return tx.QueryRow(ctx, q,
			in.GroupID, in.ShardCount, string(in.Audit.Channel), in.Audit.Actor).
			Scan(&out.GroupID, &out.ShardCount, &out.SettlementAcctNo, &out.ShardAcctNos)
	})
	if err != nil {
		return nil, mapErrIfPg(err)
	}
	return &out, nil
}

// RescaleHotWallet grows an already-hot group up a tier and rebalances by
// draining existing shards back to settlement (US-1.12).
func (r *PgWalletRepo) RescaleHotWallet(ctx context.Context, in domain.RescaleHotWalletInput) (*domain.RescaleHotWalletResult, error) {
	var out domain.RescaleHotWalletResult
	err := r.withTx(ctx, in.Audit, func(tx pgx.Tx) error {
		const q = `
			SELECT group_id, old_shard_count, new_shard_count,
			       settlement_acct_no, added_acct_nos, rebalanced_amount
			  FROM rescale_hot_wallet($1, $2::smallint, $3, $4)
		`
		return tx.QueryRow(ctx, q,
			in.GroupID, in.NewShardCount, string(in.Audit.Channel), in.Audit.Actor).
			Scan(&out.GroupID, &out.OldShardCount, &out.NewShardCount,
				&out.SettlementAcctNo, &out.AddedAcctNos, &out.RebalancedAmount)
	})
	if err != nil {
		return nil, mapErrIfPg(err)
	}
	return &out, nil
}

// MerchantDeposit routes an inbound deposit into a group — settlement while cold,
// a shard once hot (US-1.11). ShardIndex is NULL when routed to settlement.
func (r *PgWalletRepo) MerchantDeposit(ctx context.Context, in domain.MerchantDepositInput) (*domain.MerchantDepositResult, error) {
	var out domain.MerchantDepositResult
	meta := in.Metadata
	if meta == nil {
		meta = map[string]any{}
	}
	metaJSON, err := json.Marshal(meta)
	if err != nil {
		return nil, domain.InvalidRequest("invalid metadata", err)
	}
	err = r.withTx(ctx, in.Audit, func(tx pgx.Tx) error {
		const q = `
			SELECT tran_internal_id, status, target_acct_no, shard_index, new_balance, event_uuid
			  FROM post_merchant_deposit($1, $2::numeric, $3, $4::jsonb, $5, $6)
		`
		return tx.QueryRow(ctx, q,
			in.GroupID, in.Amount, in.Reference, metaJSON,
			string(in.Audit.Channel), in.Audit.Actor).
			Scan(&out.TranInternalID, &out.Status, &out.TargetAcctNo,
				&out.ShardIndex, &out.NewBalance, &out.EventUUID)
	})
	if err != nil {
		return nil, mapErrIfPg(err)
	}
	return &out, nil
}
