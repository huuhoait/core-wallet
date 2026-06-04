// Standalone fee-charge write adapter — post_fee_charge / post_fee_charge_reversal
// SPs (US-2.8). Writes → withTx (audit GUCs). SECURITY DEFINER because wallet_app
// holds only SELECT on the reference tables.
package repo

import (
	"context"
	"encoding/json"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/ewallet-pg/wallet-service/internal/domain"
)

// PostFeeCharge charges a standalone fee + VAT against a wallet (US-2.8).
func (r *PgWalletRepo) PostFeeCharge(ctx context.Context, in domain.FeeChargeInput) (*domain.FeeChargeResult, error) {
	var out domain.FeeChargeResult
	metaJSON, err := json.Marshal(withNarrative(in.Metadata, in.Narrative))
	if err != nil {
		return nil, domain.InvalidRequest("metadata not serialisable", err)
	}
	feeCode := in.FeeCode
	if feeCode == "" {
		feeCode = "FEECHG" // SP default; passed explicitly since the param is positional
	}
	err = r.withTx(ctx, in.Audit, func(tx pgx.Tx) error {
		const q = `
			SELECT tran_internal_id, status, fee_gross, vat_amount, new_balance, event_uuid
			  FROM post_fee_charge($1, $2::numeric, $3, $4, $5, $6::jsonb, $7, $8)
		`
		return tx.QueryRow(ctx, q,
			in.AcctNo, in.Amount, in.Reference, feeCode, in.Narrative,
			string(metaJSON), string(in.Audit.Channel), in.Audit.Actor).
			Scan(&out.TranInternalID, &out.Status, &out.FeeGross, &out.VATAmount,
				&out.NewBalance, &out.EventUUID)
	})
	if err != nil {
		return nil, mapErrIfPg(err)
	}
	return &out, nil
}

// ReverseFeeCharge reverses a standalone fee charge by its original reference (US-2.8).
func (r *PgWalletRepo) ReverseFeeCharge(ctx context.Context, in domain.FeeChargeReversalInput) (*domain.FeeChargeReversalResult, error) {
	var out domain.FeeChargeReversalResult
	err := r.withTx(ctx, in.Audit, func(tx pgx.Tx) error {
		const q = `
			SELECT reversal_tran_key, was_already_reversed, new_balance, event_uuid
			  FROM post_fee_charge_reversal($1, $2, $3, $4, $5)
		`
		var uu *uuid.UUID
		if err := tx.QueryRow(ctx, q,
			in.OrigReference, in.Reason, in.Initiator,
			string(in.Audit.Channel), in.Audit.Actor).
			Scan(&out.ReversalTranKey, &out.WasAlreadyReversed, &out.NewBalance, &uu); err != nil {
			return err
		}
		if uu != nil {
			out.EventUUID = *uu
		}
		return nil
	})
	if err != nil {
		return nil, mapErrIfPg(err)
	}
	return &out, nil
}
