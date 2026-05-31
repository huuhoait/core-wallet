package dto

import (
	"time"

	"github.com/ewallet-pg/wallet-service/internal/domain"
)

// ----- account profile ------------------------------------------------------

type AccountResponse struct {
	AcctNo           string     `json:"acct_no"`
	ClientNo         string     `json:"client_no"`
	AcctType         string     `json:"acct_type"`
	Ccy              string     `json:"ccy"`
	AcctStatus       string     `json:"acct_status"`
	AcctRole         string     `json:"acct_role"`
	ActualBal        string     `json:"actual_bal"`
	RestrainedAmt    string     `json:"restrained_amt"`
	AvailableBal     string     `json:"available_bal"` // calc_bal = actual - restrained
	PrevDayBal       string     `json:"prev_day_bal"`
	AcctOpenDate     string     `json:"acct_open_date"`
	LastTranDate     *time.Time `json:"last_tran_date,omitempty"`
	RestraintPresent string     `json:"restraint_present"`
	CrBlocked        string     `json:"cr_blocked"`
	Version          int64      `json:"version"`
	GroupID          *string    `json:"group_id,omitempty"`
	ShardIndex       *int16     `json:"shard_index,omitempty"`
}

func AccountRespFrom(a *domain.AccountView) AccountResponse {
	return AccountResponse{
		AcctNo: a.AcctNo, ClientNo: a.ClientNo, AcctType: a.AcctType, Ccy: a.Ccy,
		AcctStatus: a.AcctStatus, AcctRole: a.AcctRole,
		ActualBal: a.ActualBal, RestrainedAmt: a.RestrainedAmt, AvailableBal: a.CalcBal,
		PrevDayBal: a.PrevDayBal, AcctOpenDate: a.AcctOpenDate.Format("2006-01-02"),
		LastTranDate: a.LastTranDate, RestraintPresent: a.RestraintPresent,
		CrBlocked: a.CrBlocked, Version: a.Version,
		GroupID: a.GroupID, ShardIndex: a.ShardIndex,
	}
}

// ----- transaction list (account statement) --------------------------------

type TxEntryResponse struct {
	SeqNo         int64  `json:"seq_no"`
	TransactionID *int64 `json:"transaction_id,omitempty"` // = tfr_internal_key
	TranType      string `json:"tran_type"`
	DRCR          string `json:"dr_cr"`
	Amount        string `json:"amount"`
	Ccy           string `json:"ccy"`
	BalanceAfter  string `json:"balance_after"`
	PostDate      string `json:"post_date"`
	ValueDate     string `json:"value_date"`
	Reference     string `json:"reference"`
	Narrative     string `json:"narrative,omitempty"`
}

type TxListResponse struct {
	AcctNo     string            `json:"acct_no"`
	From       string            `json:"from,omitempty"`
	To         string            `json:"to,omitempty"`
	PageSize   int               `json:"page_size"`
	Items      []TxEntryResponse `json:"items"`
	Count      int               `json:"count"`
	NextCursor *int64            `json:"next_cursor,omitempty"` // pass as ?before_seq= for the next page
}

func TxListRespFrom(q domain.TxListQuery, entries []domain.TxEntry) TxListResponse {
	items := make([]TxEntryResponse, 0, len(entries))
	for _, e := range entries {
		items = append(items, TxEntryResponse{
			SeqNo: e.SeqNo, TransactionID: e.TranInternalID, TranType: e.TranType,
			DRCR: e.DRCR, Amount: e.Amount, Ccy: e.Ccy, BalanceAfter: e.BalanceAfter,
			PostDate: e.PostDate.Format("2006-01-02"), ValueDate: e.ValueDate.Format("2006-01-02"),
			Reference: e.Reference, Narrative: e.Narrative,
		})
	}
	out := TxListResponse{AcctNo: q.AcctNo, PageSize: q.Limit, Items: items, Count: len(items)}
	if q.From != nil {
		out.From = q.From.Format("2006-01-02")
	}
	if q.To != nil {
		out.To = q.To.Format("2006-01-02")
	}
	// A full page implies more rows may exist → expose the keyset cursor.
	if q.Limit > 0 && len(entries) == q.Limit {
		last := entries[len(entries)-1].SeqNo
		out.NextCursor = &last
	}
	return out
}

// ----- transaction detail (all legs of a transaction) ----------------------

type TxLegResponse struct {
	TFRSeqNo     *int64 `json:"tfr_seq_no,omitempty"`
	SeqNo        int64  `json:"seq_no"`
	AcctNo       string `json:"acct_no,omitempty"`
	TranType     string `json:"tran_type"`
	DRCR         string `json:"dr_cr"`
	Amount       string `json:"amount"`
	Ccy          string `json:"ccy"`
	BalanceAfter string `json:"balance_after"`
	PostDate     string `json:"post_date"`
	ValueDate    string `json:"value_date"`
	Reference    string `json:"reference"`
	Narrative    string `json:"narrative,omitempty"`
}

type TxDetailResponse struct {
	TransactionID int64           `json:"transaction_id"` // tfr_internal_key
	Reference     string          `json:"reference"`
	PostDate      string          `json:"post_date"`
	LegCount      int             `json:"leg_count"`
	Legs          []TxLegResponse `json:"legs"`
}

func TxDetailRespFrom(tfrKey int64, legs []domain.TxLeg) TxDetailResponse {
	out := TxDetailResponse{TransactionID: tfrKey, LegCount: len(legs)}
	out.Legs = make([]TxLegResponse, 0, len(legs))
	for i, l := range legs {
		if i == 0 {
			out.Reference = l.Reference
			out.PostDate = l.PostDate.Format("2006-01-02")
		}
		out.Legs = append(out.Legs, TxLegResponse{
			TFRSeqNo: l.TFRSeqNo, SeqNo: l.SeqNo, AcctNo: l.AcctNo, TranType: l.TranType,
			DRCR: l.DRCR, Amount: l.Amount, Ccy: l.Ccy, BalanceAfter: l.BalanceAfter,
			PostDate: l.PostDate.Format("2006-01-02"), ValueDate: l.ValueDate.Format("2006-01-02"),
			Reference: l.Reference, Narrative: l.Narrative,
		})
	}
	return out
}
