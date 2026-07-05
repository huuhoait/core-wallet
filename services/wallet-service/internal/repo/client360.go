// Client 360 aggregate reads (profile + wallets + linked banks + restraints) and
// the unmasked client list. Masked paths run on readPool/wallet_app (v_*_masked
// views); unmasked paths run on piiPool/wallet_pii_ro and decrypt phone / email /
// bank acct_no inline with the DB-level DEK (current_setting('app.pii_dek')).
package repo

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5"

	"github.com/ewallet-pg/wallet-service/internal/domain"
)

// GetClient360 aggregates a client's profile, wallets, linked banks and
// restraints. unmask=false → masked profile (v_client_masked) + masked bank
// acct_no (wallet_app); unmask=true → raw profile with decrypted phone/email +
// decrypted bank acct_no (wallet_pii_ro). Unknown client → 404.
func (r *PgWalletRepo) GetClient360(ctx context.Context, clientNo string, unmask bool) (*domain.Client360, error) {
	out := &domain.Client360{}

	if unmask {
		full, err := r.getClientFullWithContacts(ctx, clientNo) // 404 if unknown
		if err != nil {
			return nil, err
		}
		out.Full = full
		banks, err := r.listClientBanksFull(ctx, clientNo)
		if err != nil {
			return nil, err
		}
		out.Banks = banks
	} else {
		masked, err := r.GetClient(ctx, clientNo) // 404 if unknown
		if err != nil {
			return nil, err
		}
		out.Masked = masked
		banks, err := r.listClientBanksMasked(ctx, clientNo)
		if err != nil {
			return nil, err
		}
		out.Banks = banks
	}

	// Wallets + restraints carry no PII → read on the lag-tolerant replica.
	accts, err := r.ListAccountsByClient(ctx, clientNo)
	if err != nil {
		return nil, err
	}
	out.Accounts = accts

	restraints, err := r.listRestraintsByClient(ctx, clientNo)
	if err != nil {
		return nil, err
	}
	out.Restraints = restraints

	return out, nil
}

// getClientFullWithContacts is GetClientFull plus the DECRYPTED phone + email
// (piiPool / wallet_pii_ro). Unknown client → 404.
func (r *PgWalletRepo) getClientFullWithContacts(ctx context.Context, clientNo string) (*domain.ClientFullView, error) {
	const q = `
		SELECT c.client_no, c.client_name, c.client_type, c.global_id, c.global_id_type,
		       c.country_loc, c.country_citizen, c.client_grp, c.acct_exec, c.status,
		       c.registered_date, c.created_at, c.updated_at,
		       k.extra_data->>'surname', k.extra_data->>'given_name',
		       k.birthdate, k.sex,
		       k.extra_data->>'resident_status', k.extra_data->>'marital_status',
		       k.kyc_tier, k.kyc_status, k.risk_level, k.verified_at,
		       CASE WHEN k.phone_no_enc IS NULL THEN NULL
		            ELSE pgp_sym_decrypt(k.phone_no_enc, current_setting('app.pii_dek'), 'cipher-algo=aes256') END,
		       CASE WHEN k.email_enc IS NULL THEN NULL
		            ELSE pgp_sym_decrypt(k.email_enc, current_setting('app.pii_dek'), 'cipher-algo=aes256') END
		  FROM FM_CLIENT c
		  LEFT JOIN LATERAL (
		    SELECT k2.kyc_tier, k2.status AS kyc_status, k2.risk_level, k2.verified_at,
		           k2.extra_data, k2.birthdate, k2.sex, k2.phone_no_enc, k2.email_enc
		      FROM FM_CLIENT_KYC k2
		     WHERE k2.client_no = c.client_no
		     ORDER BY k2.kyc_id DESC
		     LIMIT 1
		  ) k ON true
		 WHERE c.client_no = $1
	`
	var c domain.ClientFullView
	// Decrypts phone/email → run inside a per-TX DEK so pgp_sym_decrypt can see it.
	err := r.readWithDEK(ctx, r.piiPool, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, q, clientNo).Scan(
			&c.ClientNo, &c.ClientName, &c.ClientType, &c.GlobalID, &c.GlobalIDType,
			&c.CountryLoc, &c.CountryCitizen, &c.ClientGrp, &c.AcctExec, &c.Status,
			&c.RegisteredDate, &c.CreatedAt, &c.UpdatedAt,
			&c.Surname, &c.GivenName, &c.BirthDate, &c.Sex, &c.ResidentStatus, &c.MaritalStatus,
			&c.KycTier, &c.KycStatus, &c.RiskLevel, &c.VerifiedAt, &c.Phone, &c.Email,
		)
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, domain.NotFound("client not found: "+clientNo, nil)
	}
	if err != nil {
		return nil, mapErrIfPg(err)
	}
	return &c, nil
}

