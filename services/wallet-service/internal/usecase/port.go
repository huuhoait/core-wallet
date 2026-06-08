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

	// Account profile + transaction reads (read-only, direct SELECT on WLT_*).
	GetAccount(ctx context.Context, acctNo string) (*domain.AccountView, error)
	// ListAccountsByClient returns every wallet owned by a client (account
	// profiles). Unknown client → NotFound.
	ListAccountsByClient(ctx context.Context, clientNo string) ([]domain.AccountView, error)
	// SearchAccounts finds accounts by acct_no/client_no substring → masked name.
	SearchAccounts(ctx context.Context, query string, limit int) ([]domain.AccountSearchItem, error)
	ListTransactions(ctx context.Context, q domain.TxListQuery) ([]domain.TxEntry, error)
	GetTransaction(ctx context.Context, tranKey int64) ([]domain.TxLeg, error)

	// In-book transfer reversal (post_transfer_reversal).
	ReverseTransfer(ctx context.Context, in domain.TransferReversalInput) (*domain.TransferReversalResult, error)
	// Topup reversal (post_topup_reversal).
	ReverseTopup(ctx context.Context, in domain.TopupReversalInput) (*domain.TopupReversalResult, error)
	// Merchant-settlement withdrawal reversal (post_merchant_withdraw_reversal).
	ReverseMerchantWithdraw(ctx context.Context, in domain.MerchantWithdrawReversalInput) (*domain.MerchantWithdrawReversalResult, error)

	// Standalone fee charge + its reversal (post_fee_charge / post_fee_charge_reversal).
	PostFeeCharge(ctx context.Context, in domain.FeeChargeInput) (*domain.FeeChargeResult, error)
	ReverseFeeCharge(ctx context.Context, in domain.FeeChargeReversalInput) (*domain.FeeChargeReversalResult, error)

	// Restraint management (add_restraint / release_restraint).
	AddRestraint(ctx context.Context, in domain.RestraintInput) (*domain.RestraintResult, error)
	ReleaseRestraint(ctx context.Context, in domain.ReleaseRestraintInput) (*domain.RestraintResult, error)
	// Restraint reads (read-only, direct SELECT on WLT_RESTRAINTS).
	ListRestraints(ctx context.Context, q domain.RestraintListQuery) ([]domain.RestraintView, error)
	GetRestraint(ctx context.Context, id int64) (*domain.RestraintView, error)

	// Client master CRUD (create_client / update_client).
	CreateClient(ctx context.Context, in domain.ClientCreateInput) (*domain.ClientResult, error)
	UpdateClient(ctx context.Context, in domain.ClientUpdateInput) (*domain.ClientResult, error)

	// Onboarding (US-1.1/1.7): create client + KYC + first wallet in one TX (no OTP).
	OnboardClient(ctx context.Context, in domain.OnboardInput) (*domain.OnboardResult, error)
	// KYC update / tier upgrade (US-1.2): patch FM_CLIENT_KYC (eKYC, tier, extra_data).
	UpdateKYC(ctx context.Context, in domain.KycUpdateInput) (*domain.KycResult, error)

	// Client profile reads (read-only). GetClient → masked (v_client_masked,
	// wallet_app); GetClientFull → unmasked PII (wallet_pii_ro, /v1/ops only).
	GetClient(ctx context.Context, clientNo string) (*domain.ClientView, error)
	GetClientFull(ctx context.Context, clientNo string) (*domain.ClientFullView, error)
	// ListClients returns masked client profiles (v_client_masked, wallet_app),
	// keyset-paginated by client_no.
	ListClients(ctx context.Context, q domain.ClientListQuery) ([]domain.ClientView, error)
	// ListClientsFull returns UNMASKED client profiles (raw + decrypted phone/email,
	// wallet_pii_ro), keyset-paginated by client_no.
	ListClientsFull(ctx context.Context, q domain.ClientListQuery) ([]domain.ClientFullView, error)
	// GetClient360 aggregates profile + wallets + banks + restraints. unmask=false
	// → masked (wallet_app); unmask=true → raw + decrypted PII (wallet_pii_ro).
	GetClient360(ctx context.Context, clientNo string, unmask bool) (*domain.Client360, error)

	// Client linked-bank management (link_client_bank / set_default_client_bank).
	LinkClientBank(ctx context.Context, in domain.BankLinkInput) (*domain.BankLinkResult, error)
	SetDefaultClientBank(ctx context.Context, in domain.SetDefaultBankInput) (*domain.BankLinkResult, error)

	// Account (wallet) lifecycle (open_account / update_account_status).
	OpenAccount(ctx context.Context, in domain.AccountOpenInput) (*domain.AccountOpenResult, error)
	UpdateAccountStatus(ctx context.Context, in domain.AccountStatusInput) (*domain.AccountStatusResult, error)

	// Merchant hot-wallet group lifecycle.
	// ProvisionAcctGroup (provision_acct_group, US-1.10): create a cold group row
	// + its settlement account in one TX.
	ProvisionAcctGroup(ctx context.Context, in domain.ProvisionGroupInput) (*domain.ProvisionGroupResult, error)
	// ActivateHotWallet (activate_hot_wallet, US-1.9): promote a cold group
	// (0 shards) to N hot SHARD sub-accounts.
	ActivateHotWallet(ctx context.Context, in domain.ActivateHotWalletInput) (*domain.ActivateHotWalletResult, error)
	// RescaleHotWallet (rescale_hot_wallet, US-1.12): grow an already-hot group up
	// a tier (4→8→16), draining existing shards back to settlement first.
	RescaleHotWallet(ctx context.Context, in domain.RescaleHotWalletInput) (*domain.RescaleHotWalletResult, error)
	// MerchantDeposit (post_merchant_deposit, US-1.11): route an inbound deposit
	// into a group — settlement while cold, a shard once hot.
	MerchantDeposit(ctx context.Context, in domain.MerchantDepositInput) (*domain.MerchantDepositResult, error)
}
