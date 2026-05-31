// Merchant hot-wallet group lifecycle write adapter — activate_hot_wallet SP.
// Writes → withTx (audit GUCs). The SP is SECURITY DEFINER because wallet_app
// holds only SELECT on WLT_ACCT_GROUP.
package repo

import (
	"context"

	"github.com/jackc/pgx/v5"

	"github.com/ewallet-pg/wallet-service/internal/domain"
)

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
