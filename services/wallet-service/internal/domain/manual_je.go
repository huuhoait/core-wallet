package domain

import "time"

// Manual journal entry (US-6.5) — maker-checker GL adjusting entries. A maker
// drafts a balanced set of GL lines (suspense/clearing/corrections); a different
// checker approves it (posts into WLT_GL_BATCH) or rejects it. GL-only: a manual
// JE never touches customer wallet balances.

// ManualJELine is one DR/CR leg of a manual journal entry.
type ManualJELine struct {
	GLCode     string // FM_GL_MAST.gl_code (must exist + be active)
	TranNature string // DR | CR
	Amount     string // decimal string, > 0
	ClientNo   string // optional analytic dimension; "" → none
	Narrative  string // optional per-line note
}

// ManualJEInput drafts a balanced JE (create_manual_je). Maker = Audit.Actor.
type ManualJEInput struct {
	Reference      string // idempotency / external ref (unique)
	Ccy            string
	Reason         string // mandatory — why this adjustment
	Narrative      string
	AccountingDate string // YYYY-MM-DD; "" → SP default (current accounting date)
	Lines          []ManualJELine
	Audit          AuditContext
}

// ManualJEDecisionInput approves or rejects a PENDING JE by id. Checker = Audit.Actor.
type ManualJEDecisionInput struct {
	JEID   int64
	Reason string
	Audit  AuditContext
}

// ManualJECreateResult is returned by create_manual_je.
type ManualJECreateResult struct {
	JEID      int64
	Status    string // PENDING
	TotalDR   string
	TotalCR   string
	LineCount int32
}

// ManualJEApproveResult is returned by approve_manual_je.
type ManualJEApproveResult struct {
	JEID        int64
	Status      string // POSTED
	GLTranKey   int64  // WLT_GL_BATCH.tran_key the lines posted under
	PostedLines int32
}

// ManualJERejectResult is returned by reject_manual_je.
type ManualJERejectResult struct {
	JEID   int64
	Status string // REJECTED
}

// Manual JE list pagination (keyset by je_id DESC).
const (
	DefaultManualJEPageSize = 100
	MaxManualJEPageSize     = 200
)

// ManualJEListQuery is the read-path filter for listing journal entries.
type ManualJEListQuery struct {
	Status   string // optional: PENDING|POSTED|REJECTED; "" = all
	Limit    int    // clamped to [1, MaxManualJEPageSize]
	BeforeID *int64 // keyset cursor: only rows with je_id < BeforeID
}

// ManualJEView is one JE on the read path. Lines is populated on detail only.
type ManualJEView struct {
	JEID           int64
	Reference      string
	AccountingDate time.Time
	Ccy            string
	Narrative      string
	Reason         string
	Status         string
	TotalDR        string
	TotalCR        string
	GLTranKey      *int64
	MakerID        string
	MadeAt         time.Time
	CheckerID      *string
	CheckedAt      *time.Time
	CheckReason    *string
	Version        int32
	Lines          []ManualJELineView
}

// ManualJELineView is one line on the read path (detail).
type ManualJELineView struct {
	LineNo     int32
	GLCode     string
	TranNature string
	Amount     string
	ClientNo   *string
	Narrative  *string
}
