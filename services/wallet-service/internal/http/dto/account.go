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

// AccountListResponse — GET /v1/clients/:client_no/accounts. All wallets owned
// by a client (full account profiles, no PII). Items reuse AccountResponse.
type AccountListResponse struct {
	ClientNo string            `json:"client_no"`
	Items    []AccountResponse `json:"items"`
	Count    int               `json:"count"`
}

func AccountListRespFrom(clientNo string, views []domain.AccountView) AccountListResponse {
	items := make([]AccountResponse, 0, len(views))
	for i := range views {
		items = append(items, AccountRespFrom(&views[i]))
	}
	return AccountListResponse{ClientNo: clientNo, Items: items, Count: len(items)}
}

// AccountSearchItem — one hit of GET /v1/accounts/search (masked name).
type AccountSearchItem struct {
	AcctNo   string `json:"acct_no"`
	ClientNo string `json:"client_no"`
	Name     string `json:"name"` // masked client name
}

// AccountSearchResponse — GET /v1/accounts/search result.
type AccountSearchResponse struct {
	Query string              `json:"query"`
	Items []AccountSearchItem `json:"items"`
	Count int                 `json:"count"`
}

func AccountSearchRespFrom(query string, hits []domain.AccountSearchItem) AccountSearchResponse {
	items := make([]AccountSearchItem, 0, len(hits))
	for _, h := range hits {
		items = append(items, AccountSearchItem{AcctNo: h.AcctNo, ClientNo: h.ClientNo, Name: h.Name})
	}
	return AccountSearchResponse{Query: query, Items: items, Count: len(items)}
}
