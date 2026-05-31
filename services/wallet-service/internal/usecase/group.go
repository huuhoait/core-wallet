package usecase

import (
	"context"
	"log/slog"

	"github.com/ewallet-pg/wallet-service/internal/domain"
)

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
