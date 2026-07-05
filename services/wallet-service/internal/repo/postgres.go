// Package repo implements WalletRepository against PostgreSQL via pgxpool.
// Every method opens a transaction, sets audit.* + app.trace_id GUCs via
// SET LOCAL, calls the corresponding SP, then commits.
package repo

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math/rand"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/ewallet-pg/wallet-service/internal/domain"
)

// PgWalletRepo is a WalletRepository backed by pgxpool.
//
// statementTimeoutMs / lockTimeoutMs are applied per-TX via SET LOCAL.
// AfterConnect-level SET is unreliable through PgBouncer transaction mode
// because consecutive TXs may be routed to different server connections;
// SET LOCAL is scoped to the current TX so it always takes effect.
type PgWalletRepo struct {
	pool               *pgxpool.Pool
	readPool           *pgxpool.Pool // replica for lag-tolerant reads (no TX, no retry); == pool when no DB_READ_DSN
	piiPool            *pgxpool.Pool // wallet_pii_ro conn for unmasked PII reads; == pool when no DB_PII_DSN
	statementTimeoutMs int64
	lockTimeoutMs      int64
	txMaxRetries       int    // retries of a RETRYABLE write conflict; 0 = no retry
	piiDEK             string // PII data-encryption key (KMS-injected); set per-TX as app.pii_dek. Never persisted DB-side.
}

// NewPgWalletRepo wires the write pool (primary), a read pool, and a PII pool.
// Pass the same pool when there is no replica / no dedicated PII role; a nil
// readPool or piiPool falls back to pool. readPool serves lag-tolerant reads
// (see transaction.go); piiPool (role wallet_pii_ro) serves the unmasked client
// read (see client.go).
//
// txMaxRetries bounds the server-side retry of serialization/deadlock conflicts
// (SQLSTATE 40001 / 40P01). 0 = no retry (the conflict is returned to the
// caller as a retryable 409). A negative value is clamped to 0.
//
// piiDEK is the KMS-injected PII data-encryption key. It is set per-TX via
// set_config('app.pii_dek', …, is_local=true) on both write TXs (withTx) and
// PII-decrypting read TXs (readWithDEK) so pgcrypto can en/decrypt without the
// key ever being persisted in pg_db_role_setting. May be "" in dev where no PII
// path is exercised; the SP guard then raises PII_DEK_NOT_SET on any PII op.
func NewPgWalletRepo(pool, readPool, piiPool *pgxpool.Pool, statementTimeout, lockTimeout time.Duration, txMaxRetries int, piiDEK string) *PgWalletRepo {
	if readPool == nil {
		readPool = pool
	}
	if piiPool == nil {
		piiPool = pool
	}
	if txMaxRetries < 0 {
		txMaxRetries = 0
	}
	return &PgWalletRepo{
		pool:               pool,
		readPool:           readPool,
		piiPool:            piiPool,
		statementTimeoutMs: statementTimeout.Milliseconds(),
		lockTimeoutMs:      lockTimeout.Milliseconds(),
		txMaxRetries:       txMaxRetries,
		piiDEK:             piiDEK,
	}
}

// withTx runs the operation as a single TX and, when txMaxRetries > 0,
// transparently re-runs it on a RETRYABLE conflict (VERSION_CONFLICT /
// deadlock, i.e. SQLSTATE 40001 / 40P01) up to txMaxRetries extra times with a
// small jittered backoff. Each attempt is a fresh TX on a fresh snapshot, and
// posting SPs are idempotent (WLT_API_MESSAGE gate), so a retry cannot
// double-post. Non-retryable errors return immediately; ctx cancellation
// between attempts fails fast.
//
// Default (txMaxRetries = 0) is NO retry: a single attempt, with the conflict
// returned to the caller as a retryable 409 — identical to the prior behaviour.
// Enabling retries absorbs hot-account optimistic-CAS churn (Tet/payday peaks)
// server-side so callers mostly see success instead of a 409 storm.
func (r *PgWalletRepo) withTx(
	ctx context.Context, audit domain.AuditContext,
	fn func(tx pgx.Tx) error,
) error {
	var err error
	for attempt := 0; ; attempt++ {
		err = r.runTx(ctx, audit, fn)
		if err == nil {
			return nil
		}
		// Retry only retryable conflicts, only while budget + ctx remain.
		var de *domain.Error
		if attempt >= r.txMaxRetries || ctx.Err() != nil ||
			!errors.As(err, &de) || !de.IsRetriable() {
			return err
		}
		// Backoff grows per attempt with up to ~5ms jitter to de-correlate
		// concurrent retriers; bail early if the caller's deadline fires.
		backoff := time.Duration(attempt+1)*5*time.Millisecond +
			time.Duration(rand.Int63n(int64(5*time.Millisecond)))
		select {
		case <-ctx.Done():
			return err
		case <-time.After(backoff):
		}
	}
}

