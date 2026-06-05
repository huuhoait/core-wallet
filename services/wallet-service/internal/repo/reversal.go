package repo

import (
	"context"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/ewallet-pg/wallet-service/internal/domain"
)

// ReverseTransfer calls post_transfer_reversal in one audited TX.
func (r *PgWalletRepo) ReverseTransfer(ctx context.Context, in domain.TransferReversalInput) (*domain.TransferReversalResult, error) {
	var out domain.TransferReversalResult
	err := r.withTx(ctx, in.Audit, func(tx pgx.Tx) error {
		const q = `
			SELECT reversal_tran_key, was_already_reversed, new_balance_from, new_balance_to, event_uuid
			  FROM post_transfer_reversal($1, $2, $3, $4, $5)
		`
		var nbf, nbt string
		var uu uuid.UUID
		row := tx.QueryRow(ctx, q,
			in.OrigReference, in.Reason, in.Initiator, string(in.Audit.Channel), in.Audit.Actor)
		if err := row.Scan(&out.ReversalTranKey, &out.WasAlreadyReversed, &nbf, &nbt, &uu); err != nil {
			return err
		}
		out.NewBalanceFrom, out.NewBalanceTo, out.EventUUID = nbf, nbt, uu
		return nil
	})
	if err != nil {
		return nil, mapErrIfPg(err)
	}
	return &out, nil
}

// ReverseTopup calls post_topup_reversal in one audited TX.
func (r *PgWalletRepo) ReverseTopup(ctx context.Context, in domain.TopupReversalInput) (*domain.TopupReversalResult, error) {
	var out domain.TopupReversalResult
	err := r.withTx(ctx, in.Audit, func(tx pgx.Tx) error {
		const q = `
			SELECT reversal_tran_key, was_already_reversed, new_balance, event_uuid
			  FROM post_topup_reversal($1, $2, $3, $4, $5)
		`
		var nb string
		var uu uuid.UUID
		row := tx.QueryRow(ctx, q,
			in.OrigReference, in.Reason, in.Initiator, string(in.Audit.Channel), in.Audit.Actor)
		if err := row.Scan(&out.ReversalTranKey, &out.WasAlreadyReversed, &nb, &uu); err != nil {
			return err
		}
		out.NewBalance, out.EventUUID = nb, uu
		return nil
	})
	if err != nil {
		return nil, mapErrIfPg(err)
	}
	return &out, nil
}

// ReverseMerchantWithdraw calls post_merchant_withdraw_reversal in one audited
// TX. Credits the settlement account back the principal + fee/VAT and emits
// wallet.merchant_withdraw.reversed.v1 on the outbox.
func (r *PgWalletRepo) ReverseMerchantWithdraw(ctx context.Context, in domain.MerchantWithdrawReversalInput) (*domain.MerchantWithdrawReversalResult, error) {
	var out domain.MerchantWithdrawReversalResult
	err := r.withTx(ctx, in.Audit, func(tx pgx.Tx) error {
		const q = `
			SELECT reversal_tran_key, was_already_reversed, settlement_balance_after, event_uuid
			  FROM post_merchant_withdraw_reversal($1, $2, $3, $4, $5, $6)
		`
		var bal string
		var uu uuid.UUID
		row := tx.QueryRow(ctx, q,
			in.OrigReference, in.FailCode, in.FailReason, in.Initiator, string(in.Audit.Channel), in.Audit.Actor)
		if err := row.Scan(&out.ReversalTranKey, &out.WasAlreadyReversed, &bal, &uu); err != nil {
			return err
		}
		out.SettlementBalanceAfter, out.EventUUID = bal, uu
		return nil
	})
	if err != nil {
		return nil, mapErrIfPg(err)
	}
	return &out, nil
}