// listClientBanksMasked lists a client's banks with the acct_no MASKED, read from
// v_client_banks_masked (readPool / wallet_app). Empty slice when none.
//
// Even the MASKED path decrypts: the view calls pgp_sym_decrypt(…,
// current_setting('app.pii_dek')) to derive the '****'+last-4 mask, so it too must
// run under a per-TX DEK (readWithDEK) now that the DEK is app-held per-TX.
func (r *PgWalletRepo) listClientBanksMasked(ctx context.Context, clientNo string) ([]domain.ClientBankView, error) {
	const q = `
		SELECT link_id, bank_code, bank_name, COALESCE(acct_no_masked, ''),
		       acct_holder_name, (is_default <> 0), status, created_at
		  FROM v_client_banks_masked
		 WHERE client_no = $1
		 ORDER BY is_default DESC, link_id
	`
	var out []domain.ClientBankView
	err := r.readWithDEK(ctx, r.readPool, func(tx pgx.Tx) error {
		var e error
		out, e = r.scanClientBanks(ctx, tx, q, clientNo)
		return e
	})
	return out, err
}

// listClientBanksFull lists a client's banks with the acct_no DECRYPTED, read
// from FM_CLIENT_BANKS (piiPool / wallet_pii_ro). Empty slice when none. Runs
// under a per-TX DEK (readWithDEK) so pgp_sym_decrypt sees app.pii_dek.
func (r *PgWalletRepo) listClientBanksFull(ctx context.Context, clientNo string) ([]domain.ClientBankView, error) {
	const q = `
		SELECT link_id, bank_code, bank_name,
		       COALESCE(pgp_sym_decrypt(acct_no_enc, current_setting('app.pii_dek'), 'cipher-algo=aes256'), ''),
		       acct_holder_name, (is_default <> 0), status, created_at
		  FROM FM_CLIENT_BANKS
		 WHERE client_no = $1
		 ORDER BY is_default DESC, link_id
	`
	var out []domain.ClientBankView
	err := r.readWithDEK(ctx, r.piiPool, func(tx pgx.Tx) error {
		var e error
		out, e = r.scanClientBanks(ctx, tx, q, clientNo)
		return e
	})
	return out, err
}

// querier is the subset of *pgxpool.Pool / pgx.Tx used by the PII read scanners,
// so a query can run either directly on a pool or inside a readWithDEK TX.
type querier interface {
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}

func (r *PgWalletRepo) scanClientBanks(ctx context.Context, db querier, q, clientNo string) ([]domain.ClientBankView, error) {
	rows, err := db.Query(ctx, q, clientNo)
	if err != nil {
		return nil, mapErrIfPg(err)
	}
	defer rows.Close()
	out := make([]domain.ClientBankView, 0, 4)
	for rows.Next() {
		var b domain.ClientBankView
		if err := rows.Scan(
			&b.LinkID, &b.BankCode, &b.BankName, &b.AcctNo,
			&b.AcctHolderName, &b.IsDefault, &b.Status, &b.CreatedAt,
		); err != nil {
			return nil, mapErrIfPg(err)
		}
		out = append(out, b)
	}
	if err := rows.Err(); err != nil {
		return nil, mapErrIfPg(err)
	}
	return out, nil
}

// listRestraintsByClient returns every account-scoped restraint across all of a
// client's wallets, newest-first. No PII → readPool. Empty slice when none.
func (r *PgWalletRepo) listRestraintsByClient(ctx context.Context, clientNo string) ([]domain.RestraintView, error) {
	const q = `
		SELECT r.seq_no, COALESCE(a.acct_no, ''), r.restraint_type, r.restraint_purpose,
		       r.pledged_amt::text, r.start_date, r.end_date, r.status,
		       COALESCE(r.narrative, ''), COALESCE(r.reference_doc, ''),
		       r.created_at, r.created_by, r.removed_at, r.removed_by, r.removed_reason
		  FROM WLT_RESTRAINTS r
		  JOIN WLT_ACCT a ON a.internal_key = r.internal_key
		 WHERE a.client_no = $1
		 ORDER BY r.seq_no DESC
	`
	rows, err := r.readPool.Query(ctx, q, clientNo)
	if err != nil {
		return nil, mapErrIfPg(err)
	}
	defer rows.Close()
	out := make([]domain.RestraintView, 0, 4)
	for rows.Next() {
		var v domain.RestraintView
		if err := rows.Scan(
			&v.RestraintID, &v.AcctNo, &v.Type, &v.Purpose, &v.PledgedAmt,
			&v.StartDate, &v.EndDate, &v.Status, &v.Narrative, &v.ReferenceDoc,
			&v.CreatedAt, &v.CreatedBy, &v.RemovedAt, &v.RemovedBy, &v.RemovedReason,
		); err != nil {
			return nil, mapErrIfPg(err)
		}
		out = append(out, v)
	}
	if err := rows.Err(); err != nil {
		return nil, mapErrIfPg(err)
	}
	return out, nil
}

