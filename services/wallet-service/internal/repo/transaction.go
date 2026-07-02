// Account-profile + transaction-history read adapters. READ-ONLY: no TX, no
// audit GUCs. wallet_app holds SELECT on WLT_ACCT / WLT_TRAN_HIST (schema
// §grants), so these query the tables directly (amounts cast ::text to scan as
// decimal strings). Client PII is NOT exposed here — that needs the masked view.
//
// Replica routing: GetAccount (profile) and ListTransactions (statement list)
// run on r.readPool — the read replica when DB_READ_DSN is set, else the primary.
// These are lag-tolerant (eventually-consistent display). GetTransaction (detail)
// and all balance/ops reads stay on the primary (r.pool) for read-your-writes.
package repo

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5"

	"github.com/ewallet-pg/wallet-service/internal/domain"
)

// GetAccount returns the account profile (no client PII).
func (r *PgWalletRepo) GetAccount(ctx context.Context, acctNo string) (*domain.AccountView, error) {
	const q = `
		SELECT acct_no, client_no, acct_desc, acct_type, ccy, acct_status, acct_role,
		       actual_bal::text, total_restrained_amt::text, calc_bal::text,
		       prev_day_actual_bal::text, acct_open_date, last_tran_date,
		       restraint_present, cr_blocked, version, group_id, shard_index
		  FROM WLT_ACCT
		 WHERE acct_no = $1
	`
	var a domain.AccountView
	err := r.readPool.QueryRow(ctx, q, acctNo).Scan( // replica (lag-tolerant profile)
		&a.AcctNo, &a.ClientNo, &a.AcctDesc, &a.AcctType, &a.Ccy, &a.AcctStatus, &a.AcctRole,
		&a.ActualBal, &a.RestrainedAmt, &a.CalcBal, &a.PrevDayBal,
		&a.AcctOpenDate, &a.LastTranDate, &a.RestraintPresent, &a.CrBlocked,
		&a.Version, &a.GroupID, &a.ShardIndex,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, domain.NotFound("account not found: "+acctNo, nil)
	}
	if err != nil {
		return nil, mapErrIfPg(err)
	}
	return &a, nil
}

// ListAccountsByClient returns every wallet owned by a client (account profiles,
// no client PII), oldest-first. READ-ONLY: no TX, no audit GUCs. An existing
// client with no wallets returns an empty slice; an unknown client → 404.
func (r *PgWalletRepo) ListAccountsByClient(ctx context.Context, clientNo string) ([]domain.AccountView, error) {
	const q = `
		SELECT acct_no, client_no, acct_desc, acct_type, ccy, acct_status, acct_role,
		       actual_bal::text, total_restrained_amt::text, calc_bal::text,
		       prev_day_actual_bal::text, acct_open_date, last_tran_date,
		       restraint_present, cr_blocked, version, group_id, shard_index
		  FROM WLT_ACCT
		 WHERE client_no = $1
		 ORDER BY acct_open_date, acct_no
	`
	rows, err := r.readPool.Query(ctx, q, clientNo) // replica (lag-tolerant profile)
	if err != nil {
		return nil, mapErrIfPg(err)
	}
	defer rows.Close()

	out := make([]domain.AccountView, 0, 8)
	for rows.Next() {
		var a domain.AccountView
		if err := rows.Scan(
			&a.AcctNo, &a.ClientNo, &a.AcctDesc, &a.AcctType, &a.Ccy, &a.AcctStatus, &a.AcctRole,
			&a.ActualBal, &a.RestrainedAmt, &a.CalcBal, &a.PrevDayBal,
			&a.AcctOpenDate, &a.LastTranDate, &a.RestraintPresent, &a.CrBlocked,
			&a.Version, &a.GroupID, &a.ShardIndex,
		); err != nil {
			return nil, mapErrIfPg(err)
		}
		out = append(out, a)
	}
	if err := rows.Err(); err != nil {
		return nil, mapErrIfPg(err)
	}
	// Empty result: distinguish "no wallets" from "unknown client".
	if len(out) == 0 {
		var exists bool
		if err := r.readPool.QueryRow(ctx,
			`SELECT EXISTS(SELECT 1 FROM FM_CLIENT WHERE client_no = $1)`, clientNo,
		).Scan(&exists); err != nil {
			return nil, mapErrIfPg(err)
		}
		if !exists {
			return nil, domain.NotFound("client not found: "+clientNo, nil)
		}
	}
	return out, nil
}

