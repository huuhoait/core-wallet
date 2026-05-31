package dto

import (
	"time"

	"github.com/ewallet-pg/wallet-service/internal/domain"
)

// CreateClientRequest — POST /v1/clients. client_type is one of IND (individual),
// CORP (corporate) or MER (merchant) — validated by the SP (→ 422 INVALID_CLIENT_TYPE)
// so both layers agree on the code. CORP and MER are organization-like and create
// only the FM_CLIENT row; IND also creates FM_CLIENT_INDVL.
type CreateClientRequest struct {
	ClientName     string `json:"client_name"              binding:"required,max=200"`
	ClientType     string `json:"client_type"              binding:"required"`
	GlobalID       string `json:"global_id,omitempty"      binding:"omitempty,max=64"`
	GlobalIDType   string `json:"global_id_type,omitempty" binding:"omitempty,max=12"`
	CountryLoc     string `json:"country_loc,omitempty"    binding:"omitempty,max=8"`
	CountryCitizen string `json:"country_citizen,omitempty" binding:"omitempty,max=8"`
	Surname        string `json:"surname,omitempty"        binding:"omitempty,max=80"`
	GivenName      string `json:"given_name,omitempty"     binding:"omitempty,max=80"`
	BirthDate      string `json:"birth_date,omitempty"     binding:"omitempty,datetime=2006-01-02"`
	Sex            string `json:"sex,omitempty"            binding:"omitempty,oneof=M F O"`
}

// UpdateClientRequest — PATCH /v1/clients/:client_no. All fields optional.
type UpdateClientRequest struct {
	ClientName     string `json:"client_name,omitempty"     binding:"omitempty,max=200"`
	Status         string `json:"status,omitempty"          binding:"omitempty,max=4"`
	CountryLoc     string `json:"country_loc,omitempty"     binding:"omitempty,max=8"`
	CountryCitizen string `json:"country_citizen,omitempty" binding:"omitempty,max=8"`
	Surname        string `json:"surname,omitempty"         binding:"omitempty,max=80"`
	GivenName      string `json:"given_name,omitempty"      binding:"omitempty,max=80"`
	BirthDate      string `json:"birth_date,omitempty"      binding:"omitempty,datetime=2006-01-02"`
	Sex            string `json:"sex,omitempty"             binding:"omitempty,oneof=M F O"`
}

type ClientResponse struct {
	ClientNo  string    `json:"client_no"`
	Status    string    `json:"status"`
	Timestamp time.Time `json:"timestamp"`
}

func ClientRespFrom(r *domain.ClientResult) ClientResponse {
	return ClientResponse{ClientNo: r.ClientNo, Status: r.Status, Timestamp: r.Timestamp}
}

// LinkBankRequest — POST /v1/clients/:client_no/banks. acct_no is plaintext;
// the SP encrypts it to ACCT_NO_ENC (never stored or echoed in clear).
type LinkBankRequest struct {
	BankCode       string `json:"bank_code"                  binding:"required,max=20"`
	AcctNo         string `json:"acct_no"                    binding:"required,max=40"`
	BankName       string `json:"bank_name,omitempty"        binding:"omitempty,max=120"`
	AcctHolderName string `json:"acct_holder_name,omitempty" binding:"omitempty,max=200"`
	IsDefault      bool   `json:"is_default,omitempty"`
}

// BankLinkResponse — link_client_bank / set_default_client_bank result.
type BankLinkResponse struct {
	LinkID    int64     `json:"link_id"`
	ClientNo  string    `json:"client_no"`
	IsDefault bool      `json:"is_default"`
	Status    string    `json:"status"`
	Timestamp time.Time `json:"timestamp"`
}

func BankLinkRespFrom(r *domain.BankLinkResult) BankLinkResponse {
	return BankLinkResponse{
		LinkID:    r.LinkID,
		ClientNo:  r.ClientNo,
		IsDefault: r.IsDefault != 0,
		Status:    r.Status,
		Timestamp: r.Timestamp,
	}
}

// datePtr renders an optional date as YYYY-MM-DD (nil → omitted).
func datePtr(t *time.Time) *string {
	if t == nil {
		return nil
	}
	s := t.Format("2006-01-02")
	return &s
}

