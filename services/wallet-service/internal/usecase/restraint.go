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

// ListRestraints returns an account's restraints (all statuses), newest-first,
// keyset-paginated. Limit is clamped to [1, MaxRestraintPageSize] with a default
// of DefaultRestraintPageSize.
func (s *WalletService) ListRestraints(ctx context.Context, q domain.RestraintListQuery) ([]domain.RestraintView, error) {
	if q.Limit <= 0 {
		q.Limit = domain.DefaultRestraintPageSize
	}
	if q.Limit > domain.MaxRestraintPageSize {
		q.Limit = domain.MaxRestraintPageSize
	}
	return s.repo.ListRestraints(ctx, q)
}

// GetRestraint returns a single restraint by its id (WLT_RESTRAINTS.SEQ_NO).
func (s *WalletService) GetRestraint(ctx context.Context, id int64) (*domain.RestraintView, error) {
	return s.repo.GetRestraint(ctx, id)
}