// SearchAccounts finds accounts whose acct_no or client_no contains the query
// substring (case-insensitive), returning acct_no + client_no + the MASKED client
// name (v_client_masked). READ-ONLY (readPool, wallet_app); no PII. The caller
// enforces the minimum query length. Empty slice when nothing matches.
func (r *PgWalletRepo) SearchAccounts(ctx context.Context, query string, limit int) ([]domain.AccountSearchItem, error) {
	const sql = `
		SELECT a.acct_no, a.client_no, COALESCE(m.client_name_masked, '')
		  FROM WLT_ACCT a
		  LEFT JOIN v_client_masked m ON m.client_no = a.client_no
		 WHERE a.acct_no ILIKE '%' || $1 || '%'
		    OR a.client_no ILIKE '%' || $1 || '%'
		 ORDER BY a.acct_no
		 LIMIT $2
	`
	rows, err := r.readPool.Query(ctx, sql, query, limit)
	if err != nil {
		return nil, mapErrIfPg(err)
	}
	defer rows.Close()

	safeLimit := limit
	if safeLimit < 0 {
		safeLimit = 0
	}
	if safeLimit > domain.MaxAccountSearchSize {
		safeLimit = domain.MaxAccountSearchSize
	}

	out := make([]domain.AccountSearchItem, 0, safeLimit)
	for rows.Next() {
		var it domain.AccountSearchItem
		if err := rows.Scan(&it.AcctNo, &it.ClientNo, &it.Name); err != nil {
			return nil, mapErrIfPg(err)
		}
		out = append(out, it)
	}
	if err := rows.Err(); err != nil {
		return nil, mapErrIfPg(err)
	}
	return out, nil
}

// SearchAccountsFull is the UNMASKED account search (piiPool / wallet_pii_ro):
// matches acct_no, client_no OR the RAW client name, and returns the raw client
// name. Privileged P1/PII read — exposed only under /v1/ops. Empty slice when none.
func (r *PgWalletRepo) SearchAccountsFull(ctx context.Context, query string, limit int) ([]domain.AccountSearchItem, error) {
	const sql = `
		SELECT a.acct_no, a.client_no, COALESCE(c.client_name, '')
		  FROM WLT_ACCT a
		  LEFT JOIN FM_CLIENT c ON c.client_no = a.client_no
		 WHERE a.acct_no ILIKE '%' || $1 || '%'
		    OR a.client_no ILIKE '%' || $1 || '%'
		    OR c.client_name ILIKE '%' || $1 || '%'
		 ORDER BY a.acct_no
		 LIMIT $2
	`
	rows, err := r.piiPool.Query(ctx, sql, query, limit)
	if err != nil {
		return nil, mapErrIfPg(err)
	}
	defer rows.Close()
	out := make([]domain.AccountSearchItem, 0, min(limit, domain.MaxAccountSearchSize))
	for rows.Next() {
		var it domain.AccountSearchItem
		if err := rows.Scan(&it.AcctNo, &it.ClientNo, &it.Name); err != nil {
			return nil, mapErrIfPg(err)
		}
		out = append(out, it)
	}
	if err := rows.Err(); err != nil {
		return nil, mapErrIfPg(err)
	}
	return out, nil
}