// runTx opens a TX, sets audit GUCs, runs fn, commits on success — one attempt.
//
// Rollback discipline:
//   - The deferred Rollback runs UNCONDITIONALLY, on every exit path.
//   - It uses a FRESH context with a short cleanup deadline, NOT the caller's
//     ctx. The caller's ctx may already be cancelled (timeout case), and we
//     still need a usable ctx to send the ROLLBACK wire message. If cleanup
//     itself fails, pgx will mark the connection as broken and close it on
//     pool return — the wallet's data integrity is preserved either way.
//   - Successful Commit makes Rollback a no-op (PG returns ErrTxClosed).
//
// Error mapping: any error escaping the SP or pgx is run through mapPgError
// so the caller always receives a *domain.Error (TIMEOUT for ctx / lock /
// statement timeout, INTERNAL for everything else).
func (r *PgWalletRepo) runTx(
	ctx context.Context, audit domain.AuditContext,
	fn func(tx pgx.Tx) error,
) error {
	tx, err := r.pool.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return mapPgError(err)
	}
	defer func() {
		// Fresh ctx so cleanup runs even if caller's ctx is already cancelled.
		cleanupCtx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		_ = tx.Rollback(cleanupCtx)
	}()

	// SET LOCAL the timeouts — guaranteed per-TX even through PgBouncer txn mode.
	// Values come from validated config (time.Duration), no SQL injection risk.
	if _, err := tx.Exec(ctx, fmt.Sprintf(
		"SET LOCAL statement_timeout = %d; SET LOCAL lock_timeout = %d",
		r.statementTimeoutMs, r.lockTimeoutMs)); err != nil {
		return mapPgError(err)
	}
	if err := setAuditGUCs(ctx, tx, audit, r.piiDEK); err != nil {
		return mapPgError(err)
	}
	if err := fn(tx); err != nil {
		return mapPgError(err)
	}
	if err := tx.Commit(ctx); err != nil {
		return mapPgError(err)
	}
	return nil
}

// setAuditGUCs publishes the per-request audit context into the TX so the
// BEFORE INSERT/UPDATE trigger trg_audit_cols (and the client-info audit
// trigger fn_audit_client_change) can pick it up via current_setting().
//
// SELECT set_config(name, value, is_local=true) is the SP-safe way to do
// SET LOCAL since PgBouncer in transaction-mode can hand the connection to
// another client immediately after COMMIT — `is_local=true` guarantees the
// setting is scoped to the current TX only.
//
// It ALSO sets app.pii_dek in the SAME batch (7th set_config): the write SPs
// (onboard_client, link_client_bank, post_withdraw, …) pgp_sym_encrypt PII with
// current_setting('app.pii_dek'). It MUST be per-TX (is_local) for the exact same
// reason as the audit GUCs — PgBouncer transaction-mode may hand this server
// connection to another client right after COMMIT, so a session/DB-level value is
// unreliable. This replaces the persisted `ALTER DATABASE … SET app.pii_dek`,
// which stored the DEK in pg_db_role_setting readable by every role.
func setAuditGUCs(ctx context.Context, tx pgx.Tx, a domain.AuditContext, dek string) error {
	const q = `
		SELECT
		  set_config('audit.actor',      $1, true),
		  set_config('audit.channel',    $2, true),
		  set_config('audit.request_id', $3, true),
		  set_config('audit.ip',         $4, true),
		  set_config('audit.user_agent', $5, true),
		  set_config('app.trace_id',     $6, true),
		  set_config('app.pii_dek',      $7, true)
	`
	// app.trace_id carries the FULL W3C traceparent (the posting SPs copy it into
	// WLT_OUTBOX.HEADERS->>'traceparent'), so a downstream relay/consumer can
	// EXTRACT a valid parent and continue the trace. Fall back to the bare
	// trace-id when no traceparent is available (OTel off / unsampled).
	traceparent := a.TraceParent
	if traceparent == "" {
		traceparent = a.TraceID
	}
	_, err := tx.Exec(ctx, q,
		a.Actor, string(a.Channel), a.RequestID, a.IPAddress, a.UserAgent, traceparent, dek)
	return err
}

