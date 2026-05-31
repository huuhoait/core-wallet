package domain

import "time"

// ClientCreateInput creates a client master record (create_client SP): FM_CLIENT
// plus one FM_CLIENT_KYC row (tier 1 / status P, phone captured later by onboarding).
// IND personal fields (Surname/GivenName/BirthDate/Sex) fold into extra_data JSONB.
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

// OnboardInput — POST /v1/onboard (US-1.1/1.7): step 1 of the OTP-free flow.
// One TX creates FM_CLIENT, its FM_CLIENT_KYC row (phone captured, tier 1) and
// the first zero-balance wallet. ExtraData carries type-specific identity (IND
// surname/given_name/…; ORG legal_rep/ubo/business_reg_no — required for CORP/MER).
type OnboardInput struct {
	ClientName     string
	ClientType     string // IND | CORP | MER
	Phone          string // VN format 0xxxxxxxxx (captured, not OTP-verified)
	GlobalID       string
	GlobalIDType   string
	Email          string
	CountryLoc     string
	CountryCitizen string
	AcctType       string // CONSUMER | MERCHANT ("" → CONSUMER)
	Ccy            string // "" → VND
	// Flat identity columns on FM_CLIENT_KYC (dates as YYYY-MM-DD; "" → NULL).
	BirthDate  string
	Sex        string
	DateIssue  string // identity-doc issuance date
	ExpireDate string // identity-doc expiry date
	PlaceIssue string // identity-doc place of issuance
	ExtraData  map[string]any
	Audit      AuditContext
}

// OnboardResult is returned by onboard_client.
type OnboardResult struct {
	ClientNo    string
	AcctNo      string
	InternalKey int64
	KycTier     string
	KycStatus   string
	Balance     string // numeric → string (always "0" at onboarding)
	Ccy         string
	CreatedAt   time.Time
}

// KycUpdateInput — POST /v1/clients/:client_no/kyc (US-1.2): submit/update eKYC
// info and raise the tier. Empty/nil fields are left unchanged; ExtraData (when
// present) is MERGED into FM_CLIENT_KYC.extra_data.
type KycUpdateInput struct {
	ClientNo       string
	KycTier        string // "" = unchanged; else 0..3
	Status         string
	RiskLevel      string
	EkycProvider   string
	EkycRef        string
	FaceMatchScore *float64 // nil = unchanged
	LivenessResult string
	ExtraData      map[string]any // nil = unchanged
	Audit          AuditContext
}

// KycResult is returned by update_kyc.
type KycResult struct {
	ClientNo   string
	KycTier    string
	Status     string
	RiskLevel  string
	VerifiedAt *time.Time
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
