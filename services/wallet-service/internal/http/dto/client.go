package dto

import (
	"time"

	"github.com/ewallet-pg/wallet-service/internal/domain"
)

// CreateClientRequest — POST /v1/clients. client_type is validated by the SP
// (→ 422 INVALID_CLIENT_TYPE) so both layers agree on the code.
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
