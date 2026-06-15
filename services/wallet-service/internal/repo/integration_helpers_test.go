package repo

// Shared fixtures + ledger assertions for the posting-path integration tests
// (US-10.7). These run the real stored procedures against a live PostgreSQL and
// read the ledger back to prove the double-entry, balance, and outbox effects.
//
// They build on the harness in onboard_integration_test.go (itRepo, dropClient,
// itAudit, uniqN, phoneFrom, wantDomainCode) — same package, so no exports. If
// no DB is reachable every test SKIPs, so `go test ./...` stays green without a
// stack. The DB-backed CI job (ci.yml: go-integration) is where these execute.
//
//	docker compose up -d
//	WALLET_TEST_DSN=postgres://postgres:postgres_dev_only@localhost:5432/wallet?sslmode=disable \
//	  go test -race -run Integration ./internal/repo/...

import (
	"context"
	"fmt"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/ewallet-pg/wallet-service/internal/domain"
)

// newWallet onboards a fresh CONSUMER client + zero-balance STANDALONE wallet
// (US-1.1) and returns (clientNo, acctNo). It registers both the client-master
// cleanup (dropClient) and the ledger cleanup (dropLedgerFor); cleanups run
// LIFO, so the ledger rows are removed before the account/client rows.
func newWallet(t *testing.T, repo *PgWalletRepo, pool *pgxpool.Pool) (clientNo, acctNo string) {
	t.Helper()
	ctx := context.Background()
	n := uniqN()
	in := domain.OnboardInput{
		ClientName: "IT POSTING TEST", ClientType: "IND", Phone: phoneFrom(n),
		GlobalID: fmt.Sprintf("IT%013d", n), GlobalIDType: "CCCD", Email: "it@test.vn",
		CountryLoc: "VN", CountryCitizen: "VN", AcctType: "CONSUMER", Ccy: "VND",
		BirthDate: "1990-05-15", Sex: "M",
		DateIssue: "2018-01-02", ExpireDate: "2030-01-01", PlaceIssue: "CA Ha Noi",
		ExtraData: map[string]any{"surname": "IT", "given_name": "POSTING"},
		Audit:     itAudit(),
	}
	res, err := repo.OnboardClient(ctx, in)
	if err != nil {
		t.Fatalf("newWallet: OnboardClient: %v", err)
	}
	// Register account/client cleanup FIRST so (LIFO) it runs AFTER the ledger
	// cleanup registered by dropLedgerFor below.
	dropClient(t, pool, res.ClientNo)
	dropLedgerFor(t, pool, res.AcctNo)
	return res.ClientNo, res.AcctNo
}

// fundedWallet onboards a wallet (newWallet) and tops it up to `amount` (a decimal
// string ≥ the TOPUP minimum), so callers that test transfer/withdraw/fee-charge
// start from a known non-zero balance. Returns (clientNo, acctNo).
func fundedWallet(t *testing.T, repo *PgWalletRepo, pool *pgxpool.Pool, amount string) (clientNo, acctNo string) {
	t.Helper()
	clientNo, acctNo = newWallet(t, repo, pool)
	ref := fmt.Sprintf("IT-FUND-%d", uniqN())
	if _, err := repo.Topup(context.Background(), domain.TopupInput{
		AcctNo: acctNo, Amount: amount, Reference: ref, Narrative: "it fund", Audit: itAudit(),
	}); err != nil {
		t.Fatalf("fundedWallet: Topup(%s): %v", amount, err)
	}
	return clientNo, acctNo
}

// raiseTier bumps a client's KYC tier directly (withdraw requires tier ≥ 2,
// P0023). Test-only shortcut around the full update_kyc flow.
func raiseTier(t *testing.T, pool *pgxpool.Pool, clientNo, tier string) {
	t.Helper()
	if _, err := pool.Exec(context.Background(),
		`UPDATE fm_client_kyc SET kyc_tier = $2 WHERE client_no = $1`, clientNo, tier); err != nil {
		t.Fatalf("raiseTier(%s,%s): %v", clientNo, tier, err)
	}
}

