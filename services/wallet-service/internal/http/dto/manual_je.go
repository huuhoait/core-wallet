package dto

import (
	"github.com/ewallet-pg/wallet-service/internal/domain"
)

// ----- manual journal entry: maker-checker (US-6.5) ------------------------

// ManualJELineRequest is one DR/CR leg. gl_code / tran_nature are validated by
// the create_manual_je SP (so it returns the documented MJE_GL_INVALID /
// MJE_INVALID_LINES codes), not bound with `oneof` here.
type ManualJELineRequest struct {
	GLCode     string `json:"gl_code"     binding:"required,max=32"`
	TranNature string `json:"tran_nature" binding:"required"` // DR | CR (SP-validated)
	Amount     string `json:"amount"      binding:"required,money"`
	ClientNo   string `json:"client_no,omitempty" binding:"omitempty,max=48"`
	Narrative  string `json:"narrative,omitempty" binding:"omitempty,max=200"`
}

// CreateManualJERequest — POST /v1/ops/gl/journal-entries (maker).
type CreateManualJERequest struct {
	Reference      string                `json:"reference"            binding:"required,min=4,max=64"`
	Ccy            string                `json:"ccy"                  binding:"required,len=3"`
	Reason         string                `json:"reason"               binding:"required,max=200"`
	Narrative      string                `json:"narrative,omitempty"  binding:"omitempty,max=200"`
	AccountingDate string                `json:"accounting_date,omitempty" binding:"omitempty,datetime=2006-01-02"`
	Lines          []ManualJELineRequest `json:"lines"                binding:"required,min=2,dive"`
}

// ManualJEDecisionRequest — POST .../approve and .../reject. Body optional.
type ManualJEDecisionRequest struct {
	Reason string `json:"reason,omitempty" binding:"omitempty,max=200"`
}

func (r CreateManualJERequest) ToInput(audit domain.AuditContext) domain.ManualJEInput {
	lines := make([]domain.ManualJELine, 0, len(r.Lines))
	for _, l := range r.Lines {
		lines = append(lines, domain.ManualJELine{
			GLCode: l.GLCode, TranNature: l.TranNature, Amount: l.Amount,
			ClientNo: l.ClientNo, Narrative: l.Narrative,
		})
	}
	return domain.ManualJEInput{
		Reference: r.Reference, Ccy: r.Ccy, Reason: r.Reason, Narrative: r.Narrative,
		AccountingDate: r.AccountingDate, Lines: lines, Audit: audit,
	}
}

// ManualJECreateResponse — the PENDING draft result.
type ManualJECreateResponse struct {
	JEID      int64  `json:"je_id"`
	Status    string `json:"status"`
	TotalDR   string `json:"total_dr"`
	TotalCR   string `json:"total_cr"`
	LineCount int32  `json:"line_count"`
}

func ManualJECreateRespFrom(r *domain.ManualJECreateResult) ManualJECreateResponse {
	return ManualJECreateResponse{
		JEID: r.JEID, Status: r.Status, TotalDR: r.TotalDR, TotalCR: r.TotalCR, LineCount: r.LineCount,
	}
}

// ManualJEApproveResponse — POSTED result (with the GL tran_key it landed on).
type ManualJEApproveResponse struct {
	JEID        int64  `json:"je_id"`
	Status      string `json:"status"`
	GLTranKey   int64  `json:"gl_tran_key"`
	PostedLines int32  `json:"posted_lines"`
}

func ManualJEApproveRespFrom(r *domain.ManualJEApproveResult) ManualJEApproveResponse {
	return ManualJEApproveResponse{
		JEID: r.JEID, Status: r.Status, GLTranKey: r.GLTranKey, PostedLines: r.PostedLines,
	}
}

// ManualJERejectResponse — REJECTED result.
type ManualJERejectResponse struct {
	JEID   int64  `json:"je_id"`
	Status string `json:"status"`
}

func ManualJERejectRespFrom(r *domain.ManualJERejectResult) ManualJERejectResponse {
	return ManualJERejectResponse{JEID: r.JEID, Status: r.Status}
}

