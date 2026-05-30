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
