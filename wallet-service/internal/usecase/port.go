// Package usecase contains application services that orchestrate domain
// behaviour. It defines repository ports (interfaces) implemented by adapters.
//
// Layering rule: usecase imports domain only. It MUST NOT import gin, pgx,
// or any framework — only the standard library + domain types.
package usecase

import (
	"context"
	"time"

	"github.com/ewallet-pg/wallet-service/internal/domain"
)

// WalletRepository is the driven port for posting business operations.
// Implementations live in internal/repo/postgres.go.
//
// Each method MUST be implemented as a single transaction with the audit GUCs
// (audit.actor, audit.channel, app.trace_id) set at TX start so the BEFORE
// INSERT/UPDATE trigger trg_audit_cols can attribute the change.
type WalletRepository interface {
	Topup(ctx context.Context, in domain.TopupInput) (*domain.TopupResult, error)
	Transfer(ctx context.Context, in domain.TransferInput) (*domain.TransferResult, error)
	Withdraw(ctx context.Context, in domain.WithdrawInput) (*domain.WithdrawResult, error)
	MerchantWithdraw(ctx context.Context, in domain.MerchantWithdrawInput) (*domain.MerchantWithdrawResult, error)
	Reverse(ctx context.Context, in domain.ReversalInput) (*domain.ReversalResult, error)

	MarkAcked(ctx context.Context, in domain.AckInput) (*domain.MarkResult, error)
	MarkDisbursing(ctx context.Context, in domain.DisbursingInput) (*domain.MarkResult, error)
	MarkCompleted(ctx context.Context, in domain.CompletedInput) (*domain.MarkResult, error)

	// Balance queries (read-only, no audit TX — Get Balance §9).
	GetBalance(ctx context.Context, acctNo string) (*domain.BalanceView, error)
	GetBalanceOps(ctx context.Context, acctNo string) (*domain.BalanceOpsView, error)
	GetBalanceAsOf(ctx context.Context, acctNo string, asOf time.Time) (*domain.BalanceAsOf, error)
	GetBalanceBatch(ctx context.Context, acctNos []string) ([]domain.BalanceBatchItem, error)

	// In-book transfer reversal (post_transfer_reversal).
	ReverseTransfer(ctx context.Context, in domain.TransferReversalInput) (*domain.TransferReversalResult, error)
	// Topup reversal (post_topup_reversal).
	ReverseTopup(ctx context.Context, in domain.TopupReversalInput) (*domain.TopupReversalResult, error)
}
