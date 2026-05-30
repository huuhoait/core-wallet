package domain

import (
	"encoding/json"
	"time"
)

// BalanceView is the customer-facing realtime balance (get_balance SP, §9.3.1).
// Amount fields are decimal strings to avoid float money. When Masked is true
// (active AML_HOLD restraint, BAL-02) the amount pointers are nil and Message
// carries the customer-safe text.
type BalanceView struct {
	AcctNo        string
	Ccy           string
	AcctStatus    string
	ActualBal     *string
	AvailableBal  *string
	RestrainedAmt *string
	Masked        bool
	Message       string
	LastTranDate  *time.Time
	AsOf          time.Time
}

// BalanceOpsView is the ops/internal full view (get_balance_ops SP, §9.3.2).
type BalanceOpsView struct {
	AcctNo           string
	ClientNo         string
	Ccy              string
	AcctStatus       string
	ActualBal        string
	LedgerBal        string
	CalcBal          string
	AvailableBal     string
	RestrainedAmt    string
	RestraintPresent string
	CrBlocked        string
	ActiveRestraints json.RawMessage // jsonb array
	Version          int64
	PreviousDayBal   string
	LastTranDate     *time.Time
	AsOf             time.Time
}

// BalanceAsOf is a historical end-of-day snapshot (get_balance_asof SP, §9.3.3).
type BalanceAsOf struct {
	AcctNo    string
	Ccy       string
	ActualBal string
	TranDate  time.Time
	Source    string
}

// BalanceBatchItem is one row of a batch balance query (get_balance_batch, §9.3.4).
type BalanceBatchItem struct {
	AcctNo        string
	Ccy           string
	ActualBal     string
	AvailableBal  string
	RestrainedAmt string
}