// ClientProfileResponse — GET /v1/clients/:client_no (MASKED). Name and CCCD/
// passport are masked; raw PII never appears on this path.
type ClientProfileResponse struct {
	ClientNo         string     `json:"client_no"`
	ClientNameMasked string     `json:"client_name_masked"`
	ClientType       *string    `json:"client_type,omitempty"`
	GlobalIDType     *string    `json:"global_id_type,omitempty"`
	GlobalIDMasked   *string    `json:"global_id_masked,omitempty"`
	CountryLoc       *string    `json:"country_loc,omitempty"`
	CountryCitizen   *string    `json:"country_citizen,omitempty"`
	ClientGrp        *string    `json:"client_grp,omitempty"`
	AcctExec         *string    `json:"acct_exec,omitempty"`
	Status           string     `json:"status"`
	BirthDate        *string    `json:"birth_date,omitempty"`
	Sex              *string    `json:"sex,omitempty"`
	ResidentStatus   *string    `json:"resident_status,omitempty"`
	KycTier          *string    `json:"kyc_tier,omitempty"`
	KycStatus        *string    `json:"kyc_status,omitempty"`
	RiskLevel        *string    `json:"risk_level,omitempty"`
	PhoneMasked      *string    `json:"phone_masked,omitempty"`
	VerifiedAt       *time.Time `json:"verified_at,omitempty"`
}

func ClientProfileRespFrom(c *domain.ClientView) ClientProfileResponse {
	return ClientProfileResponse{
		ClientNo: c.ClientNo, ClientNameMasked: c.ClientNameMasked,
		ClientType: c.ClientType, GlobalIDType: c.GlobalIDType, GlobalIDMasked: c.GlobalIDMasked,
		CountryLoc: c.CountryLoc, CountryCitizen: c.CountryCitizen, ClientGrp: c.ClientGrp, AcctExec: c.AcctExec,
		Status: c.Status, BirthDate: datePtr(c.BirthDate), Sex: c.Sex, ResidentStatus: c.ResidentStatus,
		KycTier: c.KycTier, KycStatus: c.KycStatus, RiskLevel: c.RiskLevel, PhoneMasked: c.PhoneMasked,
		VerifiedAt: c.VerifiedAt,
	}
}

// ClientFullResponse — GET /v1/ops/clients/:client_no (UNMASKED, wallet_pii_ro).
// Raw name + CCCD/passport. Phone/email stay encrypted at rest (not returned).
type ClientFullResponse struct {
	ClientNo       string     `json:"client_no"`
	ClientName     string     `json:"client_name"`
	ClientType     *string    `json:"client_type,omitempty"`
	GlobalID       *string    `json:"global_id,omitempty"`
	GlobalIDType   *string    `json:"global_id_type,omitempty"`
	CountryLoc     *string    `json:"country_loc,omitempty"`
	CountryCitizen *string    `json:"country_citizen,omitempty"`
	ClientGrp      *string    `json:"client_grp,omitempty"`
	AcctExec       *string    `json:"acct_exec,omitempty"`
	Status         string     `json:"status"`
	RegisteredDate *string    `json:"registered_date,omitempty"`
	CreatedAt      time.Time  `json:"created_at"`
	UpdatedAt      time.Time  `json:"updated_at"`
	Surname        *string    `json:"surname,omitempty"`
	GivenName      *string    `json:"given_name,omitempty"`
	BirthDate      *string    `json:"birth_date,omitempty"`
	Sex            *string    `json:"sex,omitempty"`
	ResidentStatus *string    `json:"resident_status,omitempty"`
	MaritalStatus  *string    `json:"marital_status,omitempty"`
	KycTier        *string    `json:"kyc_tier,omitempty"`
	KycStatus      *string    `json:"kyc_status,omitempty"`
	RiskLevel      *string    `json:"risk_level,omitempty"`
	VerifiedAt     *time.Time `json:"verified_at,omitempty"`
}

func ClientFullRespFrom(c *domain.ClientFullView) ClientFullResponse {
	return ClientFullResponse{
		ClientNo: c.ClientNo, ClientName: c.ClientName, ClientType: c.ClientType,
		GlobalID: c.GlobalID, GlobalIDType: c.GlobalIDType,
		CountryLoc: c.CountryLoc, CountryCitizen: c.CountryCitizen, ClientGrp: c.ClientGrp, AcctExec: c.AcctExec,
		Status: c.Status, RegisteredDate: datePtr(c.RegisteredDate), CreatedAt: c.CreatedAt, UpdatedAt: c.UpdatedAt,
		Surname: c.Surname, GivenName: c.GivenName, BirthDate: datePtr(c.BirthDate), Sex: c.Sex,
		ResidentStatus: c.ResidentStatus, MaritalStatus: c.MaritalStatus,
		KycTier: c.KycTier, KycStatus: c.KycStatus, RiskLevel: c.RiskLevel, VerifiedAt: c.VerifiedAt,
	}
}
