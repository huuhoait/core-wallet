package usecase

import (
	"context"

	"github.com/ewallet-pg/wallet-service/internal/domain"
)

// CreateClient creates a client master record (identity only; no KYC flow).
func (s *WalletService) CreateClient(ctx context.Context, in domain.ClientCreateInput) (*domain.ClientResult, error) {
	res, err := s.repo.CreateClient(ctx, in)
	if err != nil {
		s.logFailure(ctx, "create_client", in.GlobalID, err)
		return nil, err
	}
	return res, nil
}

// UpdateClient patches mutable identity fields of an existing client.
func (s *WalletService) UpdateClient(ctx context.Context, in domain.ClientUpdateInput) (*domain.ClientResult, error) {
	res, err := s.repo.UpdateClient(ctx, in)
	if err != nil {
		s.logFailure(ctx, "update_client", in.ClientNo, err)
		return nil, err
	}
	return res, nil
}

// GetClient returns the masked client profile (wallet_app path).
func (s *WalletService) GetClient(ctx context.Context, clientNo string) (*domain.ClientView, error) {
	return s.repo.GetClient(ctx, clientNo)
}

// GetClientFull returns the unmasked client profile (wallet_pii_ro path, ops only).
func (s *WalletService) GetClientFull(ctx context.Context, clientNo string) (*domain.ClientFullView, error) {
	return s.repo.GetClientFull(ctx, clientNo)
}

// LinkClientBank links a bank account to a client (optionally as default).
func (s *WalletService) LinkClientBank(ctx context.Context, in domain.BankLinkInput) (*domain.BankLinkResult, error) {
	res, err := s.repo.LinkClientBank(ctx, in)
	if err != nil {
		s.logFailure(ctx, "link_client_bank", in.ClientNo, err)
		return nil, err
	}
	return res, nil
}

// SetDefaultClientBank makes an existing linked bank the client's default.
func (s *WalletService) SetDefaultClientBank(ctx context.Context, in domain.SetDefaultBankInput) (*domain.BankLinkResult, error) {
	res, err := s.repo.SetDefaultClientBank(ctx, in)
	if err != nil {
		s.logFailure(ctx, "set_default_client_bank", in.ClientNo, err)
		return nil, err
	}
	return res, nil
}
