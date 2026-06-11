package dto

import (
	"testing"
	"time"

	"github.com/ewallet-pg/wallet-service/internal/domain"
)

func TestSuspenseAgingRespFrom(t *testing.T) {
	rows := []domain.SuspenseAgingRow{
		{
			GLCode: "109.04.002", GLDesc: "Unidentified receipts", Ccy: "VND",
			NetBalance: "8000.00", Bucket0_30: "3000.00", Bucket31_60: "0.00",
			Bucket61_90: "0.00", Bucket90Plus: "5000.00",
			OldestPostDate: time.Date(2026, 3, 1, 0, 0, 0, 0, time.UTC),
		},
	}
	r := SuspenseAgingRespFrom("2026-06-11", rows)

	if r.AsOf != "2026-06-11" || r.Count != 1 || len(r.Items) != 1 {
		t.Fatalf("envelope meta wrong: %+v", r)
	}
	it := r.Items[0]
	if it.GLCode != "109.04.002" || it.NetBalance != "8000.00" || it.Bucket90Plus != "5000.00" {
		t.Errorf("row not mapped: %+v", it)
	}
	if it.OldestPostDate != "2026-03-01" {
		t.Errorf("oldest_post_date = %q, want 2026-03-01 (YYYY-MM-DD)", it.OldestPostDate)
	}
}
