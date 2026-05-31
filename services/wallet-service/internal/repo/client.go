// Client master CRUD adapters — create_client / update_client SECURITY DEFINER
// SPs (wallet_sp_client.sql). Writes → withTx so audit GUCs attribute the change.
package repo

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5"

	"github.com/ewallet-pg/wallet-service/internal/domain"
)

func (r *PgWalletRepo) CreateClient(ctx context.Context, in domain.ClientCreateInput) (*domain.ClientResult, error) {
	var out domain.ClientResult
	err := r.withTx(ctx, in.Audit, func(tx pgx.Tx) error {
		const q = `
			SELECT client_no, status, created_at
			  FROM create_client($1, $2, $3, $4, $5, $6, $7, $8, $9::date, $10, $11)
		`
		row := tx.QueryRow(ctx, q,
			in.ClientName, in.ClientType, nullStr(in.GlobalID), nullStr(in.GlobalIDType),
			nullStr(in.CountryLoc), nullStr(in.CountryCitizen),
			nullStr(in.Surname), nullStr(in.GivenName), nullDate(in.BirthDate), nullStr(in.Sex),
			in.Audit.Actor)
		return row.Scan(&out.ClientNo, &out.Status, &out.Timestamp)
	})
	if err != nil {
		return nil, mapErrIfPg(err)
	}
	return &out, nil
}

func (r *PgWalletRepo) LinkClientBank(ctx context.Context, in domain.BankLinkInput) (*domain.BankLinkResult, error) {
	var out domain.BankLinkResult
	err := r.withTx(ctx, in.Audit, func(tx pgx.Tx) error {
		const q = `
			SELECT link_id, client_no, is_default, status, created_at
			  FROM link_client_bank($1, $2, $3, $4, $5, $6, $7)
		`
		row := tx.QueryRow(ctx, q,
			in.ClientNo, in.BankCode, in.AcctNo,
			nullStr(in.BankName), nullStr(in.AcctHolderName),
			in.IsDefault, in.Audit.Actor)
		return row.Scan(&out.LinkID, &out.ClientNo, &out.IsDefault, &out.Status, &out.Timestamp)
	})
	if err != nil {
		return nil, mapErrIfPg(err)
	}
	return &out, nil
}

func (r *PgWalletRepo) SetDefaultClientBank(ctx context.Context, in domain.SetDefaultBankInput) (*domain.BankLinkResult, error) {
	var out domain.BankLinkResult
	err := r.withTx(ctx, in.Audit, func(tx pgx.Tx) error {
		const q = `
			SELECT link_id, client_no, is_default, status, updated_at
			  FROM set_default_client_bank($1, $2, $3)
		`
		row := tx.QueryRow(ctx, q, in.ClientNo, in.LinkID, in.Audit.Actor)
		return row.Scan(&out.LinkID, &out.ClientNo, &out.IsDefault, &out.Status, &out.Timestamp)
	})
	if err != nil {
		return nil, mapErrIfPg(err)
	}
	return &out, nil
}

func (r *PgWalletRepo) UpdateClient(ctx context.Context, in domain.ClientUpdateInput) (*domain.ClientResult, error) {
	var out domain.ClientResult
	err := r.withTx(ctx, in.Audit, func(tx pgx.Tx) error {
		const q = `
			SELECT client_no, status, updated_at
			  FROM update_client($1, $2, $3, $4, $5, $6, $7, $8::date, $9, $10)
		`
		row := tx.QueryRow(ctx, q,
			in.ClientNo, nullStr(in.ClientName), nullStr(in.Status),
			nullStr(in.CountryLoc), nullStr(in.CountryCitizen),
			nullStr(in.Surname), nullStr(in.GivenName), nullDate(in.BirthDate), nullStr(in.Sex),
			in.Audit.Actor)
		return row.Scan(&out.ClientNo, &out.Status, &out.Timestamp)
	})
	if err != nil {
		return nil, mapErrIfPg(err)
	}
	return &out, nil
}

