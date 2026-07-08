// Client master CRUD adapters — create_client / update_client SECURITY DEFINER
// SPs (wallet_sp_client.sql). Writes → withTx so audit GUCs attribute the change.
package repo

import (
	"context"
	"encoding/json"
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

// OnboardClient runs onboard_client (US-1.1/1.7): create the client, its
// FM_CLIENT_KYC row (phone captured — no OTP) and the first zero-balance wallet
// in ONE TX. ExtraData (type-specific bag) is passed as jsonb; nil → {}.
func (r *PgWalletRepo) OnboardClient(ctx context.Context, in domain.OnboardInput) (*domain.OnboardResult, error) {
	extraJSON := "{}"
	if in.ExtraData != nil {
		b, err := json.Marshal(in.ExtraData)
		if err != nil {
			return nil, domain.InvalidRequest("extra_data not serialisable", err)
		}
		extraJSON = string(b) // pgx: pass JSON as text for $::jsonb (raw []byte → bytea)
	}
	var out domain.OnboardResult
	err := r.withTx(ctx, in.Audit, func(tx pgx.Tx) error {
		const q = `
			SELECT client_no, acct_no, internal_key, kyc_tier, kyc_status, balance, ccy, created_at
			  FROM onboard_client($1, $2, $3, $4, $5, $6, $7, $8, $9, $10,
			                      $11::date, $12, $13::date, $14::date, $15, $16::jsonb, $17)
		`
		row := tx.QueryRow(ctx, q,
			in.ClientName, in.ClientType, in.Phone,
			nullStr(in.GlobalID), nullStr(in.GlobalIDType), nullStr(in.Email),
			nullStr(in.CountryLoc), nullStr(in.CountryCitizen),
			nullStr(in.AcctType), nullStr(in.Ccy),
			nullDate(in.BirthDate), nullStr(in.Sex), nullDate(in.DateIssue),
			nullDate(in.ExpireDate), nullStr(in.PlaceIssue),
			extraJSON, in.Audit.Actor)
		return row.Scan(&out.ClientNo, &out.AcctNo, &out.InternalKey, &out.KycTier,
			&out.KycStatus, &out.Balance, &out.Ccy, &out.CreatedAt)
	})
	if err != nil {
		return nil, mapErrIfPg(err)
	}
	return &out, nil
}

// UpdateKYC runs update_kyc (US-1.2): patch the centralized FM_CLIENT_KYC row
// (eKYC fields, tier, risk) and MERGE extra_data. Nil/empty args are unchanged.
func (r *PgWalletRepo) UpdateKYC(ctx context.Context, in domain.KycUpdateInput) (*domain.KycResult, error) {
	var extraArg any // nil → SQL NULL → SP leaves extra_data unchanged
	if in.ExtraData != nil {
		b, err := json.Marshal(in.ExtraData)
		if err != nil {
			return nil, domain.InvalidRequest("extra_data not serialisable", err)
		}
		extraArg = string(b) // pgx: pass JSON as text for $::jsonb
	}
	var out domain.KycResult
	err := r.withTx(ctx, in.Audit, func(tx pgx.Tx) error {
		const q = `
			SELECT client_no, kyc_tier, status, risk_level, verified_at
			  FROM update_kyc($1, $2, $3, $4, $5, $6, $7::numeric, $8, $9::jsonb, $10)
		`
		row := tx.QueryRow(ctx, q,
			in.ClientNo, nullStr(in.KycTier), nullStr(in.Status), nullStr(in.RiskLevel),
			nullStr(in.EkycProvider), nullStr(in.EkycRef), in.FaceMatchScore,
			nullStr(in.LivenessResult), extraArg, in.Audit.Actor)
		return row.Scan(&out.ClientNo, &out.KycTier, &out.Status, &out.RiskLevel, &out.VerifiedAt)
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

// LogPIIAccess appends a PII-access row via the SECURITY DEFINER log_pii_access
// SP. It runs on the PRIMARY pool (wallet_app) — not the read-only pii pool — so
// the write is reliable, and outside withTx (no audit GUCs / no business TX): a
// privileged read is not a ledger mutation, and the actor is passed explicitly.
func (r *PgWalletRepo) LogPIIAccess(ctx context.Context, e domain.PIIAccessEntry) error {
	detail := []byte("{}")
	if len(e.Detail) > 0 {
		if b, err := json.Marshal(e.Detail); err == nil {
			detail = b
		}
	}
	const q = `SELECT log_pii_access($1, $2, $3, $4, $5, $6, $7, $8)`
	_, err := r.pool.Exec(ctx, q,
		e.Audit.Actor, e.AccessType, nullStr(e.ClientNo), detail,
		nullStr(string(e.Audit.Channel)), nullStr(e.Audit.RequestID),
		nullStr(e.Audit.TraceID), nullStr(e.Audit.IPAddress))
	if err != nil {
		return mapErrIfPg(err)
	}
	return nil
}

func (r *PgWalletRepo) AttachClientDocument(ctx context.Context, in domain.AttachDocumentInput) (*domain.AttachDocumentResult, error) {
	var out domain.AttachDocumentResult
	err := r.withTx(ctx, in.Audit, func(tx pgx.Tx) error {
		const q = `
			SELECT client_no, doc_count, related_docs
			  FROM attach_client_document($1, $2, $3, $4, $5)
		`
		// Empty Status → NULL so the SP applies its DEFAULT 'PENDING'.
		row := tx.QueryRow(ctx, q,
			in.ClientNo, in.DocType, in.Link, nullStr(in.Status), in.Audit.Actor)
		return row.Scan(&out.ClientNo, &out.DocCount, &out.RelatedDocs)
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

// ListClients returns a page of MASKED client profiles from v_client_masked
// (wallet_app path, readPool), keyset-paginated by client_no ascending with
// optional status / client_type filters. READ-ONLY: no TX, no audit GUCs.
func (r *PgWalletRepo) ListClients(ctx context.Context, q domain.ClientListQuery) ([]domain.ClientView, error) {
	const sql = `
		SELECT client_no, client_name_masked, client_type, global_id_type, global_id_masked,
		       country_loc, country_citizen, client_grp, acct_exec, status,
		       birth_date, sex, resident_status,
		       kyc_tier, kyc_status, risk_level, phone_masked, verified_at
		  FROM v_client_masked
		 WHERE ($2::varchar IS NULL OR client_no > $2)
		   AND ($3::varchar IS NULL OR status = $3)
		   AND ($4::varchar IS NULL OR client_type = $4)
		 ORDER BY client_no ASC
		 LIMIT $1
	`
	rows, err := r.readPool.Query(ctx, sql, q.Limit, q.AfterNo, q.Status, q.ClientType)
	if err != nil {
		return nil, mapErrIfPg(err)
	}
	defer rows.Close()

	// Constant capacity hint: keep the user-influenced limit out of make()
	// (CodeQL go/uncontrolled-allocation-size); append grows past it if needed.
	out := make([]domain.ClientView, 0, domain.DefaultClientPageSize)
	for rows.Next() {
		var c domain.ClientView
		if err := rows.Scan(
			&c.ClientNo, &c.ClientNameMasked, &c.ClientType, &c.GlobalIDType, &c.GlobalIDMasked,
			&c.CountryLoc, &c.CountryCitizen, &c.ClientGrp, &c.AcctExec, &c.Status,
			&c.BirthDate, &c.Sex, &c.ResidentStatus,
			&c.KycTier, &c.KycStatus, &c.RiskLevel, &c.PhoneMasked, &c.VerifiedAt,
		); err != nil {
			return nil, mapErrIfPg(err)
		}
		out = append(out, c)
	}
	if err := rows.Err(); err != nil {
		return nil, mapErrIfPg(err)
	}
	return out, nil
}

// GetClientFull returns the UNMASKED client profile via the wallet_pii_ro pool
// (piiPool). Privileged P1/PII read — exposed only under /v1/ops. Phone/email
// stay encrypted at rest and are not decrypted here. Unknown client_no → 404.
// READ-ONLY: no TX, no audit GUCs.
func (r *PgWalletRepo) GetClientFull(ctx context.Context, clientNo string) (*domain.ClientFullView, error) {
	// FM_CLIENT_INDVL was folded into FM_CLIENT_KYC (US-1.15). birthdate/sex are
	// flat real columns; surname/given_name/resident_status/marital_status remain
	// in extra_data JSONB.
	const q = `
		SELECT c.client_no, c.client_name, c.client_type, c.global_id, c.global_id_type,
		       c.country_loc, c.country_citizen, c.client_grp, c.acct_exec, c.status,
		       c.registered_date, c.created_at, c.updated_at,
		       k.extra_data->>'surname', k.extra_data->>'given_name',
		       k.birthdate, k.sex,
		       k.extra_data->>'resident_status', k.extra_data->>'marital_status',
		       k.kyc_tier, k.kyc_status, k.risk_level, k.verified_at
		  FROM FM_CLIENT c
		  LEFT JOIN LATERAL (
		    SELECT k2.kyc_tier, k2.status AS kyc_status, k2.risk_level, k2.verified_at,
		           k2.extra_data, k2.birthdate, k2.sex
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