// dropLedgerFor registers a t.Cleanup that removes every ledger row this account
// produced — WLT_TRAN_HIST, WLT_GL_BATCH (by reference AND acct, so GL-only fee/
// VAT legs go too), WLT_ACCT_BAL, WLT_OUTBOX (matched by any acct field in the
// payload, since transfer keys partition_key on tran_id not acct_no), and
// WLT_WITHDRAW_TRACK — plus the WLT_API_MESSAGE idempotency rows. The account row
// itself is left for dropClient.
func dropLedgerFor(t *testing.T, pool *pgxpool.Pool, acctNo string) {
	t.Helper()
	t.Cleanup(func() {
		ctx := context.Background()
		const ik = `(SELECT internal_key FROM wlt_acct WHERE acct_no = $1)`
		const refsOnAcct = `SELECT reference FROM wlt_tran_hist WHERE internal_key = ` + ik
		// Reference-keyed rows first, while the history still exists.
		_, _ = pool.Exec(ctx, `DELETE FROM wlt_api_message WHERE object_ref_id IN (`+refsOnAcct+`)`, acctNo)
		_, _ = pool.Exec(ctx, `DELETE FROM wlt_gl_batch    WHERE reference     IN (`+refsOnAcct+`)`, acctNo)
		for _, q := range []string{
			`DELETE FROM wlt_outbox WHERE partition_key = $1
			    OR payload->>'acct_no' = $1 OR payload->>'from_acct' = $1 OR payload->>'to_acct' = $1`,
			`DELETE FROM wlt_withdraw_track WHERE acct_no = $1`,
			`DELETE FROM wlt_tran_hist  WHERE internal_key      = ` + ik,
			`DELETE FROM wlt_gl_batch   WHERE acct_internal_key = ` + ik,
			`DELETE FROM wlt_acct_bal   WHERE internal_key      = ` + ik,
		} {
			_, _ = pool.Exec(ctx, q, acctNo)
		}
	})
}

// assertBalanced proves the GL journal for one transaction balances: over all
// WLT_GL_BATCH legs sharing this tran_key (= tran_internal_id), ΣDR == ΣCR and
// the total is non-zero. This is the canonical double-entry invariant; the
// customer-side WLT_TRAN_HIST holds only the wallet legs (the contra is a GL leg).
func assertBalanced(t *testing.T, pool *pgxpool.Pool, tranInternalID int64) {
	t.Helper()
	var dr, cr float64
	err := pool.QueryRow(context.Background(), `
		SELECT COALESCE(SUM(amount) FILTER (WHERE tran_nature = 'DR'), 0),
		       COALESCE(SUM(amount) FILTER (WHERE tran_nature = 'CR'), 0)
		  FROM wlt_gl_batch WHERE tran_key = $1`, tranInternalID).Scan(&dr, &cr)
	if err != nil {
		t.Fatalf("assertBalanced(%d): query: %v", tranInternalID, err)
	}
	if dr == 0 && cr == 0 {
		t.Errorf("assertBalanced(%d): no GL legs found", tranInternalID)
	}
	if dr != cr {
		t.Errorf("assertBalanced(%d): GL unbalanced ΣDR=%.2f ΣCR=%.2f", tranInternalID, dr, cr)
	}
}

// assertOutbox proves exactly one WLT_OUTBOX row was emitted for `reference`
// with the expected event_type, and that the US-7.4 envelope (payload.meta) was
// stamped by trg_outbox_envelope.
func assertOutbox(t *testing.T, pool *pgxpool.Pool, reference, eventType string) {
	t.Helper()
	var n int
	var gotType string
	var hasMeta bool
	err := pool.QueryRow(context.Background(), `
		SELECT count(*),
		       COALESCE(max(event_type) FILTER (WHERE event_type = $2), ''),
		       COALESCE(bool_and(payload ? 'meta'), false)
		  FROM wlt_outbox WHERE payload->>'reference' = $1`, reference, eventType).
		Scan(&n, &gotType, &hasMeta)
	if err != nil {
		t.Fatalf("assertOutbox(%s): query: %v", reference, err)
	}
	if n == 0 {
		t.Errorf("assertOutbox(%s): no outbox row", reference)
		return
	}
	if gotType != eventType {
		t.Errorf("assertOutbox(%s): event_type = %q, want %q", reference, gotType, eventType)
	}
	if !hasMeta {
		t.Errorf("assertOutbox(%s): payload.meta envelope missing (US-7.4)", reference)
	}
}

// assertActualBal proves wlt_acct.actual_bal equals `want` (numeric equality in
// SQL, so "100000" and "100000.00" compare equal).
func assertActualBal(t *testing.T, pool *pgxpool.Pool, acctNo, want string) {
	t.Helper()
	var ok bool
	var got string
	err := pool.QueryRow(context.Background(),
		`SELECT actual_bal = $2::numeric, actual_bal::text FROM wlt_acct WHERE acct_no = $1`,
		acctNo, want).Scan(&ok, &got)
	if err != nil {
		t.Fatalf("assertActualBal(%s): query: %v", acctNo, err)
	}
	if !ok {
		t.Errorf("assertActualBal(%s): actual_bal = %s, want %s", acctNo, got, want)
	}
}

// legCountForRef counts WLT_TRAN_HIST rows carrying `reference` (used to prove
// idempotent retries write no new legs).
func legCountForRef(t *testing.T, pool *pgxpool.Pool, reference string) int {
	t.Helper()
	var n int
	if err := pool.QueryRow(context.Background(),
		`SELECT count(*) FROM wlt_tran_hist WHERE reference = $1`, reference).Scan(&n); err != nil {
		t.Fatalf("legCountForRef(%s): query: %v", reference, err)
	}
	return n
}
