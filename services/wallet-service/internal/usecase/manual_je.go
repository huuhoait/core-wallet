package usecase

import (
	"context"
	"log/slog"

	"github.com/ewallet-pg/wallet-service/internal/domain"
)

// Manual journal entry — maker-checker (US-6.5). Validation (reason, balanced
// ΣDR=ΣCR, GL codes, maker≠checker, period-open) is enforced authoritatively in
// the SPs; the usecase forwards and logs the outcome.

// CreateManualJE drafts a balanced GL adjusting entry (status PENDING).
func (s *WalletService) CreateManualJE(ctx context.Context, in domain.ManualJEInput) (*domain.ManualJECreateResult, error) {
	res, err := s.repo.CreateManualJE(ctx, in)
	if err != nil {
		s.logFailure(ctx, "create_manual_je", in.Reference, err)
		return nil, err
	}
	s.log.InfoContext(ctx, "manual JE drafted",
		slog.String("reference", in.Reference),
		slog.Int64("je_id", res.JEID),
		slog.String("maker", in.Audit.Actor),
		slog.String("total_dr", res.TotalDR),
		slog.Int("line_count", int(res.LineCount)))
	return res, nil
}

// ApproveManualJE posts a PENDING JE into the GL batch (checker ≠ maker).
func (s *WalletService) ApproveManualJE(ctx context.Context, in domain.ManualJEDecisionInput) (*domain.ManualJEApproveResult, error) {
	res, err := s.repo.ApproveManualJE(ctx, in)
	if err != nil {
		s.logFailure(ctx, "approve_manual_je", in.Reason, err)
		return nil, err
	}
	s.log.InfoContext(ctx, "manual JE approved + posted",
		slog.Int64("je_id", res.JEID),
		slog.String("checker", in.Audit.Actor),
		slog.Int64("gl_tran_key", res.GLTranKey),
		slog.Int("posted_lines", int(res.PostedLines)))
	return res, nil
}

// RejectManualJE declines a PENDING JE (maker self-cancel or checker reject).
func (s *WalletService) RejectManualJE(ctx context.Context, in domain.ManualJEDecisionInput) (*domain.ManualJERejectResult, error) {
	res, err := s.repo.RejectManualJE(ctx, in)
	if err != nil {
		s.logFailure(ctx, "reject_manual_je", in.Reason, err)
		return nil, err
	}
	s.log.InfoContext(ctx, "manual JE rejected",
		slog.Int64("je_id", res.JEID),
		slog.String("checker", in.Audit.Actor))
	return res, nil
}

// ListManualJE returns JE headers, newest-first, keyset-paginated. Limit is
// clamped to [1, MaxManualJEPageSize] with a default of DefaultManualJEPageSize.
func (s *WalletService) ListManualJE(ctx context.Context, q domain.ManualJEListQuery) ([]domain.ManualJEView, error) {
	if q.Limit <= 0 {
		q.Limit = domain.DefaultManualJEPageSize
	}
	if q.Limit > domain.MaxManualJEPageSize {
		q.Limit = domain.MaxManualJEPageSize
	}
	return s.repo.ListManualJE(ctx, q)
}

// GetManualJE returns a single JE (header + lines) by id.
func (s *WalletService) GetManualJE(ctx context.Context, id int64) (*domain.ManualJEView, error) {
	return s.repo.GetManualJE(ctx, id)
}
