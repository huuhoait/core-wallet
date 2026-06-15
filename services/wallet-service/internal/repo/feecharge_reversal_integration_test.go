package repo

// Integration tests for standalone fee charge (US-2.8) and the four reversal
// paths (US-3.1/3.2/3.3 + fee reversal), including idempotency (US-3.5) and the
// reversal window (US-3.6, REVERSAL_WINDOW_EXPIRED / P0060 / 422). See
// integration_helpers_test.go for fixtures and onboard_integration_test.go for
// the DB harness.

import (
	"context"
	"fmt"
	"net/http"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/ewallet-pg/wallet-service/internal/domain"
)

// backdateAPIMessage ages the idempotency row (PROCESSED_AT) for a forward
// reference past the reversal window, so topup/transfer/fee reversals trip
// REVERSAL_WINDOW_EXPIRED.
func backdateAPIMessage(t *testing.T, pool *pgxpool.Pool, reference, interval string) {
	t.Helper()
	if _, err := pool.Exec(context.Background(),
		fmt.Sprintf(`UPDATE wlt_api_message SET processed_at = clock_timestamp() - interval '%s' WHERE object_ref_id = $1`, interval),
		reference); err != nil {
		t.Fatalf("backdateAPIMessage(%s): %v", reference, err)
	}
}

// ── Fee charge (US-2.8) ─────────────────────────────────────────────────────

// TestFeeCharge_HappyPath_Integration — a standalone fee debits the wallet the
// gross amount, posts a balanced GL journal (revenue + VAT legs), emits the
// event, and reports a non-zero VAT.
func TestFeeCharge_HappyPath_Integration(t *testing.T) {
	repo, pool := itRepo(t)
	ctx := context.Background()
	const start = "5000000.00"
	_, acct := fundedWallet(t, repo, pool, start)

	ref := fmt.Sprintf("IT-FEE-%d", uniqN())
	const gross = "110000.00"
	res, err := repo.PostFeeCharge(ctx, domain.FeeChargeInput{
		AcctNo: acct, Amount: gross, Reference: ref, Narrative: "it annual fee", Audit: itAudit(),
	})
	if err != nil {
		t.Fatalf("PostFeeCharge: %v", err)
	}
	if res.Status != "SUCCESS" {
		t.Errorf("status = %q, want SUCCESS", res.Status)
	}
	if res.VATAmount == "" || res.VATAmount == "0" || res.VATAmount == "0.00" {
		t.Errorf("vat_amount = %q, want > 0 (VAT-inclusive)", res.VATAmount)
	}
	assertActualBalExpr(t, pool, acct, "$2::numeric - $3::numeric", acct, start, gross)
	assertBalanced(t, pool, res.TranInternalID)
	assertOutbox(t, pool, ref, "wallet.fee.charged.v1")
}

// TestFeeCharge_Idempotent_Integration — same reference → DUPLICATE, debited once.
func TestFeeCharge_Idempotent_Integration(t *testing.T) {
	repo, pool := itRepo(t)
	ctx := context.Background()
	const start = "5000000.00"
	_, acct := fundedWallet(t, repo, pool, start)

	ref := fmt.Sprintf("IT-FEE-IDEM-%d", uniqN())
	in := domain.FeeChargeInput{AcctNo: acct, Amount: "110000.00", Reference: ref, Audit: itAudit()}
	if _, err := repo.PostFeeCharge(ctx, in); err != nil {
		t.Fatalf("PostFeeCharge #1: %v", err)
	}
	second, err := repo.PostFeeCharge(ctx, in)
	if err != nil {
		t.Fatalf("PostFeeCharge #2: %v", err)
	}
	if second.Status != "DUPLICATE" {
		t.Errorf("retry status = %q, want DUPLICATE", second.Status)
	}
	assertActualBalExpr(t, pool, acct, "$2::numeric - $3::numeric", acct, start, "110000.00")
}

// ── Reversals (US-3.1/3.2/3.3 + fee) ───────────────────────────────────────

