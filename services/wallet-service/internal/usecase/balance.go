package usecase

import (
	"context"
	"log/slog"
	"time"

	"github.com/ewallet-pg/wallet-service/internal/domain"
)

// GetBalance returns the customer realtime balance (§9.3.1).
func (s *WalletService) GetBalance(ctx context.Context, acctNo string) (*domain.BalanceView, error) {
	res, err := s.repo.GetBalance(ctx, acctNo)
	if err != nil {
		s.logFailure(ctx, "get_balance", acctNo, err)
		return nil, err
	}
	return res, nil
}

// GetBalanceOps returns the ops/internal full balance view (§9.3.2).
func (s *WalletService) GetBalanceOps(ctx context.Context, acctNo string) (*domain.BalanceOpsView, error) {
	res, err := s.repo.GetBalanceOps(ctx, acctNo)
	if err != nil {
		s.logFailure(ctx, "get_balance_ops", acctNo, err)
		return nil, err
	}
	return res, nil
}

// GetBalanceAsOf returns a historical end-of-day snapshot (§9.3.3).
func (s *WalletService) GetBalanceAsOf(ctx context.Context, acctNo string, asOf time.Time) (*domain.BalanceAsOf, error) {
	res, err := s.repo.GetBalanceAsOf(ctx, acctNo, asOf)
	if err != nil {
		s.logFailure(ctx, "get_balance_asof", acctNo, err)
		return nil, err
	}
	return res, nil
}

// GetBalanceBatch returns balances for up to 100 accounts (§9.3.4).
func (s *WalletService) GetBalanceBatch(ctx context.Context, acctNos []string) ([]domain.BalanceBatchItem, error) {
	res, err := s.repo.GetBalanceBatch(ctx, acctNos)
	if err != nil {
		s.logFailure(ctx, "get_balance_batch", "", err)
		return nil, err
	}
	s.log.InfoContext(ctx, "batch balance query",
		slog.Int("requested", len(acctNos)),
		slog.Int("found", len(res)))
	return res, nil
}
