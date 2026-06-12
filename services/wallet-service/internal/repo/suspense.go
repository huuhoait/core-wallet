// Suspense/clearing aging adapter (US-6.2). Read-only: direct SELECT against the
// fn_suspense_aging SQL function on the read pool (CQRS read path, no audit TX).
package repo

import (
	"context"
	"time"

	"github.com/ewallet-pg/wallet-service/internal/domain"
)

// SuspenseAging returns the suspense/clearing aging report as of asOf — one row
// per (109.x GL, ccy) with a non-zero net balance, bucketed by post_date age.
func (r *PgWalletRepo) SuspenseAging(ctx context.Context, asOf time.Time) ([]domain.SuspenseAgingRow, error) {
	const sql = `
		SELECT gl_code, gl_desc, ccy,
		       net_balance::text, bucket_0_30::text, bucket_31_60::text,
		       bucket_61_90::text, bucket_90_plus::text, oldest_post_date
		  FROM fn_suspense_aging($1::date)
	`
	rows, err := r.readPool.Query(ctx, sql, asOf)
	if err != nil {
		return nil, mapErrIfPg(err)
	}
	defer rows.Close()

	out := make([]domain.SuspenseAgingRow, 0, 16)
	for rows.Next() {
		var v domain.SuspenseAgingRow
		if err := rows.Scan(&v.GLCode, &v.GLDesc, &v.Ccy,
			&v.NetBalance, &v.Bucket0_30, &v.Bucket31_60, &v.Bucket61_90, &v.Bucket90Plus,
			&v.OldestPostDate); err != nil {
			return nil, mapErrIfPg(err)
		}
		out = append(out, v)
	}
	if err := rows.Err(); err != nil {
		return nil, mapErrIfPg(err)
	}
	return out, nil
}
