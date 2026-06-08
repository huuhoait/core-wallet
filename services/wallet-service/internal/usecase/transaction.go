package usecase

import (
	"context"

	"github.com/ewallet-pg/wallet-service/internal/domain"
)

// GetAccount returns the account profile (no client PII).
func (s *WalletService) GetAccount(ctx context.Context, acctNo string) (*domain.AccountView, error) {
	return s.repo.GetAccount(ctx, acctNo)
}

// ListAccountsByClient returns all wallets owned by a client. Unknown client → 404.
func (s *WalletService) ListAccountsByClient(ctx context.Context, clientNo string) ([]domain.AccountView, error) {
	return s.repo.ListAccountsByClient(ctx, clientNo)
}

// SearchAccounts finds accounts by acct_no/client_no substring (masked name).
// Limit is clamped to [1, MaxAccountSearchSize]; the handler enforces the
// minimum query length.
func (s *WalletService) SearchAccounts(ctx context.Context, query string, limit int) ([]domain.AccountSearchItem, error) {
	if limit <= 0 {
		limit = domain.DefaultAccountSearchSize
	}
	if limit > domain.MaxAccountSearchSize {
		limit = domain.MaxAccountSearchSize
	}
	return s.repo.SearchAccounts(ctx, query, limit)
}

// ListTransactions returns an account statement page. Limit is clamped to
// [1, MaxTxPageSize] with a default of DefaultTxPageSize (200).
func (s *WalletService) ListTransactions(ctx context.Context, q domain.TxListQuery) ([]domain.TxEntry, error) {
	if q.Limit <= 0 {
		q.Limit = domain.DefaultTxPageSize
	}
	if q.Limit > domain.MaxTxPageSize {
		q.Limit = domain.MaxTxPageSize
	}
	return s.repo.ListTransactions(ctx, q)
}

// GetTransaction returns all legs of a transaction by its TRAN_INTERNAL_ID.
func (s *WalletService) GetTransaction(ctx context.Context, tranKey int64) ([]domain.TxLeg, error) {
	return s.repo.GetTransaction(ctx, tranKey)
}
