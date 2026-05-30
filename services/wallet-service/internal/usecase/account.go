package usecase

import (
	"context"

	"github.com/ewallet-pg/wallet-service/internal/domain"
)

// OpenAccount opens a wallet (ACCT_NO gen, zero balance) with per-client
// wallet-count limit enforced in the SP.
func (s *WalletService) OpenAccount(ctx context.Context, in domain.AccountOpenInput) (*domain.AccountOpenResult, error) {
	res, err := s.repo.OpenAccount(ctx, in)
	if err != nil {
		s.logFailure(ctx, "open_account", in.ClientNo, err)
		return nil, err
	}
	return res, nil
}

// UpdateAccountStatus blocks / closes / re-activates an account.
func (s *WalletService) UpdateAccountStatus(ctx context.Context, in domain.AccountStatusInput) (*domain.AccountStatusResult, error) {
	res, err := s.repo.UpdateAccountStatus(ctx, in)
	if err != nil {
		s.logFailure(ctx, "update_account_status", in.AcctNo, err)
		return nil, err
	}
	return res, nil
}
