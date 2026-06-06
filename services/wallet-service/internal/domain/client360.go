package domain

import "time"

// ClientBankView is one linked bank for a client. AcctNo carries the MASKED
// account number ('****' + last 4) on the masked 360 path, or the DECRYPTED
// cleartext on the unmasked (wallet_pii_ro) path.
type ClientBankView struct {
	LinkID         int64
	BankCode       string
	BankName       *string
	AcctNo         string
	AcctHolderName *string
	IsDefault      bool
	Status         string
	CreatedAt      time.Time
}

// Client360 is the aggregate customer view: profile + wallets + linked banks +
// restraints. Exactly one of Masked / Full is set — Masked for the wallet_app
// path (PII masked), Full for the wallet_pii_ro path (raw + decrypted phone/email).
// Accounts/restraints/banks are shared; banks carry masked vs decrypted acct_no.
type Client360 struct {
	Masked     *ClientView
	Full       *ClientFullView
	Accounts   []AccountView
	Banks      []ClientBankView
	Restraints []RestraintView
}
