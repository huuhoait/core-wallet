package usecase

import (
	"context"

	"github.com/ewallet-pg/wallet-service/internal/domain"
)

// AddRestraint validates + records a hold on an account. Field-level validation
// (enums, type/purpose conflict, amount, dates) is enforced authoritatively in
// the add_restraint SP; the usecase just forwards.
func (s *WalletService) AddRestraint(ctx context.Context, in domain.RestraintInput) (*domain.RestraintResult, error) {
	res, err := s.repo.AddRestraint(ctx, in)
	if err != nil {
		s.logFailure(ctx, "add_restraint", in.AcctNo, err)
		return nil, err
	}
	return res, nil
}

// ReleaseRestraint releases an active restraint by id.
func (s *WalletService) ReleaseRestraint(ctx context.Context, in domain.ReleaseRestraintInput) (*domain.RestraintResult, error) {
	res, err := s.repo.ReleaseRestraint(ctx, in)
	if err != nil {
		s.logFailure(ctx, "release_restraint", in.Reason, err)
		return nil, err
	}
	return res, nil
}
