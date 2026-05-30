// Restraint write adapters — add/release a hold via the add_restraint /
// release_restraint SPs (wallet_sp_restraint.sql). Writes → wrapped in withTx
// so audit GUCs are set for the trg_audit_cols trigger on WLT_ACCT/WLT_RESTRAINTS.
package repo

import (
	"context"

	"github.com/jackc/pgx/v5"

	"github.com/ewallet-pg/wallet-service/internal/domain"
)

// AddRestraint inserts a restraint and rolls it up onto the account.
func (r *PgWalletRepo) AddRestraint(ctx context.Context, in domain.RestraintInput) (*domain.RestraintResult, error) {
	var out domain.RestraintResult
	err := r.withTx(ctx, in.Audit, func(tx pgx.Tx) error {
		const q = `
			SELECT restraint_id, status, pledged_amt::text, available_bal_after::text, version
			  FROM add_restraint($1, $2, $3, $4::numeric, $5::date, $6::date, $7, $8, $9)
		`
		row := tx.QueryRow(ctx, q,
			in.AcctNo, in.Type, in.Purpose,
			nullNumeric(in.PledgedAmt), nullDate(in.StartDate), nullDate(in.EndDate),
			nullStr(in.Narrative), nullStr(in.ReferenceDoc), in.Audit.Actor)
		return row.Scan(&out.RestraintID, &out.Status, &out.PledgedAmt,
			&out.AvailableBalAfter, &out.Version)
	})
	if err != nil {
		return nil, mapErrIfPg(err)
	}
	return &out, nil
}

// ReleaseRestraint marks an active restraint released and recomputes aggregates.
func (r *PgWalletRepo) ReleaseRestraint(ctx context.Context, in domain.ReleaseRestraintInput) (*domain.RestraintResult, error) {
	var out domain.RestraintResult
	err := r.withTx(ctx, in.Audit, func(tx pgx.Tx) error {
		const q = `
			SELECT restraint_id, status, available_bal_after::text, version
			  FROM release_restraint($1, $2, $3)
		`
		row := tx.QueryRow(ctx, q, in.RestraintID, nullStr(in.Reason), in.Audit.Actor)
		return row.Scan(&out.RestraintID, &out.Status, &out.AvailableBalAfter, &out.Version)
	})
	if err != nil {
		return nil, mapErrIfPg(err)
	}
	return &out, nil
}

// nullStr / nullNumeric / nullDate pass NULL to the SP when the input is empty,
// so SP DEFAULTs (e.g. start_date = CURRENT_DATE) apply.
func nullStr(s string) any {
	if s == "" {
		return nil
	}
	return s
}
func nullNumeric(s string) any {
	if s == "" {
		return nil
	}
	return s
}
func nullDate(s string) any {
	if s == "" {
		return nil
	}
	return s
}
