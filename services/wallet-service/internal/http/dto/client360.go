package dto

import (
	"time"

	"github.com/ewallet-pg/wallet-service/internal/domain"
)

// ----- unmasked client list (GET /v1/ops/clients) ---------------------------

// ClientFullListResponse — keyset-paginated list of UNMASKED client profiles.
type ClientFullListResponse struct {
	PageSize   int                  `json:"page_size"`
	Items      []ClientFullResponse `json:"items"`
	Count      int                  `json:"count"`
	NextCursor *string              `json:"next_cursor,omitempty"` // pass as ?after= for the next page
}

func ClientFullListRespFrom(q domain.ClientListQuery, views []domain.ClientFullView) ClientFullListResponse {
	items := make([]ClientFullResponse, 0, len(views))
	for i := range views {
		items = append(items, ClientFullRespFrom(&views[i]))
	}
	out := ClientFullListResponse{PageSize: q.Limit, Items: items, Count: len(items)}
	if q.Limit > 0 && len(views) == q.Limit {
		last := views[len(views)-1].ClientNo
		out.NextCursor = &last
	}
	return out
}

// ----- client 360 (profile + accounts + banks + restraints) ------------------

// Client360Profile merges raw (unmasked path only) and masked identity fields.
type Client360Profile struct {
	ClientNo         string     `json:"client_no"`
	ClientType       *string    `json:"client_type,omitempty"`
	ClientName       string     `json:"client_name,omitempty"` // raw — unmasked path only
	ClientNameMasked string     `json:"client_name_masked,omitempty"`
	GlobalID         string     `json:"global_id,omitempty"` // raw — unmasked path only
	GlobalIDMasked   string     `json:"global_id_masked,omitempty"`
	GlobalIDType     *string    `json:"global_id_type,omitempty"`
	Phone            string     `json:"phone,omitempty"` // decrypted — unmasked path only
	PhoneMasked      string     `json:"phone_masked,omitempty"`
	Surname          *string    `json:"surname,omitempty"`
	GivenName        *string    `json:"given_name,omitempty"`
	Sex              *string    `json:"sex,omitempty"`
	BirthDate        *string    `json:"birth_date,omitempty"`
	Email            string     `json:"email,omitempty"` // decrypted — unmasked path only
	CountryCitizen   *string    `json:"country_citizen,omitempty"`
	CountryLoc       *string    `json:"country_loc,omitempty"`
	ResidentStatus   *string    `json:"resident_status,omitempty"`
	Status           string     `json:"status"`
	KycTier          *string    `json:"kyc_tier,omitempty"`
	KycStatus        *string    `json:"kyc_status,omitempty"`
	RiskLevel        *string    `json:"risk_level,omitempty"`
	VerifiedAt       *time.Time `json:"verified_at,omitempty"`
	RegisteredDate   *string    `json:"registered_date,omitempty"`
	CreatedAt        *time.Time `json:"created_at,omitempty"`
	UpdatedAt        *time.Time `json:"updated_at,omitempty"`
}

// Client360Account is the wallet summary in a 360 view (subset of AccountResponse).
type Client360Account struct {
	AcctNo           string     `json:"acct_no"`
	AcctType         string     `json:"acct_type"`
	Ccy              string     `json:"ccy"`
	AcctStatus       string     `json:"acct_status"`
	AcctRole         string     `json:"acct_role"`
	ActualBal        string     `json:"actual_bal"`
	AvailableBal     string     `json:"available_bal"`
	RestrainedAmt    string     `json:"restrained_amt"`
	PrevDayBal       string     `json:"prev_day_bal"`
	AcctOpenDate     string     `json:"acct_open_date"`
	LastTranDate     *time.Time `json:"last_tran_date,omitempty"`
	RestraintPresent string     `json:"restraint_present"`
	CrBlocked        string     `json:"cr_blocked"`
}

// Client360Bank is one linked bank. AcctNo is masked on the masked path,
// decrypted cleartext on the unmasked path.
type Client360Bank struct {
	LinkID         int64     `json:"link_id"`
	BankCode       string    `json:"bank_code"`
	BankName       *string   `json:"bank_name,omitempty"`
	AcctNo         string    `json:"acct_no,omitempty"`
	AcctHolderName *string   `json:"acct_holder_name,omitempty"`
	IsDefault      bool      `json:"is_default"`
	Status         string    `json:"status"`
	CreatedAt      time.Time `json:"created_at"`
}

// Client360Response is the aggregate customer view returned under `data`.
type Client360Response struct {
	Profile    Client360Profile        `json:"profile"`
	Accounts   []Client360Account      `json:"accounts"`
	Banks      []Client360Bank         `json:"banks"`
	Restraints []RestraintViewResponse `json:"restraints"`
}

