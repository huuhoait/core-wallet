package dto

import "github.com/ewallet-pg/wallet-service/internal/domain"

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
