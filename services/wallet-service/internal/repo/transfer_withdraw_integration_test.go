package repo

// Integration tests for transfer (US-2.2) and withdraw (US-2.3) posting paths,
// plus restraint enforcement (US-8.2). See integration_helpers_test.go for the
// fixtures/assertions and onboard_integration_test.go for the DB harness.

import (
	"context"
	"fmt"
	"net/http"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/ewallet-pg/wallet-service/internal/domain"
)

// assertActualBalExpr proves wlt_acct.actual_bal equals the SQL numeric
// expression `expr` evaluated with args ($1 is acctNo; e.g.
// "$2::numeric - $3::numeric"). Used to prove fee/principal were deducted.
func assertActualBalExpr(t *testing.T, pool *pgxpool.Pool, acctNo, expr string, args ...any) {
	t.Helper()
	q := fmt.Sprintf(`SELECT actual_bal = (%s), actual_bal::text FROM wlt_acct WHERE acct_no = $1`, expr)
	var ok bool
	var got string
	if err := pool.QueryRow(context.Background(), q, args...).Scan(&ok, &got); err != nil {
		t.Fatalf("assertActualBalExpr(%s): %v", acctNo, err)
	}
	if !ok {
		t.Errorf("actual_bal(%s) = %s, want %s", acctNo, got, expr)
	}
}

// TestTransfer_HappyPath_Integration — US-2.2/2.5: a TRFOUT moves the principal
// to the receiver in full, debits sender principal+fee, posts a balanced GL
// journal (incl. fee revenue + VAT legs), and emits the transfer event.
func TestTransfer_HappyPath_Integration(t *testing.T) {
	repo, pool := itRepo(t)
	ctx := context.Background()
	const start = "10000000.00"
	_, from := fundedWallet(t, repo, pool, start)
	_, to := newWallet(t, repo, pool)

	ref := fmt.Sprintf("IT-TRF-%d", uniqN())
	const amt = "1000000.00"
	res, err := repo.Transfer(ctx, domain.TransferInput{
		FromAcctNo: from, ToAcctNo: to, Amount: amt, Reference: ref,
		TranType: "TRFOUT", Narrative: "it transfer", Audit: itAudit(),
	})
	if err != nil {
		t.Fatalf("Transfer: %v", err)
	}
	if res.Status != "SUCCESS" {
		t.Errorf("status = %q, want SUCCESS", res.Status)
	}
	if res.FeeGross == "" || res.FeeGross == "0" || res.FeeGross == "0.00" {
		t.Errorf("TRFOUT fee_gross = %q, want > 0", res.FeeGross)
	}

	// Receiver got the full principal; sender lost principal + fee_gross.
	assertActualBal(t, pool, to, amt)
	assertActualBalExpr(t, pool, from, "$2::numeric - $3::numeric - $4::numeric", from, start, amt, res.FeeGross)
	assertBalanced(t, pool, res.TranInternalID)
	assertOutbox(t, pool, ref, "wallet.transfer.posted.v1")
}

// TestTransfer_Free_Integration — TRFOUTF charges no fee: sender is debited
// exactly the principal, no fee/VAT.
func TestTransfer_Free_Integration(t *testing.T) {
	repo, pool := itRepo(t)
	ctx := context.Background()
	const start = "5000000.00"
	_, from := fundedWallet(t, repo, pool, start)
	_, to := newWallet(t, repo, pool)

	ref := fmt.Sprintf("IT-TRFF-%d", uniqN())
	const amt = "2000000.00"
	res, err := repo.Transfer(ctx, domain.TransferInput{
		FromAcctNo: from, ToAcctNo: to, Amount: amt, Reference: ref,
		TranType: "TRFOUTF", Audit: itAudit(),
	})
	if err != nil {
		t.Fatalf("Transfer (free): %v", err)
	}
	if !(res.FeeGross == "0" || res.FeeGross == "0.00" || res.FeeGross == "") {
		t.Errorf("TRFOUTF fee_gross = %q, want 0", res.FeeGross)
	}
	assertActualBal(t, pool, to, amt)
	assertActualBalExpr(t, pool, from, "$2::numeric - $3::numeric", from, start, amt)
	assertBalanced(t, pool, res.TranInternalID)
}

// TestTransfer_InsufficientFunds_Integration — debit exceeding calc_bal →
// INSUFFICIENT_FUNDS / 422.
func TestTransfer_InsufficientFunds_Integration(t *testing.T) {
	repo, pool := itRepo(t)
	_, from := fundedWallet(t, repo, pool, "100000.00")
	_, to := newWallet(t, repo, pool)

	_, err := repo.Transfer(context.Background(), domain.TransferInput{
		FromAcctNo: from, ToAcctNo: to, Amount: "1000000.00",
		Reference: fmt.Sprintf("IT-TRF-NSF-%d", uniqN()), TranType: "TRFOUT", Audit: itAudit(),
	})
	wantDomainCode(t, err, domain.CodeInsufficientFunds, http.StatusUnprocessableEntity)
}

// TestTransfer_SameAccount_Integration — from == to → SAME_ACCOUNT / 400.
func TestTransfer_SameAccount_Integration(t *testing.T) {
	repo, pool := itRepo(t)
	_, acct := fundedWallet(t, repo, pool, "1000000.00")

	_, err := repo.Transfer(context.Background(), domain.TransferInput{
		FromAcctNo: acct, ToAcctNo: acct, Amount: "10000.00",
		Reference: fmt.Sprintf("IT-TRF-SAME-%d", uniqN()), TranType: "TRFOUT", Audit: itAudit(),
	})
	wantDomainCode(t, err, domain.CodeSameAccount, http.StatusBadRequest)
}

