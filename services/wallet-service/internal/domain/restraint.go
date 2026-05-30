package domain

import "time"

// RestraintInput adds a hold/lien on an account (add_restraint SP).
// Type ∈ {DEBIT,CREDIT,ALL,INFO}; Purpose ∈ §8.2.2 enum. PledgedAmt is a
// decimal string ("0" or empty = full block for DEBIT/ALL; ignored for INFO).
type RestraintInput struct {
	AcctNo       string
	Type         string
	Purpose      string
	PledgedAmt   string // decimal string; "" → 0
	StartDate    string // YYYY-MM-DD; "" → today (SP default)
	EndDate      string // YYYY-MM-DD; "" → no auto-expire
	Narrative    string
	ReferenceDoc string
	Audit        AuditContext
}

// ReleaseRestraintInput releases an active restraint by id.
type ReleaseRestraintInput struct {
	RestraintID int64
	Reason      string
	Audit       AuditContext
}

// RestraintResult is returned by add_restraint / release_restraint.
type RestraintResult struct {
	RestraintID       int64
	Status            string // 'A' (added) | 'R' (released)
	PledgedAmt        string // echoed pledged amount (add only; "" on release)
	AvailableBalAfter string
	Version           int32
}

// Restraint list pagination (keyset by seq_no DESC, mirroring transactions).
const (
	DefaultRestraintPageSize = 100
	MaxRestraintPageSize     = 200
)

// RestraintListQuery is the read-path filter for listing an account's
// restraints. The list returns ALL statuses (A/R/E); there is no status filter.
type RestraintListQuery struct {
	AcctNo    string
	Limit     int    // clamped to [1, MaxRestraintPageSize]
	BeforeSeq *int64 // keyset cursor: only rows with seq_no < BeforeSeq
}

// RestraintView is one restraint row on the read path (list + detail). It mirrors
// WLT_RESTRAINTS; AcctNo is resolved from INTERNAL_KEY (empty for group-scoped).
type RestraintView struct {
	RestraintID   int64      // WLT_RESTRAINTS.SEQ_NO
	AcctNo        string     // resolved via INTERNAL_KEY; "" if group-scoped
	Type          string     // DEBIT | CREDIT | ALL | INFO
	Purpose       string     // COURT_ORDER | AML_HOLD | ...
	PledgedAmt    string     // decimal string
	StartDate     time.Time  // DATE
	EndDate       *time.Time // DATE; nil = no auto-expire
	Status        string     // A (active) | R (released) | E (expired)
	Narrative     string
	ReferenceDoc  string
	CreatedAt     time.Time
	CreatedBy     string
	RemovedAt     *time.Time // set when released
	RemovedBy     *string
	RemovedReason *string
}