func Client360RespFrom(v *domain.Client360) Client360Response {
	out := Client360Response{
		Accounts:   make([]Client360Account, 0, len(v.Accounts)),
		Banks:      make([]Client360Bank, 0, len(v.Banks)),
		Restraints: make([]RestraintViewResponse, 0, len(v.Restraints)),
	}

	if v.Full != nil {
		f := v.Full
		p := Client360Profile{
			ClientNo: f.ClientNo, ClientType: f.ClientType,
			ClientName: f.ClientName, ClientNameMasked: maskName(f.ClientName),
			GlobalIDType: f.GlobalIDType,
			Surname:      f.Surname, GivenName: f.GivenName, Sex: f.Sex,
			BirthDate:      datePtr(f.BirthDate),
			CountryCitizen: f.CountryCitizen, CountryLoc: f.CountryLoc,
			ResidentStatus: f.ResidentStatus, Status: f.Status,
			KycTier: f.KycTier, KycStatus: f.KycStatus, RiskLevel: f.RiskLevel,
			VerifiedAt:     f.VerifiedAt,
			RegisteredDate: datePtr(f.RegisteredDate),
			CreatedAt:      &f.CreatedAt, UpdatedAt: &f.UpdatedAt,
		}
		if f.GlobalID != nil {
			p.GlobalID = *f.GlobalID
			p.GlobalIDMasked = maskGlobalID(*f.GlobalID)
		}
		if f.Phone != nil {
			p.Phone = *f.Phone
			p.PhoneMasked = maskPhone(*f.Phone)
		}
		if f.Email != nil {
			p.Email = *f.Email
		}
		out.Profile = p
	} else if v.Masked != nil {
		m := v.Masked
		p := Client360Profile{
			ClientNo: m.ClientNo, ClientType: m.ClientType,
			ClientNameMasked: m.ClientNameMasked, GlobalIDType: m.GlobalIDType,
			Sex: m.Sex, BirthDate: datePtr(m.BirthDate),
			CountryCitizen: m.CountryCitizen, CountryLoc: m.CountryLoc,
			ResidentStatus: m.ResidentStatus, Status: m.Status,
			KycTier: m.KycTier, KycStatus: m.KycStatus, RiskLevel: m.RiskLevel,
			VerifiedAt: m.VerifiedAt,
		}
		if m.GlobalIDMasked != nil {
			p.GlobalIDMasked = *m.GlobalIDMasked
		}
		if m.PhoneMasked != nil {
			p.PhoneMasked = *m.PhoneMasked
		}
		out.Profile = p
	}

	for i := range v.Accounts {
		a := &v.Accounts[i]
		out.Accounts = append(out.Accounts, Client360Account{
			AcctNo: a.AcctNo, AcctType: a.AcctType, Ccy: a.Ccy, AcctStatus: a.AcctStatus,
			AcctRole: a.AcctRole, ActualBal: a.ActualBal, AvailableBal: a.CalcBal,
			RestrainedAmt: a.RestrainedAmt, PrevDayBal: a.PrevDayBal,
			AcctOpenDate: a.AcctOpenDate.Format("2006-01-02"), LastTranDate: a.LastTranDate,
			RestraintPresent: a.RestraintPresent, CrBlocked: a.CrBlocked,
		})
	}
	for i := range v.Banks {
		b := &v.Banks[i]
		out.Banks = append(out.Banks, Client360Bank{
			LinkID: b.LinkID, BankCode: b.BankCode, BankName: b.BankName, AcctNo: b.AcctNo,
			AcctHolderName: b.AcctHolderName, IsDefault: b.IsDefault, Status: b.Status, CreatedAt: b.CreatedAt,
		})
	}
	for i := range v.Restraints {
		out.Restraints = append(out.Restraints, restraintViewResp(v.Restraints[i]))
	}
	return out
}

// ----- masking helpers (match v_client_masked derivation) --------------------

// maskName: first + "***" + last (regexp '(^.).*(.$)' → '\1***\2').
func maskName(s string) string {
	r := []rune(s)
	switch {
	case len(r) >= 2:
		return string(r[0]) + "***" + string(r[len(r)-1])
	case len(r) == 1:
		return string(r[0])
	default:
		return ""
	}
}

// maskGlobalID: "****" + last 4 chars.
func maskGlobalID(s string) string {
	if s == "" {
		return ""
	}
	return "****" + lastN(s, 4)
}

// maskPhone: "09xxxxx" + last 3 digits (e.g. 0901234567 → 09xxxxx567).
func maskPhone(s string) string {
	if s == "" {
		return ""
	}
	return "09xxxxx" + lastN(s, 3)
}

func lastN(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return string(r)
	}
	return string(r[len(r)-n:])
}