// TestTransfer_DebitRestraintBlocksThenReleases_Integration — US-8.2: a full
// (zero-pledge) DEBIT restraint blocks the sender (DR_RESTRAINT_ACTIVE / 423);
// releasing it lets the same transfer through.
func TestTransfer_DebitRestraintBlocksThenReleases_Integration(t *testing.T) {
	repo, pool := itRepo(t)
	ctx := context.Background()
	_, from := fundedWallet(t, repo, pool, "5000000.00")
	_, to := newWallet(t, repo, pool)

	rs, err := repo.AddRestraint(ctx, domain.RestraintInput{
		AcctNo: from, Type: "DEBIT", Purpose: "FRAUD_WATCH", Narrative: "it freeze", Audit: itAudit(),
	})
	if err != nil {
		t.Fatalf("AddRestraint: %v", err)
	}

	in := domain.TransferInput{
		FromAcctNo: from, ToAcctNo: to, Amount: "100000.00",
		Reference: fmt.Sprintf("IT-TRF-RST-%d", uniqN()), TranType: "TRFOUT", Audit: itAudit(),
	}
	_, err = repo.Transfer(ctx, in)
	wantDomainCode(t, err, domain.CodeDRRestraintActive, http.StatusLocked)

	if _, err := repo.ReleaseRestraint(ctx, domain.ReleaseRestraintInput{
		RestraintID: rs.RestraintID, Reason: "it unfreeze", Audit: itAudit(),
	}); err != nil {
		t.Fatalf("ReleaseRestraint: %v", err)
	}
	if _, err := repo.Transfer(ctx, in); err != nil {
		t.Fatalf("Transfer after release: %v", err)
	}
	assertActualBal(t, pool, to, "100000.00")
}

// TestWithdraw_HappyPath_Integration — US-2.3: debits wallet (principal+fee),
// opens a SUBMITTED WLT_WITHDRAW_TRACK row, balanced GL (fee revenue + VAT),
// emits the withdraw event. Requires KYC tier ≥ 2.
func TestWithdraw_HappyPath_Integration(t *testing.T) {
	repo, pool := itRepo(t)
	ctx := context.Background()
	const start = "10000000.00"
	client, acct := fundedWallet(t, repo, pool, start)
	raiseTier(t, pool, client, "2")

	ref := fmt.Sprintf("IT-WD-%d", uniqN())
	const amt = "1000000.00"
	res, err := repo.Withdraw(ctx, domain.WithdrawInput{
		AcctNo: acct, Amount: amt, Reference: ref,
		ExtPayoutRef:    fmt.Sprintf("IT-PAYOUT-%d", uniqN()),
		BeneficiaryBank: "970436", BeneficiaryAcct: "0123456789",
		Narrative: "it withdraw", Audit: itAudit(),
	})
	if err != nil {
		t.Fatalf("Withdraw: %v", err)
	}
	if res.Status != "SUCCESS" {
		t.Errorf("status = %q, want SUCCESS", res.Status)
	}
	if res.FeeGross == "" || res.FeeGross == "0" || res.FeeGross == "0.00" {
		t.Errorf("withdraw fee_gross = %q, want > 0", res.FeeGross)
	}

	assertActualBalExpr(t, pool, acct, "$2::numeric - $3::numeric - $4::numeric", acct, start, amt, res.FeeGross)
	assertBalanced(t, pool, res.TranInternalID)
	assertOutbox(t, pool, ref, "wallet.withdraw.posted.v1")

	var status string
	if err := pool.QueryRow(ctx,
		`SELECT status FROM wlt_withdraw_track WHERE acct_no = $1`, acct).Scan(&status); err != nil {
		t.Fatalf("read withdraw_track: %v", err)
	}
	if status != "SUBMITTED" {
		t.Errorf("withdraw_track status = %q, want SUBMITTED", status)
	}
}

// TestWithdraw_TierInsufficient_Integration — withdraw needs tier ≥ 2; a freshly
// onboarded (tier 1) wallet → TIER_INSUFFICIENT / 403.
func TestWithdraw_TierInsufficient_Integration(t *testing.T) {
	repo, pool := itRepo(t)
	_, acct := fundedWallet(t, repo, pool, "10000000.00") // tier stays 1

	_, err := repo.Withdraw(context.Background(), domain.WithdrawInput{
		AcctNo: acct, Amount: "1000000.00", Reference: fmt.Sprintf("IT-WD-TIER-%d", uniqN()),
		ExtPayoutRef:    fmt.Sprintf("IT-PAYOUT-%d", uniqN()),
		BeneficiaryBank: "970436", BeneficiaryAcct: "0123456789", Audit: itAudit(),
	})
	wantDomainCode(t, err, domain.CodeTierInsufficient, http.StatusForbidden)
}

// TestWithdraw_InsufficientFunds_Integration — principal+fee exceeding calc_bal →
// INSUFFICIENT_FUNDS / 422 (tier raised so the tier gate passes first).
func TestWithdraw_InsufficientFunds_Integration(t *testing.T) {
	repo, pool := itRepo(t)
	client, acct := fundedWallet(t, repo, pool, "100000.00")
	raiseTier(t, pool, client, "2")

	_, err := repo.Withdraw(context.Background(), domain.WithdrawInput{
		AcctNo: acct, Amount: "1000000.00", Reference: fmt.Sprintf("IT-WD-NSF-%d", uniqN()),
		ExtPayoutRef:    fmt.Sprintf("IT-PAYOUT-%d", uniqN()),
		BeneficiaryBank: "970436", BeneficiaryAcct: "0123456789", Audit: itAudit(),
	})
	wantDomainCode(t, err, domain.CodeInsufficientFunds, http.StatusUnprocessableEntity)
}
