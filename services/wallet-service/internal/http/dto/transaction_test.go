package dto

import (
	"testing"

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
	// full page (len == limit) → next_cursor = last seq_no
	r := TxListRespFrom("ACC", entries(30, 20, 10), 3)
	if r.Count != 3 {
		t.Fatalf("count = %d, want 3", r.Count)
	}
	if r.NextCursor == nil || *r.NextCursor != 10 {
		t.Errorf("next_cursor = %v, want 10 (last seq of a full page)", r.NextCursor)
	}

	// partial page (len < limit) → no cursor (end of statement)
	r = TxListRespFrom("ACC", entries(30, 20), 3)
	if r.NextCursor != nil {
		t.Errorf("next_cursor = %v, want nil on a partial page", *r.NextCursor)
	}

	// empty page → no cursor
	r = TxListRespFrom("ACC", nil, 3)
	if r.NextCursor != nil || r.Count != 0 {
		t.Errorf("empty: count=%d next_cursor=%v, want 0/nil", r.Count, r.NextCursor)
	}
}
