package domain

// AccountOpenInput opens a wallet for a client (open_account SP). KYC-tier
// gating is intentionally not enforced (onboarding out of scope).
type AccountOpenInput struct {
	ClientNo string
	AcctType string // 'CONSUMER' | 'MERCHANT' (SP-validated)
	Ccy      string // "" → VND
	Audit    AuditContext
}

// AccountStatusInput changes account status (update_account_status SP):
// 'A' active | 'B' blocked | 'C' closed (close requires zero balance).
type AccountStatusInput struct {
	AcctNo string
	Status string
	Audit  AuditContext
}

// AccountOpenResult is returned by open_account.
type AccountOpenResult struct {
	AcctNo      string
	InternalKey int64
	AcctStatus  string
}

// AccountStatusResult is returned by update_account_status.
type AccountStatusResult struct {
	AcctNo     string
	AcctStatus string
	Version    int32
}
