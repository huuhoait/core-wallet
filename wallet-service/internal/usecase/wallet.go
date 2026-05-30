package usecase

import (
	"context"
	"log/slog"

	"github.com/ewallet-pg/wallet-service/internal/domain"
)

// WalletService is the application service. Handlers depend on this; the
// implementation delegates to WalletRepository (which calls PG SPs).
//
// In a CRUD-heavy app the usecase often holds business logic. Here, business
// logic lives in PG plpgsql SPs — so this layer mostly:
//  1. Enforces invariants outside SP scope (e.g., max metadata depth)
//  2. Decorates errors with cross-cutting concerns (logging, span attrs)
//  3. Provides a stable interface for tests (mock the repo)
type WalletService struct {
	repo WalletRepository
	log  *slog.Logger
}

func NewWalletService(repo WalletRepository, log *slog.Logger) *WalletService {
	return &WalletService{repo: repo, log: log}
}

func (s *WalletService) Topup(ctx context.Context, in domain.TopupInput) (*domain.TopupResult, error) {
	res, err := s.repo.Topup(ctx, in)
	if err != nil {
		s.logFailure(ctx, "topup", in.Reference, err)
		return nil, err
	}
	s.log.InfoContext(ctx, "topup posted",
		slog.String("reference", in.Reference),
		slog.Int64("tfr_internal_key", res.TFRInternalKey),
		slog.String("event_uuid", res.EventUUID.String()),
		slog.String("status", res.Status))
	return res, nil
}

func (s *WalletService) Transfer(ctx context.Context, in domain.TransferInput) (*domain.TransferResult, error) {
	if in.FromAcctNo == in.ToAcctNo {
		return nil, domain.NewError(domain.CodeSameAccount, 400, "from and to are the same account", nil)
	}
	res, err := s.repo.Transfer(ctx, in)
	if err != nil {
		s.logFailure(ctx, "transfer", in.Reference, err)
		return nil, err
	}
	s.log.InfoContext(ctx, "transfer posted",
		slog.String("reference", in.Reference),
		slog.Int64("tfr_internal_key", res.TFRInternalKey),
		slog.String("event_uuid", res.EventUUID.String()),
		slog.String("status", res.Status))
	return res, nil
}

func (s *WalletService) Withdraw(ctx context.Context, in domain.WithdrawInput) (*domain.WithdrawResult, error) {
	res, err := s.repo.Withdraw(ctx, in)
	if err != nil {
		s.logFailure(ctx, "withdraw", in.Reference, err)
		return nil, err
	}
	s.log.InfoContext(ctx, "withdraw posted",
		slog.String("reference", in.Reference),
		slog.String("ext_payout_ref", in.ExtPayoutRef),
		slog.Int64("tfr_internal_key", res.TFRInternalKey),
		slog.String("event_uuid", res.EventUUID.String()),
		slog.String("status", res.Status))
	return res, nil
}

func (s *WalletService) MerchantWithdraw(ctx context.Context, in domain.MerchantWithdrawInput) (*domain.MerchantWithdrawResult, error) {
	res, err := s.repo.MerchantWithdraw(ctx, in)
	if err != nil {
		s.logFailure(ctx, "merchant_withdraw", in.Reference, err)
		return nil, err
	}
	s.log.InfoContext(ctx, "merchant withdraw posted",
		slog.String("reference", in.Reference),
		slog.String("group_id", in.GroupID),
		slog.Int64("tfr_internal_key", res.TFRInternalKey),
		slog.String("event_uuid", res.EventUUID.String()),
		slog.String("status", res.Status))
	return res, nil
}

func (s *WalletService) Reverse(ctx context.Context, in domain.ReversalInput) (*domain.ReversalResult, error) {
	res, err := s.repo.Reverse(ctx, in)
	if err != nil {
		s.logFailure(ctx, "reverse", in.ExtPayoutRef, err)
		return nil, err
	}
	s.log.InfoContext(ctx, "withdraw reversed",
		slog.String("ext_payout_ref", in.ExtPayoutRef),
		slog.Int64("reversal_tfr_key", res.ReversalTFRKey),
		slog.Bool("was_already_reversed", res.WasAlreadyReversed),
		slog.String("event_uuid", res.EventUUID.String()))
	return res, nil
}

func (s *WalletService) MarkAcked(ctx context.Context, in domain.AckInput) (*domain.MarkResult, error) {
	return s.markTransition(ctx, "acked", in.ExtPayoutRef, func() (*domain.MarkResult, error) {
		return s.repo.MarkAcked(ctx, in)
	})
}

func (s *WalletService) MarkDisbursing(ctx context.Context, in domain.DisbursingInput) (*domain.MarkResult, error) {
	return s.markTransition(ctx, "disbursing", in.ExtPayoutRef, func() (*domain.MarkResult, error) {
		return s.repo.MarkDisbursing(ctx, in)
	})
}

func (s *WalletService) MarkCompleted(ctx context.Context, in domain.CompletedInput) (*domain.MarkResult, error) {
	return s.markTransition(ctx, "completed", in.ExtPayoutRef, func() (*domain.MarkResult, error) {
		return s.repo.MarkCompleted(ctx, in)
	})
}

func (s *WalletService) markTransition(
	ctx context.Context, target, ref string, fn func() (*domain.MarkResult, error),
) (*domain.MarkResult, error) {
	res, err := fn()
	if err != nil {
		s.logFailure(ctx, "mark_"+target, ref, err)
		return nil, err
	}
	s.log.InfoContext(ctx, "withdraw state transition",
		slog.String("target", target),
		slog.String("ext_payout_ref", ref),
		slog.String("status", res.Status))
	return res, nil
}

func (s *WalletService) logFailure(ctx context.Context, op, ref string, err error) {
	if de, ok := domain.AsDomain(err); ok {
		s.log.WarnContext(ctx, "operation failed",
			slog.String("op", op),
			slog.String("reference", ref),
			slog.String("code", de.Code),
			slog.Int("http_status", de.HTTPStatus),
			slog.String("detail", de.Detail),
			slog.Any("cause", de.Cause))
		return
	}
	s.log.ErrorContext(ctx, "operation failed (non-domain error)",
		slog.String("op", op),
		slog.String("reference", ref),
		slog.Any("error", err))
}
