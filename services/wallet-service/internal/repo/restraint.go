// Restraint adapters. Writes (add/release a hold) go via the add_restraint /
// release_restraint SPs (wallet_sp_restraint.sql), wrapped in withTx so audit
// GUCs are set for the trg_audit_cols trigger on WLT_ACCT/WLT_RESTRAINTS.
//
// Reads (list/detail) are READ-ONLY: no TX, no audit GUCs — direct SELECT on
// WLT_RESTRAINTS (CQRS read path). They run on r.readPool (replica when
// DB_READ_DSN is set) — restraint listings are lag-tolerant display reads.
package repo

import (
	"context"
	"errors"

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

// restraintCols is the shared projection for the read path. AcctNo is resolved
// from INTERNAL_KEY (LEFT JOIN → "" for group-scoped rows). PLEDGED_AMT is cast
// ::text to scan as a decimal string.
const restraintCols = `
	r.seq_no, COALESCE(a.acct_no, ''), r.restraint_type, r.restraint_purpose,
	r.pledged_amt::text, r.start_date, r.end_date, r.status,
	COALESCE(r.narrative, ''), COALESCE(r.reference_doc, ''),
	r.created_at, r.created_by, r.removed_at, r.removed_by, r.removed_reason`

func scanRestraint(row pgx.Row) (domain.RestraintView, error) {
	var v domain.RestraintView
	err := row.Scan(
		&v.RestraintID, &v.AcctNo, &v.Type, &v.Purpose,
		&v.PledgedAmt, &v.StartDate, &v.EndDate, &v.Status,
		&v.Narrative, &v.ReferenceDoc,
		&v.CreatedAt, &v.CreatedBy, &v.RemovedAt, &v.RemovedBy, &v.RemovedReason,
	)
	return v, err
}

// ListRestraints returns an account's restraints (all statuses A/R/E),
// newest-first, keyset-paginated by seq_no. An existing account with no
// restraints returns an empty slice; an unknown account → 404. Group-scoped
// restraints (INTERNAL_KEY NULL) are excluded by the account JOIN.
func (r *PgWalletRepo) ListRestraints(ctx context.Context, q domain.RestraintListQuery) ([]domain.RestraintView, error) {
	const sql = `
		SELECT ` + restraintCols + `
		  FROM WLT_RESTRAINTS r
		  JOIN WLT_ACCT a ON a.internal_key = r.internal_key
		 WHERE a.acct_no = $1
		   AND ($2::bigint IS NULL OR r.seq_no < $2)
		 ORDER BY r.seq_no DESC
		 LIMIT $3
	`
	rows, err := r.readPool.Query(ctx, sql, q.AcctNo, q.BeforeSeq, q.Limit) // replica
	if err != nil {
		return nil, mapErrIfPg(err)
	}
	defer rows.Close()

	capLimit := q.Limit
	if capLimit < 0 {
		capLimit = 0
	}
	if capLimit > domain.MaxRestraintPageSize {
		capLimit = domain.MaxRestraintPageSize
	}

	out := make([]domain.RestraintView, 0, capLimit)
	for rows.Next() {
		v, err := scanRestraint(rows)
		if err != nil {
			return nil, mapErrIfPg(err)
		}
		out = append(out, v)
	}
	if err := rows.Err(); err != nil {
		return nil, mapErrIfPg(err)
	}
	// Empty result: distinguish "no restraints" from "unknown account".
	if len(out) == 0 {
		var exists bool
		if err := r.readPool.QueryRow(ctx, // same source as the list → snapshot-consistent
			`SELECT EXISTS(SELECT 1 FROM WLT_ACCT WHERE acct_no = $1)`, q.AcctNo,
		).Scan(&exists); err != nil {
			return nil, mapErrIfPg(err)
		}
		if !exists {
			return nil, domain.NotFound("account not found: "+q.AcctNo, nil)
		}
	}
	return out, nil
}

// GetRestraint returns a single restraint by id (WLT_RESTRAINTS.SEQ_NO).
// Unknown id → 404. Uses a LEFT JOIN so group-scoped rows still resolve.
func (r *PgWalletRepo) GetRestraint(ctx context.Context, id int64) (*domain.RestraintView, error) {
	const sql = `
		SELECT ` + restraintCols + `
		  FROM WLT_RESTRAINTS r
		  LEFT JOIN WLT_ACCT a ON a.internal_key = r.internal_key
		 WHERE r.seq_no = $1
	`
	v, err := scanRestraint(r.readPool.QueryRow(ctx, sql, id)) // replica
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, domain.NotFound("restraint not found", nil)
	}
	if err != nil {
		return nil, mapErrIfPg(err)
	}
	return &v, nil
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
