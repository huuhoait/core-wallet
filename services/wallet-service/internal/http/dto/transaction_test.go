package dto

import (
	"testing"
	"time"

	"github.com/ewallet-pg/wallet-service/internal/domain"
)

func entries(seqs ...int64) []domain.TxEntry {
	out := make([]domain.TxEntry, 0, len(seqs))
	for _, s := range seqs {
		out = append(out, domain.TxEntry{SeqNo: s})
	}
	return out
}

func TestTxListRespFrom_CursorOnlyWhenFullPage(t *testing.T) {
	q := domain.TxListQuery{AcctNo: "ACC", Limit: 3}

	// full page (len == limit) → next_cursor = last seq_no
	r := TxListRespFrom(q, entries(30, 20, 10))
	if r.Count != 3 {
		t.Fatalf("count = %d, want 3", r.Count)
	}
	if r.PageSize != 3 {
		t.Errorf("page_size = %d, want 3", r.PageSize)
	}
	if r.NextCursor == nil || *r.NextCursor != 10 {
		t.Errorf("next_cursor = %v, want 10 (last seq of a full page)", r.NextCursor)
	}

	// partial page (len < limit) → no cursor (end of statement)
	r = TxListRespFrom(q, entries(30, 20))
	if r.NextCursor != nil {
		t.Errorf("next_cursor = %v, want nil on a partial page", *r.NextCursor)
	}

	// empty page → no cursor
	r = TxListRespFrom(q, nil)
	if r.NextCursor != nil || r.Count != 0 {
		t.Errorf("empty: count=%d next_cursor=%v, want 0/nil", r.Count, r.NextCursor)
	}
}

func TestTxListRespFrom_EchoesDateRangeAndPageSize(t *testing.T) {
	from := time.Date(2026, 5, 1, 0, 0, 0, 0, time.UTC)
	to := time.Date(2026, 5, 30, 0, 0, 0, 0, time.UTC)
	r := TxListRespFrom(
		domain.TxListQuery{AcctNo: "ACC", Limit: 200, From: &from, To: &to},
		entries(10),
	)
	if r.From != "2026-05-01" || r.To != "2026-05-30" {
		t.Errorf("from/to = %q/%q, want 2026-05-01/2026-05-30", r.From, r.To)
	}
	if r.PageSize != 200 {
		t.Errorf("page_size = %d, want 200", r.PageSize)
	}
}
