package domain

import "time"

// TxEntry is one ledger entry (a single leg) on an account — i.e. one line of
// the account statement. Amounts are decimal strings (never float money).
type TxEntry struct {
	SeqNo          int64
	TFRInternalKey *int64 // transaction id grouping all legs; NULL on legacy rows
	TranType       string
	DRCR           string // 'DR' | 'CR'
	Amount         string
	Ccy            string
	BalanceAfter   string
	PostDate       time.Time
	ValueDate      time.Time
	Reference      string
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
	Narrative    string
}

// TxListQuery parameterises an account statement query (keyset pagination).
type TxListQuery struct {
	AcctNo    string
	Limit     int    // 1..MaxTxPageSize (clamped in usecase)
	BeforeSeq *int64 // cursor: return rows with seq_no < BeforeSeq (newest-first)
}

// MaxTxPageSize bounds a single statement page.
const MaxTxPageSize = 100

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
