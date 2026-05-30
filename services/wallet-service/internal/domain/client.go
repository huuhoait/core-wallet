package domain

import "time"

// ClientCreateInput creates a client master record (create_client SP).
// No KYC/onboarding — identity only (FM_CLIENT + FM_CLIENT_INDVL when IND).
type ClientCreateInput struct {
	ClientName     string
	ClientType     string // 'IND' | 'CORP' (SP-validated)
	GlobalID       string // CCCD / passport / tax id
	GlobalIDType   string
	CountryLoc     string
	CountryCitizen string
	Surname        string // IND only
	GivenName      string // IND only
	BirthDate      string // YYYY-MM-DD; IND only
	Sex            string // IND only
	Audit          AuditContext
}

// ClientUpdateInput patches mutable identity fields (update_client SP).
// Empty fields are left unchanged (COALESCE in the SP).
type ClientUpdateInput struct {
	ClientNo       string
	ClientName     string
	Status         string
	CountryLoc     string
	CountryCitizen string
	Surname        string
	GivenName      string
	BirthDate      string
	Sex            string
	Audit          AuditContext
}

// ClientResult is returned by create_client / update_client.
type ClientResult struct {
	ClientNo  string
	Status    string
	Timestamp time.Time // created_at (create) | updated_at (update)
}
