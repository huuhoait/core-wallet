package usecase

import (
	"context"
	"time"

	"github.com/ewallet-pg/wallet-service/internal/domain"
)

// SuspenseAging returns the suspense/clearing aging report (US-6.2) as of asOf.
// Read-only; the SP does the aggregation.
func (s *WalletService) SuspenseAging(ctx context.Context, asOf time.Time) ([]domain.SuspenseAgingRow, error) {
	return s.repo.SuspenseAging(ctx, asOf)
}
