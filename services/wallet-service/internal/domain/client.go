package domain

import "time"

// ClientCreateInput creates a client master record (create_client SP).
// No KYC/onboarding — identity only (FM_CLIENT + FM_CLIENT_INDVL when IND).
type ClientCreateInput struct {
	ClientName     string
	ClientType     string // 'IND' | 'CORP' | 'MER' (SP-validated; CORP/MER are org-like)
	GlobalID       string // CCCD / passport / tax id
	GlobalIDType   string
	CountryLoc     string
	CountryCitizen string
	Surname        string // IND only
	GivenName      string // IND only
	BirthDate      string // YYYY-MM-DD; IND only
	Sex            string // IND only
	Audit          AuditContext
}

// ClientUpdateInput patches mutable identity fields (update_client SP).
// Empty fields are left unchanged (COALESCE in the SP).
type ClientUpdateInput struct {
	ClientNo       string
	ClientName     string
	Status         string
	CountryLoc     string
	CountryCitizen string
	Surname        string
	GivenName      string
	BirthDate      string
	Sex            string
	Audit          AuditContext
}

// ClientResult is returned by create_client / update_client.
type ClientResult struct {
	ClientNo  string
	Status    string
	Timestamp time.Time // created_at (create) | updated_at (update)
}

// BankLinkInput links a bank account to a client (link_client_bank SP).
// AcctNo is plaintext in; the SP encrypts it to ACCT_NO_ENC (pgp_sym_encrypt).
type BankLinkInput struct {
	ClientNo       string
	BankCode       string
	AcctNo         string // plaintext; SP encrypts
	BankName       string
	AcctHolderName string
	IsDefault      bool
	Audit          AuditContext
}

// SetDefaultBankInput makes an existing link the client's sole default
// (set_default_client_bank SP).
type SetDefaultBankInput struct {
	ClientNo string
	LinkID   int64
	Audit    AuditContext
}

// BankLinkResult is returned by link_client_bank / set_default_client_bank.
type BankLinkResult struct {
	LinkID    int64
	ClientNo  string
	IsDefault int16  // 0 | 1
	Status    string
	Timestamp time.Time // created_at (link) | updated_at (set-default)
}

// ClientView is the MASKED client profile (GET /v1/clients/:client_no), read
// from v_client_masked via wallet_app. Name and CCCD/passport are masked; raw
// PII is never exposed on this path. Nullable columns are pointers.
type ClientView struct {
	ClientNo         string
	ClientNameMasked string
	ClientType       *string
	GlobalIDType     *string
	GlobalIDMasked   *string
	CountryLoc       *string
	CountryCitizen   *string
	ClientGrp        *string
	AcctExec         *string
	Status           string
	BirthDate        *time.Time
	Sex              *string
	ResidentStatus   *string
	KycTier          *string
	KycStatus        *string
	RiskLevel        *string
	PhoneMasked      *string
	VerifiedAt       *time.Time
}

// ClientFullView is the UNMASKED client profile (GET /v1/ops/clients/:client_no),
// read from the raw tables via the wallet_pii_ro role. Every read of this view is
// a P1 (PII) access and SHOULD be appended to WLT_PII_ACCESS_LOG (not yet built —
// see US-8.4). Phone/email stay encrypted at rest and are not decrypted here.
type ClientFullView struct {
	ClientNo       string
	ClientName     string
	ClientType     *string
	GlobalID       *string
	GlobalIDType   *string
	CountryLoc     *string
	CountryCitizen *string
	ClientGrp      *string
	AcctExec       *string
	Status         string
	RegisteredDate *time.Time
	CreatedAt      time.Time
	UpdatedAt      time.Time
	Surname        *string
	GivenName      *string
	BirthDate      *time.Time
	Sex            *string
	ResidentStatus *string
	MaritalStatus  *string
	KycTier        *string
	KycStatus      *string
	RiskLevel      *string
	VerifiedAt     *time.Time
}
