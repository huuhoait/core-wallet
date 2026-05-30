// Client master CRUD adapters — create_client / update_client SECURITY DEFINER
// SPs (wallet_sp_client.sql). Writes → withTx so audit GUCs attribute the change.
package repo

import (
	"context"

	"github.com/jackc/pgx/v5"

	"github.com/ewallet-pg/wallet-service/internal/domain"
)

func (r *PgWalletRepo) CreateClient(ctx context.Context, in domain.ClientCreateInput) (*domain.ClientResult, error) {
	var out domain.ClientResult
	err := r.withTx(ctx, in.Audit, func(tx pgx.Tx) error {
		const q = `
			SELECT client_no, status, created_at
			  FROM create_client($1, $2, $3, $4, $5, $6, $7, $8, $9::date, $10, $11)
		`
		row := tx.QueryRow(ctx, q,
			in.ClientName, in.ClientType, nullStr(in.GlobalID), nullStr(in.GlobalIDType),
			nullStr(in.CountryLoc), nullStr(in.CountryCitizen),
			nullStr(in.Surname), nullStr(in.GivenName), nullDate(in.BirthDate), nullStr(in.Sex),
			in.Audit.Actor)
		return row.Scan(&out.ClientNo, &out.Status, &out.Timestamp)
	})
	if err != nil {
		return nil, mapErrIfPg(err)
	}
	return &out, nil
}

func (r *PgWalletRepo) UpdateClient(ctx context.Context, in domain.ClientUpdateInput) (*domain.ClientResult, error) {
	var out domain.ClientResult
	err := r.withTx(ctx, in.Audit, func(tx pgx.Tx) error {
		const q = `
			SELECT client_no, status, updated_at
			  FROM update_client($1, $2, $3, $4, $5, $6, $7, $8::date, $9, $10)
		`
		row := tx.QueryRow(ctx, q,
			in.ClientNo, nullStr(in.ClientName), nullStr(in.Status),
			nullStr(in.CountryLoc), nullStr(in.CountryCitizen),
			nullStr(in.Surname), nullStr(in.GivenName), nullDate(in.BirthDate), nullStr(in.Sex),
			in.Audit.Actor)
		return row.Scan(&out.ClientNo, &out.Status, &out.Timestamp)
	})
	if err != nil {
		return nil, mapErrIfPg(err)
	}
	return &out, nil
}
