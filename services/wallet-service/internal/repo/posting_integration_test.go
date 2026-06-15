package repo

// Integration tests for the synchronous posting paths (US-10.7). Each drives a
// repo method against the real SPs and reads the ledger back. See
// integration_helpers_test.go for the fixtures/assertions and
// onboard_integration_test.go for the DB harness (itRepo skips if no DB).

import (
	"context"
	"fmt"
	"net/http"
	"testing"

	"github.com/ewallet-pg/wallet-service/internal/domain"
)

// TestTopup_HappyPath_Integration — US-2.1: a top-up credits the wallet, writes
// one CR leg, a balanced GL journal, and an outbox event with the US-7.4 envelope.
func TestTopup_HappyPath_Integration(t *testing.T) {
	repo, pool := itRepo(t)
	ctx := context.Background()
	_, acctNo := newWallet(t, repo, pool)

	ref := fmt.Sprintf("IT-TOPUP-%d", uniqN())
	const amt = "100000.00"
	res, err := repo.Topup(ctx, domain.TopupInput{
		AcctNo: acctNo, Amount: amt, Reference: ref, Narrative: "it topup", Audit: itAudit(),
	})
	if err != nil {
		t.Fatalf("Topup: %v", err)
	}

	// Returned result.
	if res.Status != "SUCCESS" {
		t.Errorf("status = %q, want SUCCESS", res.Status)
	}
	if res.TranInternalID == 0 || res.EventUUID.String() == "" {
		t.Errorf("missing ids: %+v", res)
	}

	// Ledger effects.
	assertActualBal(t, pool, acctNo, amt)
	assertBalanced(t, pool, res.TranInternalID)
	assertOutbox(t, pool, ref, "wallet.topup.posted.v1")

	// Exactly one CR leg of TOPUP for this reference.
	if got := legCountForRef(t, pool, ref); got != 1 {
		t.Errorf("WLT_TRAN_HIST legs for ref = %d, want 1", got)
	}
	var crDr, tranType string
	if err := pool.QueryRow(ctx,
		`SELECT cr_dr_maint_ind, tran_type FROM wlt_tran_hist WHERE reference = $1`, ref).
		Scan(&crDr, &tranType); err != nil {
		t.Fatalf("read leg: %v", err)
	}
	if crDr != "CR" || tranType != "TOPUP" {
		t.Errorf("leg = %s/%s, want CR/TOPUP", crDr, tranType)
	}
}

// TestTopup_Idempotent_Integration — cross-cutting (Epic 2): re-posting the same
// reference returns DUPLICATE, writes no new legs, and leaves the balance fixed.
func TestTopup_Idempotent_Integration(t *testing.T) {
	repo, pool := itRepo(t)
	ctx := context.Background()
	_, acctNo := newWallet(t, repo, pool)

	ref := fmt.Sprintf("IT-TOPUP-IDEM-%d", uniqN())
	const amt = "250000.00"
	in := domain.TopupInput{AcctNo: acctNo, Amount: amt, Reference: ref, Audit: itAudit()}

	first, err := repo.Topup(ctx, in)
	if err != nil {
		t.Fatalf("Topup #1: %v", err)
	}
	second, err := repo.Topup(ctx, in)
	if err != nil {
		t.Fatalf("Topup #2 (retry): %v", err)
	}

	if second.Status != "DUPLICATE" {
		t.Errorf("retry status = %q, want DUPLICATE", second.Status)
	}
	if second.TranInternalID != first.TranInternalID {
		t.Errorf("retry tran_internal_id = %d, want %d (same)", second.TranInternalID, first.TranInternalID)
	}
	if got := legCountForRef(t, pool, ref); got != 1 {
		t.Errorf("legs after retry = %d, want 1 (no double-post)", got)
	}
	assertActualBal(t, pool, acctNo, amt) // credited once, not twice
}

// TestTopup_InvalidAmount_Integration — amount ≤ 0 → INVALID_AMOUNT / 400 (P0010).
func TestTopup_InvalidAmount_Integration(t *testing.T) {
	repo, pool := itRepo(t)
	_, acctNo := newWallet(t, repo, pool)

	_, err := repo.Topup(context.Background(), domain.TopupInput{
		AcctNo: acctNo, Amount: "0", Reference: fmt.Sprintf("IT-TOPUP-BAD-%d", uniqN()), Audit: itAudit(),
	})
	wantDomainCode(t, err, domain.CodeInvalidAmount, http.StatusBadRequest)
}

// TestTopup_AcctNotActive_Integration — topup to a blocked wallet →
// ACCT_NOT_ACTIVE / 403 (P0022). The account is blocked via update_account_status.
func TestTopup_AcctNotActive_Integration(t *testing.T) {
	repo, pool := itRepo(t)
	ctx := context.Background()
	_, acctNo := newWallet(t, repo, pool)

	if _, err := pool.Exec(ctx,
		`UPDATE wlt_acct SET acct_status = 'B' WHERE acct_no = $1`, acctNo); err != nil {
		t.Fatalf("block account: %v", err)
	}

	_, err := repo.Topup(ctx, domain.TopupInput{
		AcctNo: acctNo, Amount: "100000", Reference: fmt.Sprintf("IT-TOPUP-BLK-%d", uniqN()), Audit: itAudit(),
	})
	wantDomainCode(t, err, domain.CodeAcctNotActive, http.StatusForbidden)
}
