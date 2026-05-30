package dto

import "github.com/ewallet-pg/wallet-service/internal/domain"

// OpenAccountRequest — POST /v1/accounts. acct_type validated by the SP.
type OpenAccountRequest struct {
	ClientNo string `json:"client_no"   binding:"required,max=48"`
	AcctType string `json:"acct_type"   binding:"required"`
	Ccy      string `json:"ccy,omitempty" binding:"omitempty,max=4"`
}

// UpdateAccountStatusRequest — PATCH /v1/accounts/:acct_no.
type UpdateAccountStatusRequest struct {
	Status string `json:"status" binding:"required,oneof=A B C"`
}

type AccountOpenResponse struct {
	AcctNo     string `json:"acct_no"`
	ClientNo   string `json:"client_no"`
	AcctType   string `json:"acct_type"`
	Ccy        string `json:"ccy"`
	AcctStatus string `json:"acct_status"`
}

type AccountStatusResponse struct {
	AcctNo     string `json:"acct_no"`
	AcctStatus string `json:"acct_status"`
	Version    int32  `json:"version"`
}

func AccountStatusRespFrom(r *domain.AccountStatusResult) AccountStatusResponse {
	return AccountStatusResponse{AcctNo: r.AcctNo, AcctStatus: r.AcctStatus, Version: r.Version}
}
