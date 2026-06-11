package dto

import (
	"github.com/ewallet-pg/wallet-service/internal/domain"
)

// SuspenseAgingRowResponse is one (GL, ccy) line of the suspense aging report.
// oldest_post_date is YYYY-MM-DD; amounts are decimal strings.
type SuspenseAgingRowResponse struct {
	GLCode         string `json:"gl_code"`
	GLDesc         string `json:"gl_desc"`
	Ccy            string `json:"ccy"`
	NetBalance     string `json:"net_balance"`
	Bucket0_30     string `json:"bucket_0_30"`
	Bucket31_60    string `json:"bucket_31_60"`
	Bucket61_90    string `json:"bucket_61_90"`
	Bucket90Plus   string `json:"bucket_90_plus"`
	OldestPostDate string `json:"oldest_post_date"`
}

// SuspenseAgingResponse is the suspense/clearing aging report (US-6.2).
type SuspenseAgingResponse struct {
	AsOf  string                     `json:"as_of"`
	Count int                        `json:"count"`
	Items []SuspenseAgingRowResponse `json:"items"`
}

// SuspenseAgingRespFrom maps the domain rows to the response. asOf is the
// report date (YYYY-MM-DD) the caller queried.
func SuspenseAgingRespFrom(asOf string, rows []domain.SuspenseAgingRow) SuspenseAgingResponse {
	items := make([]SuspenseAgingRowResponse, 0, len(rows))
	for _, r := range rows {
		items = append(items, SuspenseAgingRowResponse{
			GLCode:         r.GLCode,
			GLDesc:         r.GLDesc,
			Ccy:            r.Ccy,
			NetBalance:     r.NetBalance,
			Bucket0_30:     r.Bucket0_30,
			Bucket31_60:    r.Bucket31_60,
			Bucket61_90:    r.Bucket61_90,
			Bucket90Plus:   r.Bucket90Plus,
			OldestPostDate: r.OldestPostDate.Format("2006-01-02"),
		})
	}
	return SuspenseAgingResponse{AsOf: asOf, Count: len(items), Items: items}
}
