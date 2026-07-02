// Manual journal entry adapters (US-6.5). Writes (create / approve / reject) go
// via the create_manual_je / approve_manual_je / reject_manual_je SPs, wrapped
// in withTx so audit GUCs are set and the GL-batch posting runs atomically.
//
// Reads (list / detail) are READ-ONLY: no TX, no audit GUCs — direct SELECT on
// WLT_MANUAL_JE(_LINE) (CQRS read path), on r.readPool.
package repo

import (
	"context"
	"encoding/json"
	"errors"

	"github.com/jackc/pgx/v5"

	"github.com/ewallet-pg/wallet-service/internal/domain"
)

// jeLineJSON is the wire shape the create_manual_je SP parses from its jsonb
// p_lines argument. Empty client_no/narrative are omitted → SQL NULL.
type jeLineJSON struct {
	GLCode     string `json:"gl_code"`
	TranNature string `json:"tran_nature"`
	Amount     string `json:"amount"`
	ClientNo   string `json:"client_no,omitempty"`
	Narrative  string `json:"narrative,omitempty"`
}

// CreateManualJE drafts a balanced JE (status PENDING). Maker = Audit.Actor.
func (r *PgWalletRepo) CreateManualJE(ctx context.Context, in domain.ManualJEInput) (*domain.ManualJECreateResult, error) {
	lines := make([]jeLineJSON, 0, len(in.Lines))
	for _, l := range in.Lines {
		lines = append(lines, jeLineJSON{
			GLCode: l.GLCode, TranNature: l.TranNature, Amount: l.Amount,
			ClientNo: l.ClientNo, Narrative: l.Narrative,
		})
	}
	linesJSON, err := json.Marshal(lines)
	if err != nil {
		return nil, domain.InvalidRequest("journal lines not serialisable", err)
	}

	var out domain.ManualJECreateResult
	err = r.withTx(ctx, in.Audit, func(tx pgx.Tx) error {
		const q = `
			SELECT je_id, status, total_dr::text, total_cr::text, line_count
			  FROM create_manual_je($1, $2, $3, $4::jsonb, $5, $6::date, $7)
		`
		row := tx.QueryRow(ctx, q,
			in.Reference, in.Ccy, in.Reason, string(linesJSON),
			nullStr(in.Narrative), nullDate(in.AccountingDate), in.Audit.Actor)
		return row.Scan(&out.JEID, &out.Status, &out.TotalDR, &out.TotalCR, &out.LineCount)
	})
	if err != nil {
		return nil, mapErrIfPg(err)
	}
	return &out, nil
}

// ApproveManualJE posts a PENDING JE into WLT_GL_BATCH. Checker = Audit.Actor.
func (r *PgWalletRepo) ApproveManualJE(ctx context.Context, in domain.ManualJEDecisionInput) (*domain.ManualJEApproveResult, error) {
	var out domain.ManualJEApproveResult
	err := r.withTx(ctx, in.Audit, func(tx pgx.Tx) error {
		const q = `
			SELECT je_id, status, gl_tran_key, posted_lines
			  FROM approve_manual_je($1, $2, $3)
		`
		row := tx.QueryRow(ctx, q, in.JEID, in.Audit.Actor, nullStr(in.Reason))
		return row.Scan(&out.JEID, &out.Status, &out.GLTranKey, &out.PostedLines)
	})
	if err != nil {
		return nil, mapErrIfPg(err)
	}
	return &out, nil
}

// RejectManualJE declines a PENDING JE (no GL posting). Checker = Audit.Actor.
func (r *PgWalletRepo) RejectManualJE(ctx context.Context, in domain.ManualJEDecisionInput) (*domain.ManualJERejectResult, error) {
	var out domain.ManualJERejectResult
	err := r.withTx(ctx, in.Audit, func(tx pgx.Tx) error {
		const q = `SELECT je_id, status FROM reject_manual_je($1, $2, $3)`
		row := tx.QueryRow(ctx, q, in.JEID, in.Audit.Actor, nullStr(in.Reason))
		return row.Scan(&out.JEID, &out.Status)
	})
	if err != nil {
		return nil, mapErrIfPg(err)
	}
	return &out, nil
}