// ----- manual JE read (list + detail) --------------------------------------

type ManualJELineResponse struct {
	LineNo     int32   `json:"line_no"`
	GLCode     string  `json:"gl_code"`
	TranNature string  `json:"tran_nature"`
	Amount     string  `json:"amount"`
	ClientNo   *string `json:"client_no,omitempty"`
	Narrative  *string `json:"narrative,omitempty"`
}

// ManualJEViewResponse is one JE on the read path. accounting_date is YYYY-MM-DD;
// timestamps are RFC 3339. Lines is present only on the detail endpoint.
type ManualJEViewResponse struct {
	JEID           int64                  `json:"je_id"`
	Reference      string                 `json:"reference"`
	AccountingDate string                 `json:"accounting_date"`
	Ccy            string                 `json:"ccy"`
	Narrative      string                 `json:"narrative,omitempty"`
	Reason         string                 `json:"reason"`
	Status         string                 `json:"status"`
	TotalDR        string                 `json:"total_dr"`
	TotalCR        string                 `json:"total_cr"`
	GLTranKey      *int64                 `json:"gl_tran_key,omitempty"`
	MakerID        string                 `json:"maker_id"`
	MadeAt         string                 `json:"made_at"`
	CheckerID      *string                `json:"checker_id,omitempty"`
	CheckedAt      *string                `json:"checked_at,omitempty"`
	CheckReason    *string                `json:"check_reason,omitempty"`
	Version        int32                  `json:"version"`
	Lines          []ManualJELineResponse `json:"lines,omitempty"`
}

func manualJEView(v domain.ManualJEView) ManualJEViewResponse {
	out := ManualJEViewResponse{
		JEID:           v.JEID,
		Reference:      v.Reference,
		AccountingDate: v.AccountingDate.Format("2006-01-02"),
		Ccy:            v.Ccy,
		Narrative:      v.Narrative,
		Reason:         v.Reason,
		Status:         v.Status,
		TotalDR:        v.TotalDR,
		TotalCR:        v.TotalCR,
		GLTranKey:      v.GLTranKey,
		MakerID:        v.MakerID,
		MadeAt:         v.MadeAt.Format("2006-01-02T15:04:05Z07:00"),
		CheckerID:      v.CheckerID,
		CheckReason:    v.CheckReason,
		Version:        v.Version,
	}
	if v.CheckedAt != nil {
		s := v.CheckedAt.Format("2006-01-02T15:04:05Z07:00")
		out.CheckedAt = &s
	}
	for _, l := range v.Lines {
		out.Lines = append(out.Lines, ManualJELineResponse{
			LineNo: l.LineNo, GLCode: l.GLCode, TranNature: l.TranNature,
			Amount: l.Amount, ClientNo: l.ClientNo, Narrative: l.Narrative,
		})
	}
	return out
}

// ManualJEViewRespFrom maps a single JE (GET .../:je_id).
func ManualJEViewRespFrom(v *domain.ManualJEView) ManualJEViewResponse { return manualJEView(*v) }

// ManualJEListResponse pages JE headers (keyset via next_cursor).
type ManualJEListResponse struct {
	Status     string                 `json:"status,omitempty"`
	PageSize   int                    `json:"page_size"`
	Items      []ManualJEViewResponse `json:"items"`
	Count      int                    `json:"count"`
	NextCursor *int64                 `json:"next_cursor,omitempty"`
}

func ManualJEListRespFrom(q domain.ManualJEListQuery, views []domain.ManualJEView) ManualJEListResponse {
	items := make([]ManualJEViewResponse, 0, len(views))
	for _, v := range views {
		items = append(items, manualJEView(v))
	}
	out := ManualJEListResponse{Status: q.Status, PageSize: q.Limit, Items: items, Count: len(items)}
	if q.Limit > 0 && len(views) == q.Limit {
		last := views[len(views)-1].JEID
		out.NextCursor = &last
	}
	return out
}