// GetClient returns the MASKED client profile from v_client_masked (wallet_app
// path, readPool). Name + CCCD/passport come back masked; raw PII is never
// exposed here. Unknown client_no → 404. READ-ONLY: no TX, no audit GUCs.
func (r *PgWalletRepo) GetClient(ctx context.Context, clientNo string) (*domain.ClientView, error) {
	const q = `
		SELECT client_no, client_name_masked, client_type, global_id_type, global_id_masked,
		       country_loc, country_citizen, client_grp, acct_exec, status,
		       birth_date, sex, resident_status,
		       kyc_tier, kyc_status, risk_level, phone_masked, verified_at
		  FROM v_client_masked
		 WHERE client_no = $1
	`
	var c domain.ClientView
	err := r.readPool.QueryRow(ctx, q, clientNo).Scan(
		&c.ClientNo, &c.ClientNameMasked, &c.ClientType, &c.GlobalIDType, &c.GlobalIDMasked,
		&c.CountryLoc, &c.CountryCitizen, &c.ClientGrp, &c.AcctExec, &c.Status,
		&c.BirthDate, &c.Sex, &c.ResidentStatus,
		&c.KycTier, &c.KycStatus, &c.RiskLevel, &c.PhoneMasked, &c.VerifiedAt,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, domain.NotFound("client not found: "+clientNo, nil)
	}
	if err != nil {
		return nil, mapErrIfPg(err)
	}
	return &c, nil
}

// GetClientFull returns the UNMASKED client profile via the wallet_pii_ro pool
// (piiPool). Privileged P1/PII read — exposed only under /v1/ops. Phone/email
// stay encrypted at rest and are not decrypted here. Unknown client_no → 404.
// READ-ONLY: no TX, no audit GUCs.
func (r *PgWalletRepo) GetClientFull(ctx context.Context, clientNo string) (*domain.ClientFullView, error) {
	// IND personal details now live in FM_CLIENT_KYC.extra_data JSONB (US-1.15);
	// FM_CLIENT_INDVL was folded in and dropped. Read them via ->> on the KYC row.
	const q = `
		SELECT c.client_no, c.client_name, c.client_type, c.global_id, c.global_id_type,
		       c.country_loc, c.country_citizen, c.client_grp, c.acct_exec, c.status,
		       c.registered_date, c.created_at, c.updated_at,
		       k.extra_data->>'surname', k.extra_data->>'given_name',
		       (k.extra_data->>'birth_date')::date, k.extra_data->>'sex',
		       k.extra_data->>'resident_status', k.extra_data->>'marital_status',
		       k.kyc_tier, k.kyc_status, k.risk_level, k.verified_at
		  FROM FM_CLIENT c
		  LEFT JOIN LATERAL (
		    SELECT k2.kyc_tier, k2.status AS kyc_status, k2.risk_level, k2.verified_at, k2.extra_data
		      FROM FM_CLIENT_KYC k2
		     WHERE k2.client_no = c.client_no
		     ORDER BY k2.kyc_id DESC
		     LIMIT 1
		  ) k ON true
		 WHERE c.client_no = $1
	`
	var c domain.ClientFullView
	err := r.piiPool.QueryRow(ctx, q, clientNo).Scan(
		&c.ClientNo, &c.ClientName, &c.ClientType, &c.GlobalID, &c.GlobalIDType,
		&c.CountryLoc, &c.CountryCitizen, &c.ClientGrp, &c.AcctExec, &c.Status,
		&c.RegisteredDate, &c.CreatedAt, &c.UpdatedAt,
		&c.Surname, &c.GivenName, &c.BirthDate, &c.Sex, &c.ResidentStatus, &c.MaritalStatus,
		&c.KycTier, &c.KycStatus, &c.RiskLevel, &c.VerifiedAt,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, domain.NotFound("client not found: "+clientNo, nil)
	}
	if err != nil {
		return nil, mapErrIfPg(err)
	}
	return &c, nil
}
