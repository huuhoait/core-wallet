package usecase

import (
	"context"

	"github.com/ewallet-pg/wallet-service/internal/domain"
)

// GetAccount returns the account profile (no client PII).
func (s *WalletService) GetAccount(ctx context.Context, acctNo string) (*domain.AccountView, error) {
	return s.repo.GetAccount(ctx, acctNo)
}

// ListTransactions returns an account statement page. Limit is clamped to
// [1, MaxTxPageSize] with a default of 20.
func (s *WalletService) ListTransactions(ctx context.Context, q domain.TxListQuery) ([]domain.TxEntry, error) {
	if q.Limit <= 0 {
		q.Limit = 20
	}
	if q.Limit > domain.MaxTxPageSize {
		q.Limit = domain.MaxTxPageSize
	}
	return s.repo.ListTransactions(ctx, q)
}

// GetTransaction returns all legs of a transaction by its TFR_INTERNAL_KEY.
func (s *WalletService) GetTransaction(ctx context.Context, tfrKey int64) ([]domain.TxLeg, error) {
	return s.repo.GetTransaction(ctx, tfrKey)
}