// readWithDEK runs a PII-DECRYPTING read inside a single read-only TX with the
// per-TX PII DEK established FIRST (set_config('app.pii_dek', …, is_local=true)),
// so a query that calls pgp_sym_decrypt(…, current_setting('app.pii_dek')) — or a
// masked view that does the same to show last-4 — can see the key in the SAME TX.
//
// Read paths bypass withTx (no audit GUCs, no business TX), but the DEK is now
// app-held and per-TX (never persisted DB-side), so every decrypt read MUST wrap
// itself here — a bare pool.Query would run on a connection with no app.pii_dek
// (PgBouncer transaction-mode) and fail. Mirrors withTx's rollback discipline:
// the deferred Rollback uses a fresh ctx so cleanup always reaches the server.
func (r *PgWalletRepo) readWithDEK(ctx context.Context, pool *pgxpool.Pool, fn func(tx pgx.Tx) error) error {
	tx, err := pool.BeginTx(ctx, pgx.TxOptions{AccessMode: pgx.ReadOnly})
	if err != nil {
		return mapPgError(err)
	}
	defer func() {
		cleanupCtx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		_ = tx.Rollback(cleanupCtx)
	}()
	if _, err := tx.Exec(ctx, "SELECT set_config('app.pii_dek', $1, true)", r.piiDEK); err != nil {
		return mapPgError(err)
	}
	if err := fn(tx); err != nil {
		return err
	}
	if err := tx.Commit(ctx); err != nil {
		return mapPgError(err)
	}
	return nil
}

// ------------ post_topup ------------------------------------------------------

func (r *PgWalletRepo) Topup(ctx context.Context, in domain.TopupInput) (*domain.TopupResult, error) {
	var out domain.TopupResult
	metaJSON, err := json.Marshal(withNarrative(in.Metadata, in.Narrative))
	if err != nil {
		return nil, domain.InvalidRequest("metadata not serialisable", err)
	}

	err = r.withTx(ctx, in.Audit, func(tx pgx.Tx) error {
		const q = `
			SELECT tran_internal_id, status, new_balance, event_uuid
			  FROM post_topup($1, $2::numeric, $3, $4::jsonb, $5, $6)
		`
		row := tx.QueryRow(ctx, q,
			in.AcctNo, in.Amount, in.Reference, string(metaJSON),
			string(in.Audit.Channel), in.Audit.Actor)
		return scanTopupResult(row, &out)
	})
	if err != nil {
		return nil, mapErrIfPg(err)
	}
	return &out, nil
}

func scanTopupResult(row pgx.Row, out *domain.TopupResult) error {
	var amt string
	var uu uuid.UUID
	if err := row.Scan(&out.TranInternalID, &out.Status, &amt, &uu); err != nil {
		return err
	}
	out.NewBalance = amt
	out.EventUUID = uu
	return nil
}

// ------------ post_transfer --------------------------------------------------

func (r *PgWalletRepo) Transfer(ctx context.Context, in domain.TransferInput) (*domain.TransferResult, error) {
	var out domain.TransferResult
	metaJSON, err := json.Marshal(withNarrative(in.Metadata, in.Narrative))
	if err != nil {
		return nil, domain.InvalidRequest("metadata not serialisable", err)
	}
	tranType := in.TranType
	if tranType == "" {
		tranType = "TRFOUT" // SP default; passed explicitly since param is positional
	}

	err = r.withTx(ctx, in.Audit, func(tx pgx.Tx) error {
		const q = `
			SELECT tran_internal_id, status, new_balance_from, new_balance_to,
			       fee_gross, vat_amount, event_uuid
			  FROM post_transfer($1, $2, $3::numeric, $4, $5, $6::jsonb, $7, $8)
		`
		row := tx.QueryRow(ctx, q,
			in.FromAcctNo, in.ToAcctNo, in.Amount, in.Reference,
			tranType, string(metaJSON), string(in.Audit.Channel), in.Audit.Actor)
		return scanTransferResult(row, &out)
	})
	if err != nil {
		return nil, mapErrIfPg(err)
	}
	return &out, nil
}

