// Account (wallet) lifecycle write adapters — open_account / update_account_status
// SPs (wallet_sp_account.sql). Writes → withTx (audit GUCs). GetAccount (read)
// lives in transaction.go.
package repo

import (
	"context"

	"github.com/jackc/pgx/v5"

	"github.com/ewallet-pg/wallet-service/internal/domain"
)

func (r *PgWalletRepo) OpenAccount(ctx context.Context, in domain.AccountOpenInput) (*domain.AccountOpenResult, error) {
	var out domain.AccountOpenResult
	err := r.withTx(ctx, in.Audit, func(tx pgx.Tx) error {
		const q = `SELECT acct_no, internal_key, acct_status FROM open_account($1, $2, $3, $4)`
		return tx.QueryRow(ctx, q, in.ClientNo, in.AcctType, nullStr(in.Ccy), in.Audit.Actor).
			Scan(&out.AcctNo, &out.InternalKey, &out.AcctStatus)
	})
	if err != nil {
		return nil, mapErrIfPg(err)
	}
	return &out, nil
}

func (r *PgWalletRepo) UpdateAccountStatus(ctx context.Context, in domain.AccountStatusInput) (*domain.AccountStatusResult, error) {
	var out domain.AccountStatusResult
	err := r.withTx(ctx, in.Audit, func(tx pgx.Tx) error {
		const q = `SELECT acct_no, acct_status, version FROM update_account_status($1, $2, $3)`
		return tx.QueryRow(ctx, q, in.AcctNo, in.Status, in.Audit.Actor).
			Scan(&out.AcctNo, &out.AcctStatus, &out.Version)
	})
	if err != nil {
		return nil, mapErrIfPg(err)
	}
	return &out, nil
}
