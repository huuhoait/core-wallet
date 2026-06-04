package usecase

import (
	"context"
	"log/slog"

	"github.com/ewallet-pg/wallet-service/internal/domain"
)

// PostFeeCharge charges a standalone fee + VAT against a wallet (US-2.8) — a
// self-contained debit not tied to any principal money movement.
func (s *WalletService) PostFeeCharge(ctx context.Context, in domain.FeeChargeInput) (*domain.FeeChargeResult, error) {
	res, err := s.repo.PostFeeCharge(ctx, in)
	if err != nil {
		s.logFailure(ctx, "post_fee_charge", in.Reference, err)
		return nil, err
	}
	s.log.InfoContext(ctx, "fee charged",
		slog.String("acct_no", in.AcctNo),
		slog.String("fee_gross", res.FeeGross),
		slog.String("status", res.Status))
	return res, nil
}

// ReverseFeeCharge reverses a standalone fee charge by its original reference (US-2.8).
func (s *WalletService) ReverseFeeCharge(ctx context.Context, in domain.FeeChargeReversalInput) (*domain.FeeChargeReversalResult, error) {
	res, err := s.repo.ReverseFeeCharge(ctx, in)
	if err != nil {
		s.logFailure(ctx, "post_fee_charge_reversal", in.OrigReference, err)
		return nil, err
	}
	s.log.InfoContext(ctx, "fee charge reversed",
		slog.String("orig_reference", in.OrigReference),
		slog.Bool("was_already_reversed", res.WasAlreadyReversed))
	return res, nil
}
