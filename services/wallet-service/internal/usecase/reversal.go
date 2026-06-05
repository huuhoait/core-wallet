package usecase

import (
	"context"
	"log/slog"

	"github.com/ewallet-pg/wallet-service/internal/domain"
)

// ReverseTransfer reverses an in-book transfer (refund sender, claw back receiver).
func (s *WalletService) ReverseTransfer(ctx context.Context, in domain.TransferReversalInput) (*domain.TransferReversalResult, error) {
	res, err := s.repo.ReverseTransfer(ctx, in)
	if err != nil {
		s.logFailure(ctx, "transfer_reversal", in.OrigReference, err)
		return nil, err
	}
	s.log.InfoContext(ctx, "transfer reversed",
		slog.String("orig_reference", in.OrigReference),
		slog.Int64("reversal_tran_key", res.ReversalTranKey),
		slog.Bool("was_already_reversed", res.WasAlreadyReversed),
		slog.String("event_uuid", res.EventUUID.String()))
	return res, nil
}

// ReverseTopup reverses a topup (claw back the credited funds from the wallet).
func (s *WalletService) ReverseTopup(ctx context.Context, in domain.TopupReversalInput) (*domain.TopupReversalResult, error) {
	res, err := s.repo.ReverseTopup(ctx, in)
	if err != nil {
		s.logFailure(ctx, "topup_reversal", in.OrigReference, err)
		return nil, err
	}
	s.log.InfoContext(ctx, "topup reversed",
		slog.String("orig_reference", in.OrigReference),
		slog.Int64("reversal_tran_key", res.ReversalTranKey),
		slog.Bool("was_already_reversed", res.WasAlreadyReversed),
		slog.String("event_uuid", res.EventUUID.String()))
	return res, nil
}

// ReverseMerchantWithdraw reverses a merchant-settlement withdraw (credit back
// principal + fee/VAT to the settlement account).
func (s *WalletService) ReverseMerchantWithdraw(ctx context.Context, in domain.MerchantWithdrawReversalInput) (*domain.MerchantWithdrawReversalResult, error) {
	res, err := s.repo.ReverseMerchantWithdraw(ctx, in)
	if err != nil {
		s.logFailure(ctx, "merchant_withdraw_reversal", in.OrigReference, err)
		return nil, err
	}
	s.log.InfoContext(ctx, "merchant withdraw reversed",
		slog.String("orig_reference", in.OrigReference),
		slog.String("fail_code", in.FailCode),
		slog.Int64("reversal_tran_key", res.ReversalTranKey),
		slog.Bool("was_already_reversed", res.WasAlreadyReversed),
		slog.String("event_uuid", res.EventUUID.String()))
	return res, nil
}
