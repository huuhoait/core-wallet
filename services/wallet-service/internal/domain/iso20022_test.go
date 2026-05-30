package domain

import "testing"

func TestMetaFor_KnownCode(t *testing.T) {
	m := MetaFor(CodeInsufficientFunds)
	if m.ISOReason != "AM04" {
		t.Errorf("INSUFFICIENT_FUNDS: ISOReason = %q, want AM04", m.ISOReason)
	}
	if m.TxStatus != TxStatusRejected {
		t.Errorf("INSUFFICIENT_FUNDS: TxStatus = %q, want RJCT", m.TxStatus)
	}
	if m.InternalCode != "E4022" {
		t.Errorf("INSUFFICIENT_FUNDS: InternalCode = %q, want E4022", m.InternalCode)
	}
	if m.Title == "" {
		t.Error("INSUFFICIENT_FUNDS: Title is empty")
	}
}

func TestMetaFor_FamilyFallback(t *testing.T) {
	// SP raises prefixed variants like FROM_ACCT_NOT_FOUND / TO_ACCT_NOT_ACTIVE.
	cases := map[string]struct{ reason, tx string }{
		"FROM_ACCT_NOT_FOUND": {"AC01", TxStatusRejected},
		"TO_ACCT_NOT_ACTIVE":  {"AC04", TxStatusRejected},
	}
	for code, want := range cases {
		m := MetaFor(code)
		if m.ISOReason != want.reason || m.TxStatus != want.tx {
			t.Errorf("%s: got reason=%q tx=%q, want reason=%q tx=%q",
				code, m.ISOReason, m.TxStatus, want.reason, want.tx)
		}
	}
}

func TestMetaFor_Unknown(t *testing.T) {
	m := MetaFor("TOTALLY_UNKNOWN_CODE")
	if m.Title != "TOTALLY_UNKNOWN_CODE" {
		t.Errorf("unknown code Title = %q, want the code itself", m.Title)
	}
	if m.ISOReason != "" {
		t.Errorf("unknown code ISOReason = %q, want empty", m.ISOReason)
	}
}

func TestTxStatusForMark(t *testing.T) {
	cases := map[string]string{
		"ACKED":      TxStatusAcceptedTechnical,
		"DISBURSING": TxStatusInProcess,
		"COMPLETED":  TxStatusSettled,
		"OTHER":      "",
	}
	for status, want := range cases {
		if got := TxStatusForMark(status); got != want {
			t.Errorf("TxStatusForMark(%q) = %q, want %q", status, got, want)
		}
	}
}
