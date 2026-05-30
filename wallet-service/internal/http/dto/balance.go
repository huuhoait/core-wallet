package dto

import (
	"encoding/json"
	"time"

	"github.com/ewallet-pg/wallet-service/internal/domain"
)

// ----- customer realtime balance (§9.3.1) -----------------------------------

type BalanceResponse struct {
	AcctNo        string     `json:"acct_no"`
	Ccy           string     `json:"ccy"`
	AcctStatus    string     `json:"acct_status"`
	ActualBal     *string    `json:"actual_bal,omitempty"`
	AvailableBal  *string    `json:"available_bal,omitempty"`
	RestrainedAmt *string    `json:"restrained_amt,omitempty"`
	Masked        bool       `json:"masked"`
	Message       string     `json:"message,omitempty"`
	LastTranDate  *time.Time `json:"last_tran_date,omitempty"`
	AsOf          time.Time  `json:"as_of"`
}

func BalanceRespFrom(b *domain.BalanceView) BalanceResponse {
	return BalanceResponse{
		AcctNo:        b.AcctNo,
		Ccy:           b.Ccy,
		AcctStatus:    b.AcctStatus,
		ActualBal:     b.ActualBal,
		AvailableBal:  b.AvailableBal,
		RestrainedAmt: b.RestrainedAmt,
		Masked:        b.Masked,
		Message:       b.Message,
		LastTranDate:  b.LastTranDate,
		AsOf:          b.AsOf,
	}
}

// ----- ops/internal full balance (§9.3.2) -----------------------------------

type BalanceOpsResponse struct {
	AcctNo           string          `json:"acct_no"`
	ClientNo         string          `json:"client_no"`
	Ccy              string          `json:"ccy"`
	AcctStatus       string          `json:"acct_status"`
	ActualBal        string          `json:"actual_bal"`
	LedgerBal        string          `json:"ledger_bal"`
	CalcBal          string          `json:"calc_bal"`
	AvailableBal     string          `json:"available_bal"`
	RestrainedAmt    string          `json:"restrained_amt"`
	RestraintPresent string          `json:"restraint_present"`
	CrBlocked        string          `json:"cr_blocked"`
	ActiveRestraints json.RawMessage `json:"active_restraints"`
	Version          int64           `json:"version"`
	PreviousDayBal   string          `json:"previous_day_bal"`
	LastTranDate     *time.Time      `json:"last_tran_date,omitempty"`
	AsOf             time.Time       `json:"as_of"`
}

func BalanceOpsRespFrom(b *domain.BalanceOpsView) BalanceOpsResponse {
	ar := b.ActiveRestraints
	if len(ar) == 0 {
		ar = json.RawMessage("[]")
	}
	return BalanceOpsResponse{
		AcctNo:           b.AcctNo,
		ClientNo:         b.ClientNo,
		Ccy:              b.Ccy,
		AcctStatus:       b.AcctStatus,
		ActualBal:        b.ActualBal,
		LedgerBal:        b.LedgerBal,
		CalcBal:          b.CalcBal,
		AvailableBal:     b.AvailableBal,
		RestrainedAmt:    b.RestrainedAmt,
		RestraintPresent: b.RestraintPresent,
		CrBlocked:        b.CrBlocked,
		ActiveRestraints: ar,
		Version:          b.Version,
		PreviousDayBal:   b.PreviousDayBal,
		LastTranDate:     b.LastTranDate,
		AsOf:             b.AsOf,
	}
}

// ----- historical balance (§9.3.3) ------------------------------------------

type BalanceAsOfResponse struct {
	AcctNo    string `json:"acct_no"`
	Ccy       string `json:"ccy"`
	ActualBal string `json:"actual_bal"`
	TranDate  string `json:"tran_date"`
	Source    string `json:"source"`
}

func BalanceAsOfRespFrom(b *domain.BalanceAsOf) BalanceAsOfResponse {
	return BalanceAsOfResponse{
		AcctNo:    b.AcctNo,
		Ccy:       b.Ccy,
		ActualBal: b.ActualBal,
		TranDate:  b.TranDate.Format("2006-01-02"),
		Source:    b.Source,
	}
}

// ----- batch balance (§9.3.4) -----------------------------------------------

type BalanceBatchRequest struct {
	AcctNos []string `json:"acct_nos" binding:"required,min=1,max=100,dive,acct_no"`
}

type BalanceBatchItem struct {
	AcctNo        string `json:"acct_no"`
	Ccy           string `json:"ccy,omitempty"`
	ActualBal     string `json:"actual_bal,omitempty"`
	AvailableBal  string `json:"available_bal,omitempty"`
	RestrainedAmt string `json:"restrained_amt,omitempty"`
	Error         string `json:"error,omitempty"`
}

type BalanceBatchResponse struct {
	Items []BalanceBatchItem `json:"items"`
	AsOf  time.Time          `json:"as_of"`
}

// BalanceBatchRespFrom builds the response, marking any requested acct that was
// not returned by the SP as ACCT_NOT_FOUND (§9.3.4 partial-result contract).
func BalanceBatchRespFrom(requested []string, found []domain.BalanceBatchItem, asOf time.Time) BalanceBatchResponse {
	byAcct := make(map[string]domain.BalanceBatchItem, len(found))
	for _, f := range found {
		byAcct[f.AcctNo] = f
	}
	items := make([]BalanceBatchItem, 0, len(requested))
	for _, a := range requested {
		if f, ok := byAcct[a]; ok {
			items = append(items, BalanceBatchItem{
				AcctNo:        f.AcctNo,
				Ccy:           f.Ccy,
				ActualBal:     f.ActualBal,
				AvailableBal:  f.AvailableBal,
				RestrainedAmt: f.RestrainedAmt,
			})
		} else {
			items = append(items, BalanceBatchItem{AcctNo: a, Error: domain.CodeAcctNotFound})
		}
	}
	return BalanceBatchResponse{Items: items, AsOf: asOf}
}
