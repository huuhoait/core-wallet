package domain

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