// manualJEHeaderCols is the shared header projection for the read path.
const manualJEHeaderCols = `
	je_id, reference, accounting_date, ccy, COALESCE(narrative, ''), reason, status,
	total_dr::text, total_cr::text, gl_tran_key, maker_id, made_at,
	checker_id, checked_at, check_reason, version`

func scanManualJEHeader(row pgx.Row) (domain.ManualJEView, error) {
	var v domain.ManualJEView
	err := row.Scan(
		&v.JEID, &v.Reference, &v.AccountingDate, &v.Ccy, &v.Narrative, &v.Reason, &v.Status,
		&v.TotalDR, &v.TotalCR, &v.GLTranKey, &v.MakerID, &v.MadeAt,
		&v.CheckerID, &v.CheckedAt, &v.CheckReason, &v.Version,
	)
	return v, err
}

// ListManualJE returns JE headers (no lines), newest-first, keyset-paginated by
// je_id, optionally filtered by status. Empty status → all statuses.
func (r *PgWalletRepo) ListManualJE(ctx context.Context, q domain.ManualJEListQuery) ([]domain.ManualJEView, error) {
	const sql = `
		SELECT ` + manualJEHeaderCols + `
		  FROM WLT_MANUAL_JE
		 WHERE ($1 = '' OR status = $1)
		   AND ($2::bigint IS NULL OR je_id < $2)
		 ORDER BY je_id DESC
		 LIMIT $3
	`

	limit := q.Limit
	if limit <= 0 {
		limit = domain.DefaultManualJEPageSize
	}
	if limit > domain.MaxManualJEPageSize {
		limit = domain.MaxManualJEPageSize
	}

	rows, err := r.readPool.Query(ctx, sql, q.Status, q.BeforeID, limit)
	if err != nil {
		return nil, mapErrIfPg(err)
	}
	defer rows.Close()

	out := make([]domain.ManualJEView, 0, limit)
	for rows.Next() {
		v, err := scanManualJEHeader(rows)
		if err != nil {
			return nil, mapErrIfPg(err)
		}
		out = append(out, v)
	}
	if err := rows.Err(); err != nil {
		return nil, mapErrIfPg(err)
	}
	return out, nil
}

// GetManualJE returns a single JE (header + ordered lines). Unknown id → 404.
func (r *PgWalletRepo) GetManualJE(ctx context.Context, id int64) (*domain.ManualJEView, error) {
	const headSQL = `SELECT ` + manualJEHeaderCols + ` FROM WLT_MANUAL_JE WHERE je_id = $1`
	v, err := scanManualJEHeader(r.readPool.QueryRow(ctx, headSQL, id))
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, domain.NewError(domain.CodeMJENotFound, 404, "manual journal entry not found", nil)
	}
	if err != nil {
		return nil, mapErrIfPg(err)
	}

	const lineSQL = `
		SELECT line_no, gl_code, tran_nature, amount::text, client_no, narrative
		  FROM WLT_MANUAL_JE_LINE WHERE je_id = $1 ORDER BY line_no
	`
	rows, err := r.readPool.Query(ctx, lineSQL, id)
	if err != nil {
		return nil, mapErrIfPg(err)
	}
	defer rows.Close()
	for rows.Next() {
		var l domain.ManualJELineView
		if err := rows.Scan(&l.LineNo, &l.GLCode, &l.TranNature, &l.Amount, &l.ClientNo, &l.Narrative); err != nil {
			return nil, mapErrIfPg(err)
		}
		v.Lines = append(v.Lines, l)
	}
	if err := rows.Err(); err != nil {
		return nil, mapErrIfPg(err)
	}
	return &v, nil
}
