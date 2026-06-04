package usecase

import (
	"context"
	"log/slog"

	"github.com/ewallet-pg/wallet-service/internal/domain"
)

// ProvisionAcctGroup creates a new cold merchant/agent group — the group row +
// its settlement account — atomically in one TX (US-1.10). Prerequisite for
// ActivateHotWallet on a real merchant.
func (s *WalletService) ProvisionAcctGroup(ctx context.Context, in domain.ProvisionGroupInput) (*domain.ProvisionGroupResult, error) {
	res, err := s.repo.ProvisionAcctGroup(ctx, in)
	if err != nil {
		s.logFailure(ctx, "provision_acct_group", in.GroupID, err)
		return nil, err
	}
	s.log.InfoContext(ctx, "merchant group provisioned",
		slog.String("group_id", res.GroupID),
		slog.String("group_type", res.GroupType),
		slog.String("settlement_acct_no", res.SettlementAcctNo))
	return res, nil
}

// ActivateHotWallet promotes a cold merchant group (0 shards) to a hot wallet by
// materialising ShardCount empty SHARD sub-accounts. No funds move — settlement
// keeps the balance; top-ups route to shards and sweeps drain them back.
func (s *WalletService) ActivateHotWallet(ctx context.Context, in domain.ActivateHotWalletInput) (*domain.ActivateHotWalletResult, error) {
	res, err := s.repo.ActivateHotWallet(ctx, in)
	if err != nil {
		s.logFailure(ctx, "activate_hot_wallet", in.GroupID, err)
		return nil, err
	}
	s.log.InfoContext(ctx, "hot wallet activated",
		slog.String("group_id", in.GroupID),
		slog.Int("shard_count", int(res.ShardCount)),
		slog.String("settlement_acct_no", res.SettlementAcctNo))
	return res, nil
}

// RescaleHotWallet grows an already-hot group up a tier (4→8→16) and rebalances:
// existing shards are drained back to settlement so the wider fan-out starts even.
func (s *WalletService) RescaleHotWallet(ctx context.Context, in domain.RescaleHotWalletInput) (*domain.RescaleHotWalletResult, error) {
	res, err := s.repo.RescaleHotWallet(ctx, in)
	if err != nil {
		s.logFailure(ctx, "rescale_hot_wallet", in.GroupID, err)
		return nil, err
	}
	s.log.InfoContext(ctx, "hot wallet rescaled",
		slog.String("group_id", in.GroupID),
		slog.Int("old_shard_count", int(res.OldShardCount)),
		slog.Int("new_shard_count", int(res.NewShardCount)),
		slog.String("rebalanced_amount", res.RebalancedAmount))
	return res, nil
}

// MerchantDeposit routes an inbound merchant deposit/payment into a group: it
// credits the settlement account while the group is cold, or a reference-hashed
// shard once it is hot (US-1.11).
func (s *WalletService) MerchantDeposit(ctx context.Context, in domain.MerchantDepositInput) (*domain.MerchantDepositResult, error) {
	res, err := s.repo.MerchantDeposit(ctx, in)
	if err != nil {
		s.logFailure(ctx, "post_merchant_deposit", in.Reference, err)
		return nil, err
	}
	s.log.InfoContext(ctx, "merchant deposit posted",
		slog.String("group_id", in.GroupID),
		slog.String("target_acct_no", res.TargetAcctNo),
		slog.String("status", res.Status))
	return res, nil
}
