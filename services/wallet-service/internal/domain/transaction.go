package domain

import (
	"encoding/json"
	"time"
)

// TxEntry is one ledger entry (a single leg) on an account — i.e. one line of
// the account statement. Amounts are decimal strings (never float money).
type TxEntry struct {
	SeqNo          int64
	TranInternalID *int64 // transaction id grouping all legs; NULL on legacy rows
	TranType       string
	DRCR           string // 'DR' | 'CR'
	Amount         string
	Ccy            string
	BalanceAfter   string
	PostDate       time.Time
	ValueDate      time.Time
	Reference      string
	TranDesc       string // per-row transaction description (WLT_TRAN_HIST.tran_desc)
	Narrative      string
}

// TxLeg is one leg of a full transaction (detail view): includes the account it
// hit and the link back to the primary leg (TFRSeqNo).
type TxLeg struct {
	SeqNo        int64
	TFRSeqNo     *int64 // = primary leg's SeqNo; NULL on the primary leg itself
	InternalKey  int64
	AcctNo       string
	TranType     string
	DRCR         string
	Amount       string
	Ccy          string
	BalanceAfter string
	PostDate     time.Time
	ValueDate    time.Time
	Reference    string
	TranDesc     string          // per-leg transaction description (WLT_TRAN_HIST.tran_desc)
	Narrative    string
	Metadata     json.RawMessage // raw jsonb metadata (WLT_TRAN_HIST.metadata)
}

// TxListQuery parameterises an account statement query: filter by account +
// optional post_date range, keyset-paginated newest-first.
type TxListQuery struct {
	AcctNo    string
	Limit     int        // 1..MaxTxPageSize (clamped in usecase)
	BeforeSeq *int64     // cursor: return rows with seq_no < BeforeSeq (newest-first)
	From      *time.Time // optional: post_date >= From (inclusive)
	To        *time.Time // optional: post_date <= To (inclusive)
}

// Statement page sizing — a page returns up to 200 entries (default 200).
const (
	DefaultTxPageSize = 200
	MaxTxPageSize     = 200
)

// Account search sizing + the minimum query length (cheap-enumeration guard).
const (
	DefaultAccountSearchSize = 50
	MaxAccountSearchSize     = 200
	MinAccountSearchLen      = 6
)

// AccountSearchItem is one hit of an account search: the account number, its
// owning client, and the MASKED client name (no raw PII).
type AccountSearchItem struct {
	AcctNo   string
	ClientNo string
	Name     string // masked client name (client_name_masked)
}

// AccountView is the account profile (WLT_ACCT), excluding client PII.
type AccountView struct {
	AcctNo           string
	ClientNo         string
	AcctType         string
	Ccy              string
	AcctStatus       string
	AcctRole         string
	ActualBal        string
	RestrainedAmt    string
	CalcBal          string
	PrevDayBal       string
	AcctOpenDate     time.Time
	LastTranDate     *time.Time
	RestraintPresent string
	CrBlocked        string
	Version          int64
	GroupID          *string
	ShardIndex       *int16
}
