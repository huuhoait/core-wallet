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

// OnboardClient runs the OTP-free step 1: create client + KYC + first wallet (US-1.1/1.7).
func (s *WalletService) OnboardClient(ctx context.Context, in domain.OnboardInput) (*domain.OnboardResult, error) {
	res, err := s.repo.OnboardClient(ctx, in)
	if err != nil {
		s.logFailure(ctx, "onboard_client", in.GlobalID, err)
		return nil, err
	}
	return res, nil
}

// UpdateKYC submits/updates eKYC info and raises the KYC tier (US-1.2).
func (s *WalletService) UpdateKYC(ctx context.Context, in domain.KycUpdateInput) (*domain.KycResult, error) {
	res, err := s.repo.UpdateKYC(ctx, in)
	if err != nil {
		s.logFailure(ctx, "update_kyc", in.ClientNo, err)
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

// ListClientsFull returns a keyset-paginated page of UNMASKED client profiles
// (wallet_pii_ro path, ops only). Page size clamped to [1, MaxClientPageSize].
func (s *WalletService) ListClientsFull(ctx context.Context, q domain.ClientListQuery) ([]domain.ClientFullView, error) {
	if q.Limit <= 0 {
		q.Limit = domain.DefaultClientPageSize
	}
	if q.Limit > domain.MaxClientPageSize {
		q.Limit = domain.MaxClientPageSize
	}
	return s.repo.ListClientsFull(ctx, q)
}

// GetClient360 returns the aggregate customer view (profile + wallets + banks +
// restraints). unmask=true exposes raw PII (wallet_pii_ro, /v1/ops only).
func (s *WalletService) GetClient360(ctx context.Context, clientNo string, unmask bool) (*domain.Client360, error) {
	return s.repo.GetClient360(ctx, clientNo, unmask)
}

// ListClients returns a keyset-paginated page of masked client profiles
// (wallet_app path). Page size is clamped to [1, MaxClientPageSize].
func (s *WalletService) ListClients(ctx context.Context, q domain.ClientListQuery) ([]domain.ClientView, error) {
	if q.Limit <= 0 {
		q.Limit = domain.DefaultClientPageSize
	}
	if q.Limit > domain.MaxClientPageSize {
		q.Limit = domain.MaxClientPageSize
	}
	return s.repo.ListClients(ctx, q)
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

// AttachClientDocument attaches/updates a related document on a client's KYC
// (onboarding step 3 / US-1.13).
func (s *WalletService) AttachClientDocument(ctx context.Context, in domain.AttachDocumentInput) (*domain.AttachDocumentResult, error) {
	res, err := s.repo.AttachClientDocument(ctx, in)
	if err != nil {
		s.logFailure(ctx, "attach_client_document", in.ClientNo, err)
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
