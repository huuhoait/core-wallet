// Balance-query adapters. These are READ-ONLY: no transaction, no audit GUCs
// (BAL-05 — balance reads must not write an OLTP audit row). They call the
// get_balance* SPs (wallet_sp_balance.sql) directly on the pool. Strong read
// from the primary (BAL-06): pgxpool here points at the primary, not a replica.
package repo

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/ewallet-pg/wallet-service/internal/domain"
)

// GetBalance — customer realtime view (get_balance, §9.3.1).
func (r *PgWalletRepo) GetBalance(ctx context.Context, acctNo string) (*domain.BalanceView, error) {
	const q = `
		SELECT acct_no, ccy, acct_status, actual_bal, available_bal,
		       restrained_amt, masked, message, last_tran_date, as_of
		  FROM get_balance($1)
	`
	var out domain.BalanceView
	var msg *string
	err := r.pool.QueryRow(ctx, q, acctNo).Scan(
		&out.AcctNo, &out.Ccy, &out.AcctStatus,
		&out.ActualBal, &out.AvailableBal, &out.RestrainedAmt,
		&out.Masked, &msg, &out.LastTranDate, &out.AsOf,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, domain.NotFound("wallet not found: "+acctNo, nil)
	}
	if err != nil {
		return nil, mapErrIfPg(err)
	}
	if msg != nil {
		out.Message = *msg
	}
	return &out, nil
}

// GetBalanceOps — ops/internal full view (get_balance_ops, §9.3.2).
func (r *PgWalletRepo) GetBalanceOps(ctx context.Context, acctNo string) (*domain.BalanceOpsView, error) {
	const q = `
		SELECT acct_no, client_no, ccy, acct_status, actual_bal, ledger_bal,
		       calc_bal, available_bal, restrained_amt, restraint_present,
		       cr_blocked, active_restraints, version, previous_day_bal,
		       last_tran_date, as_of
		  FROM get_balance_ops($1)
	`
	var out domain.BalanceOpsView
	err := r.pool.QueryRow(ctx, q, acctNo).Scan(
		&out.AcctNo, &out.ClientNo, &out.Ccy, &out.AcctStatus,
		&out.ActualBal, &out.LedgerBal, &out.CalcBal, &out.AvailableBal,
		&out.RestrainedAmt, &out.RestraintPresent, &out.CrBlocked,
		&out.ActiveRestraints, &out.Version, &out.PreviousDayBal,
		&out.LastTranDate, &out.AsOf,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, domain.NotFound("wallet not found: "+acctNo, nil)
	}
	if err != nil {
		return nil, mapErrIfPg(err)
	}
	return &out, nil
}

// GetBalanceAsOf — historical end-of-day snapshot (get_balance_asof, §9.3.3).
// The SP raises INVALID_DATE / GONE_ONLINE; mapPgError turns those into the
// 422 / 410 domain errors. Empty snapshot → ACCT_NOT_FOUND for the date.
func (r *PgWalletRepo) GetBalanceAsOf(ctx context.Context, acctNo string, asOf time.Time) (*domain.BalanceAsOf, error) {
	const q = `
		SELECT acct_no, ccy, actual_bal, tran_date, source
		  FROM get_balance_asof($1, $2::date)
	`
	var out domain.BalanceAsOf
	err := r.pool.QueryRow(ctx, q, acctNo, asOf).Scan(
		&out.AcctNo, &out.Ccy, &out.ActualBal, &out.TranDate, &out.Source,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, domain.NotFound("no snapshot for wallet/date: "+acctNo, nil)
	}
	if err != nil {
		return nil, mapErrIfPg(err)
	}
	return &out, nil
}

// GetBalanceBatch — batch query, max 100 (get_balance_batch, §9.3.4).
// Found accounts are returned; missing ones are simply absent (caller marks
// them ACCT_NOT_FOUND). > 100 → BATCH_SIZE_EXCEEDED from the SP.
func (r *PgWalletRepo) GetBalanceBatch(ctx context.Context, acctNos []string) ([]domain.BalanceBatchItem, error) {
	const q = `
		SELECT acct_no, ccy, actual_bal, available_bal, restrained_amt
		  FROM get_balance_batch($1::varchar[])
	`
	rows, err := r.pool.Query(ctx, q, acctNos)
	if err != nil {
		return nil, mapErrIfPg(err)
	}
	defer rows.Close()

	out := make([]domain.BalanceBatchItem, 0, len(acctNos))
	for rows.Next() {
		var it domain.BalanceBatchItem
		if err := rows.Scan(&it.AcctNo, &it.Ccy, &it.ActualBal, &it.AvailableBal, &it.RestrainedAmt); err != nil {
			return nil, mapErrIfPg(err)
		}
		out = append(out, it)
	}
	if err := rows.Err(); err != nil {
		return nil, mapErrIfPg(err)
	}
	return out, nil
}
