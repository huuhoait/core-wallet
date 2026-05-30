package dto

import (
	"time"

	"github.com/ewallet-pg/wallet-service/internal/domain"
)

// AddRestraintRequest — POST /v1/finance/restraints.
// restraint_type / restraint_purpose are required but NOT bound with `oneof`:
// the add_restraint SP validates the enums so it returns the documented 422
// RESTRAINT_TYPE_INVALID / RESTRAINT_PURPOSE_INVALID codes (§4.9).
type AddRestraintRequest struct {
	AcctNo           string `json:"acct_no"           binding:"required,acct_no"`
	RestraintType    string `json:"restraint_type"    binding:"required"`
	RestraintPurpose string `json:"restraint_purpose" binding:"required"`
	PledgedAmt       string `json:"pledged_amt,omitempty"   binding:"omitempty,money"`
	StartDate        string `json:"start_date,omitempty"    binding:"omitempty,datetime=2006-01-02"`
	EndDate          string `json:"end_date,omitempty"      binding:"omitempty,datetime=2006-01-02"`
	Narrative        string `json:"narrative,omitempty"     binding:"omitempty,max=500"`
	ReferenceDoc     string `json:"reference_doc,omitempty" binding:"omitempty,max=500"`
}

// ReleaseRestraintRequest — POST /v1/finance/restraints/:id/release. Body is
// optional; `reason` is mandatory only for COURT_ORDER / TAX_LIEN (SP-enforced).
type ReleaseRestraintRequest struct {
	Reason string `json:"reason,omitempty" binding:"omitempty,max=500"`
}

type RestraintResponse struct {
	RestraintID       int64  `json:"restraint_id"`
	Status            string `json:"status"` // 'A' added | 'R' released
	PledgedAmt        string `json:"pledged_amt,omitempty"`
	AvailableBalAfter string `json:"available_bal_after"`
	Version           int32  `json:"version"`
}

func RestraintRespFrom(r *domain.RestraintResult) RestraintResponse {
	return RestraintResponse{
		RestraintID:       r.RestraintID,
		Status:            r.Status,
		PledgedAmt:        r.PledgedAmt,
		AvailableBalAfter: r.AvailableBalAfter,
		Version:           r.Version,
	}
}

// ----- restraint read (list + detail) --------------------------------------

// RestraintViewResponse is one restraint on the read path. DATE fields are
// rendered YYYY-MM-DD; timestamps are RFC 3339 (timestamptz).
type RestraintViewResponse struct {
	RestraintID   int64      `json:"restraint_id"`
	AcctNo        string     `json:"acct_no,omitempty"` // empty for group-scoped
	RestraintType string     `json:"restraint_type"`
	Purpose       string     `json:"restraint_purpose"`
	PledgedAmt    string     `json:"pledged_amt"`
	StartDate     string     `json:"start_date"`
	EndDate       string     `json:"end_date,omitempty"`
	Status        string     `json:"status"` // A active | R released | E expired
	Narrative     string     `json:"narrative,omitempty"`
	ReferenceDoc  string     `json:"reference_doc,omitempty"`
	CreatedAt     time.Time  `json:"created_at"`
	CreatedBy     string     `json:"created_by"`
	RemovedAt     *time.Time `json:"removed_at,omitempty"`
	RemovedBy     *string    `json:"removed_by,omitempty"`
	RemovedReason *string    `json:"removed_reason,omitempty"`
}

func restraintViewResp(v domain.RestraintView) RestraintViewResponse {
	out := RestraintViewResponse{
		RestraintID:   v.RestraintID,
		AcctNo:        v.AcctNo,
		RestraintType: v.Type,
		Purpose:       v.Purpose,
		PledgedAmt:    v.PledgedAmt,
		StartDate:     v.StartDate.Format("2006-01-02"),
		Status:        v.Status,
		Narrative:     v.Narrative,
		ReferenceDoc:  v.ReferenceDoc,
		CreatedAt:     v.CreatedAt,
		CreatedBy:     v.CreatedBy,
		RemovedAt:     v.RemovedAt,
		RemovedBy:     v.RemovedBy,
		RemovedReason: v.RemovedReason,
	}
	if v.EndDate != nil {
		out.EndDate = v.EndDate.Format("2006-01-02")
	}
	return out
}

// RestraintViewRespFrom maps a single restraint (GET /restraints/:id).
func RestraintViewRespFrom(v *domain.RestraintView) RestraintViewResponse {
	return restraintViewResp(*v)
}

// RestraintListResponse pages an account's restraints (keyset via next_cursor).
type RestraintListResponse struct {
	AcctNo     string                  `json:"acct_no"`
	PageSize   int                     `json:"page_size"`
	Items      []RestraintViewResponse `json:"items"`
	Count      int                     `json:"count"`
	NextCursor *int64                  `json:"next_cursor,omitempty"` // pass as ?before_seq= for the next page
}

func RestraintListRespFrom(q domain.RestraintListQuery, views []domain.RestraintView) RestraintListResponse {
	items := make([]RestraintViewResponse, 0, len(views))
	for _, v := range views {
		items = append(items, restraintViewResp(v))
	}
	out := RestraintListResponse{AcctNo: q.AcctNo, PageSize: q.Limit, Items: items, Count: len(items)}
	// A full page implies more rows may exist → expose the keyset cursor.
	if q.Limit > 0 && len(views) == q.Limit {
		last := views[len(views)-1].RestraintID
		out.NextCursor = &last
	}
	return out
}
