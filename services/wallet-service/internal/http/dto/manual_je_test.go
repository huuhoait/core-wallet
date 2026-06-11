package dto

import (
	"testing"

	"github.com/ewallet-pg/wallet-service/internal/domain"
)

func TestCreateManualJERequest_ToInput(t *testing.T) {
	req := CreateManualJERequest{
		Reference: "MJE-1", Ccy: "VND", Reason: "reclass", Narrative: "note",
		AccountingDate: "2026-06-10",
		Lines: []ManualJELineRequest{
			{GLCode: "109", TranNature: "DR", Amount: "100.00", ClientNo: "C1"},
			{GLCode: "201", TranNature: "CR", Amount: "100.00"},
		},
	}
	in := req.ToInput(domain.AuditContext{Actor: "MAKER_A"})

	if in.Reference != "MJE-1" || in.Ccy != "VND" || in.Reason != "reclass" || in.AccountingDate != "2026-06-10" {
		t.Fatalf("header not mapped: %+v", in)
	}
	if in.Audit.Actor != "MAKER_A" {
		t.Errorf("actor = %q, want MAKER_A", in.Audit.Actor)
	}
	if len(in.Lines) != 2 {
		t.Fatalf("lines = %d, want 2", len(in.Lines))
	}
	if in.Lines[0].GLCode != "109" || in.Lines[0].TranNature != "DR" || in.Lines[0].Amount != "100.00" || in.Lines[0].ClientNo != "C1" {
		t.Errorf("line[0] not mapped: %+v", in.Lines[0])
	}
}

func jeViews(ids ...int64) []domain.ManualJEView {
	out := make([]domain.ManualJEView, 0, len(ids))
	for _, id := range ids {
		out = append(out, domain.ManualJEView{JEID: id, Status: "PENDING"})
	}
	return out
}

func TestManualJEListRespFrom_CursorOnlyWhenFullPage(t *testing.T) {
	q := domain.ManualJEListQuery{Status: "PENDING", Limit: 3}

	// full page (len == limit) → next_cursor = last je_id
	r := ManualJEListRespFrom(q, jeViews(30, 20, 10))
	if r.Count != 3 || r.PageSize != 3 || r.Status != "PENDING" {
		t.Fatalf("unexpected list meta: %+v", r)
	}
	if r.NextCursor == nil || *r.NextCursor != 10 {
		t.Errorf("next_cursor = %v, want 10 (last id of a full page)", r.NextCursor)
	}

	// partial page (len < limit) → no cursor
	r = ManualJEListRespFrom(q, jeViews(30, 20))
	if r.NextCursor != nil {
		t.Errorf("next_cursor = %v, want nil on a partial page", *r.NextCursor)
	}
}