// ListTransactions returns an account statement (one row per ledger leg that
// touched the account), newest-first, keyset-paginated by seq_no. An existing
// account with no entries returns an empty slice; an unknown account → 404.
func (r *PgWalletRepo) ListTransactions(ctx context.Context, q domain.TxListQuery) ([]domain.TxEntry, error) {
	// Defense-in-depth: bound user-influenced limit at allocation/query sink.
	safeLimit := q.Limit
	if safeLimit <= 0 {
		safeLimit = domain.DefaultTxPageSize
	}
	if safeLimit > domain.MaxTxPageSize {
		safeLimit = domain.MaxTxPageSize
	}

	// post_date range ($4/$5) also drives partition pruning on WLT_TRAN_HIST.
	const sql = `
		SELECT h.seq_no, h.tran_internal_id, h.tran_type, h.cr_dr_maint_ind,
		       h.tran_amt::text, h.ccy, h.actual_bal_amt::text,
		       h.post_date, h.value_date, h.reference,
		       COALESCE(h.tran_desc, ''), COALESCE(h.narrative, '')
		  FROM WLT_TRAN_HIST h
		  JOIN WLT_ACCT a ON a.internal_key = h.internal_key
		 WHERE a.acct_no = $1
		   AND ($2::bigint IS NULL OR h.seq_no < $2)
		   AND ($4::date  IS NULL OR h.post_date >= $4)
		   AND ($5::date  IS NULL OR h.post_date <= $5)
		 ORDER BY h.seq_no DESC
		 LIMIT $3
	`
	rows, err := r.readPool.Query(ctx, sql, q.AcctNo, q.BeforeSeq, safeLimit, q.From, q.To) // replica
	if err != nil {
		return nil, mapErrIfPg(err)
	}
	defer rows.Close()

	out := make([]domain.TxEntry, 0, safeLimit)
	for rows.Next() {
		var e domain.TxEntry
		if err := rows.Scan(
			&e.SeqNo, &e.TranInternalID, &e.TranType, &e.DRCR,
			&e.Amount, &e.Ccy, &e.BalanceAfter,
			&e.PostDate, &e.ValueDate, &e.Reference, &e.TranDesc, &e.Narrative,
		); err != nil {
			return nil, mapErrIfPg(err)
		}
		out = append(out, e)
	}
	if err := rows.Err(); err != nil {
		return nil, mapErrIfPg(err)
	}
	// Empty result: distinguish "no activity" from "unknown account".
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

// GetTransaction returns every leg of a transaction (by TRAN_INTERNAL_ID),
// ordered primary-leg-first. Unknown id → 404.
func (r *PgWalletRepo) GetTransaction(ctx context.Context, tranKey int64) ([]domain.TxLeg, error) {
	const sql = `
		SELECT h.tfr_seq_no, h.seq_no, h.internal_key, COALESCE(a.acct_no, ''),
		       h.tran_type, h.cr_dr_maint_ind, h.tran_amt::text, h.ccy,
		       h.actual_bal_amt::text, h.post_date, h.value_date,
		       h.reference, COALESCE(h.tran_desc, ''), COALESCE(h.narrative, ''),
		       COALESCE(h.metadata, '{}'::jsonb)
		  FROM WLT_TRAN_HIST h
		  LEFT JOIN WLT_ACCT a ON a.internal_key = h.internal_key
		 WHERE h.tran_internal_id = $1
		 ORDER BY h.tfr_seq_no NULLS FIRST, h.seq_no
	`
	rows, err := r.pool.Query(ctx, sql, tranKey)
	if err != nil {
		return nil, mapErrIfPg(err)
	}
	defer rows.Close()

	var out []domain.TxLeg
	for rows.Next() {
		var l domain.TxLeg
		if err := rows.Scan(
			&l.TFRSeqNo, &l.SeqNo, &l.InternalKey, &l.AcctNo,
			&l.TranType, &l.DRCR, &l.Amount, &l.Ccy,
			&l.BalanceAfter, &l.PostDate, &l.ValueDate, &l.Reference,
			&l.TranDesc, &l.Narrative, &l.Metadata,
		); err != nil {
			return nil, mapErrIfPg(err)
		}
		out = append(out, l)
	}
	if err := rows.Err(); err != nil {
		return nil, mapErrIfPg(err)
	}
	if len(out) == 0 {
		return nil, domain.NotFound("transaction not found: tran_internal_id", nil)
	}
	return out, nil
}