// TestTopupReversal_Integration — US-3.2: reversing a topup claws the credit
// back (balance → 0) and is idempotent (second call → WasAlreadyReversed).
func TestTopupReversal_Integration(t *testing.T) {
	repo, pool := itRepo(t)
	ctx := context.Background()
	_, acct := newWallet(t, repo, pool)

	ref := fmt.Sprintf("IT-TPREV-%d", uniqN())
	if _, err := repo.Topup(ctx, domain.TopupInput{AcctNo: acct, Amount: "300000.00", Reference: ref, Audit: itAudit()}); err != nil {
		t.Fatalf("Topup: %v", err)
	}

	rev, err := repo.ReverseTopup(ctx, domain.TopupReversalInput{OrigReference: ref, Reason: "it reverse", Initiator: "OPS_MANUAL", Audit: itAudit()})
	if err != nil {
		t.Fatalf("ReverseTopup: %v", err)
	}
	if rev.WasAlreadyReversed {
		t.Errorf("first reversal WasAlreadyReversed = true, want false")
	}
	assertActualBal(t, pool, acct, "0")
	assertOutbox(t, pool, ref, "wallet.topup.reversed.v1")

	again, err := repo.ReverseTopup(ctx, domain.TopupReversalInput{OrigReference: ref, Reason: "it reverse", Initiator: "OPS_MANUAL", Audit: itAudit()})
	if err != nil {
		t.Fatalf("ReverseTopup retry: %v", err)
	}
	if !again.WasAlreadyReversed {
		t.Errorf("retry WasAlreadyReversed = false, want true (idempotent)")
	}
	assertActualBal(t, pool, acct, "0")
}

// TestTransferReversal_Integration — US-3.1: reversing a transfer refunds the
// sender (incl. fee+VAT) and claws back the receiver; idempotent on retry.
func TestTransferReversal_Integration(t *testing.T) {
	repo, pool := itRepo(t)
	ctx := context.Background()
	const start = "10000000.00"
	_, from := fundedWallet(t, repo, pool, start)
	_, to := newWallet(t, repo, pool)

	ref := fmt.Sprintf("IT-TRFREV-%d", uniqN())
	if _, err := repo.Transfer(ctx, domain.TransferInput{
		FromAcctNo: from, ToAcctNo: to, Amount: "1000000.00", Reference: ref, TranType: "TRFOUT", Audit: itAudit(),
	}); err != nil {
		t.Fatalf("Transfer: %v", err)
	}

	rev, err := repo.ReverseTransfer(ctx, domain.TransferReversalInput{OrigReference: ref, Reason: "it reverse", Initiator: "OPS_MANUAL", Audit: itAudit()})
	if err != nil {
		t.Fatalf("ReverseTransfer: %v", err)
	}
	if rev.WasAlreadyReversed {
		t.Errorf("first reversal WasAlreadyReversed = true, want false")
	}
	// Sender made whole (principal + fee + VAT back), receiver clawed to zero.
	assertActualBal(t, pool, from, start)
	assertActualBal(t, pool, to, "0")
	assertOutbox(t, pool, ref, "wallet.transfer.reversed.v1")

	again, err := repo.ReverseTransfer(ctx, domain.TransferReversalInput{OrigReference: ref, Reason: "it reverse", Initiator: "OPS_MANUAL", Audit: itAudit()})
	if err != nil {
		t.Fatalf("ReverseTransfer retry: %v", err)
	}
	if !again.WasAlreadyReversed {
		t.Errorf("retry WasAlreadyReversed = false, want true (idempotent)")
	}
}

// TestWithdrawReversal_Integration — US-3.3: reversing a withdrawal refunds
// principal + fee + VAT (balance → start); idempotent on retry.
func TestWithdrawReversal_Integration(t *testing.T) {
	repo, pool := itRepo(t)
	ctx := context.Background()
	const start = "10000000.00"
	client, acct := fundedWallet(t, repo, pool, start)
	raiseTier(t, pool, client, "2")

	payout := fmt.Sprintf("IT-PAYOUT-%d", uniqN())
	if _, err := repo.Withdraw(ctx, domain.WithdrawInput{
		AcctNo: acct, Amount: "1000000.00", Reference: fmt.Sprintf("IT-WDREV-%d", uniqN()),
		ExtPayoutRef: payout, BeneficiaryBank: "970436", BeneficiaryAcct: "0123456789", Audit: itAudit(),
	}); err != nil {
		t.Fatalf("Withdraw: %v", err)
	}

	rev, err := repo.Reverse(ctx, domain.ReversalInput{ExtPayoutRef: payout, FailCode: "OPS_TEST", FailReason: "it reverse", Initiator: "OPS_MANUAL", Audit: itAudit()})
	if err != nil {
		t.Fatalf("Reverse (withdraw): %v", err)
	}
	if rev.WasAlreadyReversed {
		t.Errorf("first reversal WasAlreadyReversed = true, want false")
	}
	assertActualBal(t, pool, acct, start)

	again, err := repo.Reverse(ctx, domain.ReversalInput{ExtPayoutRef: payout, FailCode: "OPS_TEST", FailReason: "it reverse", Initiator: "OPS_MANUAL", Audit: itAudit()})
	if err != nil {
		t.Fatalf("Reverse retry: %v", err)
	}
	if !again.WasAlreadyReversed {
		t.Errorf("retry WasAlreadyReversed = false, want true (idempotent)")
	}
	assertActualBal(t, pool, acct, start)
}