func scanTransferResult(row pgx.Row, out *domain.TransferResult) error {
	var nbF, nbT, fee, vat string
	var uu uuid.UUID
	if err := row.Scan(&out.TranInternalID, &out.Status, &nbF, &nbT, &fee, &vat, &uu); err != nil {
		return err
	}
	out.NewBalanceFrom, out.NewBalanceTo = nbF, nbT
	out.FeeGross, out.VATAmount = fee, vat
	out.EventUUID = uu
	return nil
}

// ------------ post_withdraw --------------------------------------------------

func (r *PgWalletRepo) Withdraw(ctx context.Context, in domain.WithdrawInput) (*domain.WithdrawResult, error) {
	var out domain.WithdrawResult
	metaJSON, err := json.Marshal(withNarrative(in.Metadata, in.Narrative))
	if err != nil {
		return nil, domain.InvalidRequest("metadata not serialisable", err)
	}

	err = r.withTx(ctx, in.Audit, func(tx pgx.Tx) error {
		const q = `
			SELECT tran_internal_id, status, new_balance, fee_gross, vat_amount, event_uuid
			  FROM post_withdraw($1, $2::numeric, $3, $4, $5, $6, $7::jsonb, $8, $9)
		`
		row := tx.QueryRow(ctx, q,
			in.AcctNo, in.Amount, in.Reference, in.ExtPayoutRef,
			in.BeneficiaryBank, in.BeneficiaryAcct,
			string(metaJSON), string(in.Audit.Channel), in.Audit.Actor)
		return scanWithdrawResult(row, &out)
	})
	if err != nil {
		return nil, mapErrIfPg(err)
	}
	return &out, nil
}

func scanWithdrawResult(row pgx.Row, out *domain.WithdrawResult) error {
	var nb, fee, vat string
	var uu uuid.UUID
	if err := row.Scan(&out.TranInternalID, &out.Status, &nb, &fee, &vat, &uu); err != nil {
		return err
	}
	out.NewBalance, out.FeeGross, out.VATAmount = nb, fee, vat
	out.EventUUID = uu
	return nil
}

// ------------ post_merchant_withdraw -----------------------------------------

func (r *PgWalletRepo) MerchantWithdraw(ctx context.Context, in domain.MerchantWithdrawInput) (*domain.MerchantWithdrawResult, error) {
	var out domain.MerchantWithdrawResult
	var extRef *string
	if in.ExtPayoutRef != "" {
		extRef = &in.ExtPayoutRef
	}

	err := r.withTx(ctx, in.Audit, func(tx pgx.Tx) error {
		const q = `
			SELECT tran_internal_id, status, amount, fee_gross, vat_amount,
			       total_deducted, settlement_balance_after, event_uuid
			  FROM post_merchant_withdraw($1, $2::numeric, $3, $4, $5, $6, $7)
		`
		row := tx.QueryRow(ctx, q,
			in.GroupID, in.Amount, in.Reference, extRef, in.AutoSweep,
			string(in.Audit.Channel), in.Audit.Actor)
		// tran_internal_id + event_uuid are NULL on the SETTLEMENT_SWEEP_REQUIRED branch.
		var tran *int64
		var uu *uuid.UUID
		var amt, fee, vat, total, settle string
		if err := row.Scan(&tran, &out.Status, &amt, &fee, &vat, &total, &settle, &uu); err != nil {
			return err
		}
		if tran != nil {
			out.TranInternalID = *tran
		}
		if uu != nil {
			out.EventUUID = *uu
		}
		out.Amount, out.FeeGross, out.VATAmount = amt, fee, vat
		out.TotalDeducted, out.SettlementBalanceAfter = total, settle
		return nil
	})
	if err != nil {
		return nil, mapErrIfPg(err)
	}
	return &out, nil
}

// ------------ post_withdraw_reversal -----------------------------------------

func (r *PgWalletRepo) Reverse(ctx context.Context, in domain.ReversalInput) (*domain.ReversalResult, error) {
	var out domain.ReversalResult
	err := r.withTx(ctx, in.Audit, func(tx pgx.Tx) error {
		const q = `
			SELECT reversal_tran_key, was_already_reversed, event_uuid
			  FROM post_withdraw_reversal($1, $2, $3, $4, $5, $6)
		`
		row := tx.QueryRow(ctx, q,
			in.ExtPayoutRef, in.FailCode, in.FailReason, in.Initiator,
			string(in.Audit.Channel), in.Audit.Actor)
		var uu *uuid.UUID
		if err := row.Scan(&out.ReversalTranKey, &out.WasAlreadyReversed, &uu); err != nil {
			return err
		}
		if uu != nil {
			out.EventUUID = *uu
		}
		return nil
	})
	if err != nil {
		return nil, mapErrIfPg(err)
	}
	return &out, nil
}