// ListClientsFull returns a keyset-paginated page of UNMASKED client profiles
// (raw name/CCCD + decrypted phone/email), read via wallet_pii_ro. Mirrors
// ListClients (masked) but on the privileged path. Keyset by client_no ascending.
func (r *PgWalletRepo) ListClientsFull(ctx context.Context, q domain.ClientListQuery) ([]domain.ClientFullView, error) {
	limit := q.Limit
	if limit <= 0 {
		limit = domain.DefaultClientPageSize
	}
	if limit > domain.MaxClientPageSize {
		limit = domain.MaxClientPageSize
	}

	const sql = `
		SELECT c.client_no, c.client_name, c.client_type, c.global_id, c.global_id_type,
		       c.country_loc, c.country_citizen, c.client_grp, c.acct_exec, c.status,
		       c.registered_date, c.created_at, c.updated_at,
		       k.extra_data->>'surname', k.extra_data->>'given_name',
		       k.birthdate, k.sex,
		       k.extra_data->>'resident_status', k.extra_data->>'marital_status',
		       k.kyc_tier, k.kyc_status, k.risk_level, k.verified_at,
		       CASE WHEN k.phone_no_enc IS NULL THEN NULL
		            ELSE pgp_sym_decrypt(k.phone_no_enc, current_setting('app.pii_dek'), 'cipher-algo=aes256') END,
		       CASE WHEN k.email_enc IS NULL THEN NULL
		            ELSE pgp_sym_decrypt(k.email_enc, current_setting('app.pii_dek'), 'cipher-algo=aes256') END
		  FROM FM_CLIENT c
		  LEFT JOIN LATERAL (
		    SELECT k2.kyc_tier, k2.status AS kyc_status, k2.risk_level, k2.verified_at,
		           k2.extra_data, k2.birthdate, k2.sex, k2.phone_no_enc, k2.email_enc
		      FROM FM_CLIENT_KYC k2
		     WHERE k2.client_no = c.client_no
		     ORDER BY k2.kyc_id DESC
		     LIMIT 1
		  ) k ON true
		 WHERE ($2::varchar IS NULL OR c.client_no > $2)
		   AND ($3::varchar IS NULL OR c.status = $3)
		   AND ($4::varchar IS NULL OR c.client_type = $4)
		 ORDER BY c.client_no ASC
		 LIMIT $1
	`
	// Decrypts phone/email → per-TX DEK (readWithDEK) so pgp_sym_decrypt sees it.
	out := make([]domain.ClientFullView, 0, limit)
	err := r.readWithDEK(ctx, r.piiPool, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, sql, limit, q.AfterNo, q.Status, q.ClientType)
		if err != nil {
			return mapErrIfPg(err)
		}
		defer rows.Close()
		for rows.Next() {
			var c domain.ClientFullView
			if err := rows.Scan(
				&c.ClientNo, &c.ClientName, &c.ClientType, &c.GlobalID, &c.GlobalIDType,
				&c.CountryLoc, &c.CountryCitizen, &c.ClientGrp, &c.AcctExec, &c.Status,
				&c.RegisteredDate, &c.CreatedAt, &c.UpdatedAt,
				&c.Surname, &c.GivenName, &c.BirthDate, &c.Sex, &c.ResidentStatus, &c.MaritalStatus,
				&c.KycTier, &c.KycStatus, &c.RiskLevel, &c.VerifiedAt, &c.Phone, &c.Email,
			); err != nil {
				return mapErrIfPg(err)
			}
			out = append(out, c)
		}
		return mapErrIfPg(rows.Err())
	})
	if err != nil {
		return nil, err
	}
	return out, nil
}