// TestFeeChargeReversal_Integration — reversing a fee refunds the gross (balance
// → start); idempotent on retry.
func TestFeeChargeReversal_Integration(t *testing.T) {
	repo, pool := itRepo(t)
	ctx := context.Background()
	const start = "5000000.00"
	_, acct := fundedWallet(t, repo, pool, start)

	ref := fmt.Sprintf("IT-FEEREV-%d", uniqN())
	if _, err := repo.PostFeeCharge(ctx, domain.FeeChargeInput{AcctNo: acct, Amount: "110000.00", Reference: ref, Audit: itAudit()}); err != nil {
		t.Fatalf("PostFeeCharge: %v", err)
	}

	rev, err := repo.ReverseFeeCharge(ctx, domain.FeeChargeReversalInput{OrigReference: ref, Reason: "it reverse", Initiator: "OPS_MANUAL", Audit: itAudit()})
	if err != nil {
		t.Fatalf("ReverseFeeCharge: %v", err)
	}
	if rev.WasAlreadyReversed {
		t.Errorf("first reversal WasAlreadyReversed = true, want false")
	}
	assertActualBal(t, pool, acct, start)
	assertOutbox(t, pool, ref, "wallet.fee.reversed.v1")

	again, err := repo.ReverseFeeCharge(ctx, domain.FeeChargeReversalInput{OrigReference: ref, Reason: "it reverse", Initiator: "OPS_MANUAL", Audit: itAudit()})
	if err != nil {
		t.Fatalf("ReverseFeeCharge retry: %v", err)
	}
	if !again.WasAlreadyReversed {
		t.Errorf("retry WasAlreadyReversed = false, want true (idempotent)")
	}
}

// ── Reversal window (US-3.6) ────────────────────────────────────────────────

// TestTopupReversal_WindowExpired_Integration — an orig older than the 168h
// window (PROCESSED_AT source) → REVERSAL_WINDOW_EXPIRED / 422.
func TestTopupReversal_WindowExpired_Integration(t *testing.T) {
	repo, pool := itRepo(t)
	ctx := context.Background()
	_, acct := newWallet(t, repo, pool)

	ref := fmt.Sprintf("IT-TPREV-OLD-%d", uniqN())
	if _, err := repo.Topup(ctx, domain.TopupInput{AcctNo: acct, Amount: "300000.00", Reference: ref, Audit: itAudit()}); err != nil {
		t.Fatalf("Topup: %v", err)
	}
	backdateAPIMessage(t, pool, ref, "169 hours")

	_, err := repo.ReverseTopup(ctx, domain.TopupReversalInput{OrigReference: ref, Reason: "late", Initiator: "OPS_MANUAL", Audit: itAudit()})
	wantDomainCode(t, err, domain.CodeReversalWindowExpired, http.StatusUnprocessableEntity)
}

// TestWithdrawReversal_WindowExpired_Integration — same, via the SUBMITTED_AT
// source on WLT_WITHDRAW_TRACK.
func TestWithdrawReversal_WindowExpired_Integration(t *testing.T) {
	repo, pool := itRepo(t)
	ctx := context.Background()
	client, acct := fundedWallet(t, repo, pool, "10000000.00")
	raiseTier(t, pool, client, "2")

	payout := fmt.Sprintf("IT-PAYOUT-OLD-%d", uniqN())
	if _, err := repo.Withdraw(ctx, domain.WithdrawInput{
		AcctNo: acct, Amount: "1000000.00", Reference: fmt.Sprintf("IT-WDREV-OLD-%d", uniqN()),
		ExtPayoutRef: payout, BeneficiaryBank: "970436", BeneficiaryAcct: "0123456789", Audit: itAudit(),
	}); err != nil {
		t.Fatalf("Withdraw: %v", err)
	}
	if _, err := pool.Exec(ctx,
		`UPDATE wlt_withdraw_track SET submitted_at = clock_timestamp() - interval '169 hours' WHERE acct_no = $1`, acct); err != nil {
		t.Fatalf("backdate withdraw_track: %v", err)
	}

	_, err := repo.Reverse(ctx, domain.ReversalInput{ExtPayoutRef: payout, FailCode: "OPS_TEST", FailReason: "late", Initiator: "OPS_MANUAL", Audit: itAudit()})
	wantDomainCode(t, err, domain.CodeReversalWindowExpired, http.StatusUnprocessableEntity)
}