// ------------ mark_withdraw_acked --------------------------------------------

func (r *PgWalletRepo) MarkAcked(ctx context.Context, in domain.AckInput) (*domain.MarkResult, error) {
	return r.markGeneric(ctx, in.Audit, func(tx pgx.Tx) (*domain.MarkResult, error) {
		const q = `
			SELECT acct_no, status, event_uuid
			  FROM mark_withdraw_acked($1, $2, $3, $4)
		`
		row := tx.QueryRow(ctx, q, in.ExtPayoutRef, in.TreasuryBatchID,
			string(in.Audit.Channel), in.Audit.Actor)
		return scanMarkResult(row)
	})
}

func (r *PgWalletRepo) MarkDisbursing(ctx context.Context, in domain.DisbursingInput) (*domain.MarkResult, error) {
	return r.markGeneric(ctx, in.Audit, func(tx pgx.Tx) (*domain.MarkResult, error) {
		const q = `
			SELECT acct_no, status, event_uuid
			  FROM mark_withdraw_disbursing($1, $2, $3)
		`
		row := tx.QueryRow(ctx, q, in.ExtPayoutRef,
			string(in.Audit.Channel), in.Audit.Actor)
		return scanMarkResult(row)
	})
}

func (r *PgWalletRepo) MarkCompleted(ctx context.Context, in domain.CompletedInput) (*domain.MarkResult, error) {
	return r.markGeneric(ctx, in.Audit, func(tx pgx.Tx) (*domain.MarkResult, error) {
		const q = `
			SELECT acct_no, status, event_uuid
			  FROM mark_withdraw_completed($1, $2, $3, $4)
		`
		row := tx.QueryRow(ctx, q, in.ExtPayoutRef, in.NapasRef,
			string(in.Audit.Channel), in.Audit.Actor)
		return scanMarkResult(row)
	})
}

func (r *PgWalletRepo) markGeneric(
	ctx context.Context, audit domain.AuditContext,
	fn func(tx pgx.Tx) (*domain.MarkResult, error),
) (*domain.MarkResult, error) {
	var out *domain.MarkResult
	err := r.withTx(ctx, audit, func(tx pgx.Tx) error {
		res, err := fn(tx)
		if err != nil {
			return err
		}
		out = res
		return nil
	})
	if err != nil {
		return nil, mapErrIfPg(err)
	}
	return out, nil
}

func scanMarkResult(row pgx.Row) (*domain.MarkResult, error) {
	var out domain.MarkResult
	var uu *uuid.UUID
	if err := row.Scan(&out.AcctNo, &out.Status, &uu); err != nil {
		return nil, err
	}
	if uu != nil {
		out.EventUUID = *uu
	}
	return &out, nil
}

// ------------ helpers --------------------------------------------------------

func orEmpty(m map[string]any) map[string]any {
	if m == nil {
		return map[string]any{}
	}
	return m
}

// withNarrative returns a metadata map carrying the request narrative under the
// "narrative" key, which the posting SPs read via p_metadata->>'narrative' and
// persist to WLT_TRAN_HIST.NARRATIVE. An explicit narrative wins over any
// "narrative" already present in metadata. Empty narrative → metadata unchanged.
func withNarrative(m map[string]any, narrative string) map[string]any {
	out := orEmpty(m)
	if narrative == "" {
		return out
	}
	// copy-on-write so we never mutate the caller's map
	merged := make(map[string]any, len(out)+1)
	for k, v := range out {
		merged[k] = v
	}
	merged["narrative"] = narrative
	return merged
}

// mapErrIfPg ensures any error escaping the repo is a *domain.Error.
// It's defensive: withTx already maps the pg-level error, but scan/marshal
// errors slip through and we want a uniform contract.
func mapErrIfPg(err error) error {
	if err == nil {
		return nil
	}
	var de *domain.Error
	if errors.As(err, &de) {
		return err
	}
	mapped := mapPgError(err)
	if mapped != nil {
		return mapped
	}
	return domain.Internal(fmt.Errorf("repo: %w", err))
}
