package repo

// Integration test for the merchant hot-wallet lifecycle: provision a cold group
// (US-1.10) → activate to hot shards (US-1.9) → deposit routed to a shard
// (US-1.11) → merchant withdraw with shard sweep + settlement (US-2.4) → reverse
// (US-3.4). See integration_helpers_test.go for fixtures and
// onboard_integration_test.go for the DB harness.

import (
	"context"
	"fmt"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/ewallet-pg/wallet-service/internal/domain"
)

// dropGroup removes a merchant group and everything it owns — settlement + shard
// accounts, their ledger rows, sweep log, restraints, and the group row. The
// group↔settlement FK is a cycle (fk_acct_group immediate, fk_group_settlement
// deferred), so the deletes run in one tx with constraints deferred to commit.
func dropGroup(t *testing.T, pool *pgxpool.Pool, groupID string) {
	t.Helper()
	t.Cleanup(func() {
		ctx := context.Background()
		tx, err := pool.Begin(ctx)
		if err != nil {
			return
		}
		defer func() { _ = tx.Rollback(context.Background()) }()
		_, _ = tx.Exec(ctx, `SET CONSTRAINTS ALL DEFERRED`)
		const ikSub = `(SELECT internal_key FROM wlt_acct WHERE group_id = $1)`
		const refSub = `(SELECT reference FROM wlt_tran_hist WHERE internal_key IN ` + ikSub + `)`
		for _, q := range []string{
			`DELETE FROM wlt_api_message WHERE object_ref_id IN ` + refSub,
			`DELETE FROM wlt_gl_batch    WHERE reference IN ` + refSub,
			`DELETE FROM wlt_gl_batch    WHERE acct_internal_key IN ` + ikSub,
			`DELETE FROM wlt_tran_hist   WHERE internal_key IN ` + ikSub,
			`DELETE FROM wlt_acct_bal    WHERE internal_key IN ` + ikSub,
			`DELETE FROM wlt_outbox      WHERE partition_key = $1 OR payload->>'group_id' = $1`,
			`DELETE FROM wlt_sweep_log   WHERE group_id = $1`,
			`DELETE FROM wlt_restraints  WHERE group_id = $1`,
			`DELETE FROM wlt_acct        WHERE group_id = $1`,
			`DELETE FROM wlt_acct_group  WHERE group_id = $1`,
		} {
			_, _ = tx.Exec(ctx, q, groupID)
		}
		_ = tx.Commit(ctx)
	})
}

// TestMerchantLifecycle_Integration walks the full hot-wallet lifecycle and
// proves balanced GL + event emission at each posting step.
func TestMerchantLifecycle_Integration(t *testing.T) {
	repo, pool := itRepo(t)
	ctx := context.Background()

	// A client to own the group (we only need its client_no).
	client, _ := newWallet(t, repo, pool)
	groupID := fmt.Sprintf("ITG%d", uniqN()%100000000000) // ≤ 20 chars

	// 1. Provision cold (settlement account created, 0 shards).
	prov, err := repo.ProvisionAcctGroup(ctx, domain.ProvisionGroupInput{
		ClientNo: client, GroupID: groupID, GroupType: "MERCHANT", AcctType: "MERCHANT", CCY: "VND", Audit: itAudit(),
	})
	if err != nil {
		t.Fatalf("ProvisionAcctGroup: %v", err)
	}
	dropGroup(t, pool, groupID)
	if prov.SettlementAcctNo == "" {
		t.Fatalf("provision returned no settlement acct: %+v", prov)
	}

	// 2. Activate → 4 hot shards.
	act, err := repo.ActivateHotWallet(ctx, domain.ActivateHotWalletInput{GroupID: groupID, ShardCount: 4, Audit: itAudit()})
	if err != nil {
		t.Fatalf("ActivateHotWallet: %v", err)
	}
	if len(act.ShardAcctNos) != 4 {
		t.Errorf("shard count = %d, want 4", len(act.ShardAcctNos))
	}

	// 3. Deposit into the now-hot group → routes to a shard.
	depRef := fmt.Sprintf("IT-MDEP-%d", uniqN())
	dep, err := repo.MerchantDeposit(ctx, domain.MerchantDepositInput{GroupID: groupID, Amount: "5000000.00", Reference: depRef, Audit: itAudit()})
	if err != nil {
		t.Fatalf("MerchantDeposit: %v", err)
	}
	if dep.TranInternalID == 0 {
		t.Errorf("deposit tran_internal_id = 0")
	}
	if dep.ShardIndex == nil {
		t.Errorf("deposit ShardIndex = nil, want a shard (group is hot)")
	}
	assertActualBal(t, pool, dep.TargetAcctNo, "5000000")
	assertBalanced(t, pool, dep.TranInternalID)
	assertOutbox(t, pool, depRef, "wallet.merchant.deposit.posted.v1")

	// 4. Merchant withdraw with auto-sweep: drains the shard into settlement, debits.
	wdRef := fmt.Sprintf("IT-MWD-%d", uniqN())
	wd, err := repo.MerchantWithdraw(ctx, domain.MerchantWithdrawInput{
		GroupID: groupID, Amount: "1000000.00", Reference: wdRef,
		ExtPayoutRef: fmt.Sprintf("IT-MPAYOUT-%d", uniqN()), AutoSweep: true, Audit: itAudit(),
	})
	if err != nil {
		t.Fatalf("MerchantWithdraw: %v", err)
	}
	if wd.TranInternalID == 0 {
		t.Fatalf("merchant withdraw did not post (status=%q, sweep required?)", wd.Status)
	}
	assertBalanced(t, pool, wd.TranInternalID)
	assertOutbox(t, pool, wdRef, "wallet.merchant_withdraw.posted.v1")

	// 5. Reverse the merchant withdraw → credits settlement back; idempotent.
	rev, err := repo.ReverseMerchantWithdraw(ctx, domain.MerchantWithdrawReversalInput{
		OrigReference: wdRef, FailCode: "OPS_TEST", FailReason: "it reverse", Initiator: "OPS_MANUAL", Audit: itAudit(),
	})
	if err != nil {
		t.Fatalf("ReverseMerchantWithdraw: %v", err)
	}
	if rev.WasAlreadyReversed {
		t.Errorf("first reversal WasAlreadyReversed = true, want false")
	}

	again, err := repo.ReverseMerchantWithdraw(ctx, domain.MerchantWithdrawReversalInput{
		OrigReference: wdRef, FailCode: "OPS_TEST", FailReason: "it reverse", Initiator: "OPS_MANUAL", Audit: itAudit(),
	})
	if err != nil {
		t.Fatalf("ReverseMerchantWithdraw retry: %v", err)
	}
	if !again.WasAlreadyReversed {
		t.Errorf("retry WasAlreadyReversed = false, want true (idempotent)")
	}
}
