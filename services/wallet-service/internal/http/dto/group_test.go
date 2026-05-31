package dto

import (
	"testing"

	"github.com/go-playground/validator/v10"

	"github.com/ewallet-pg/wallet-service/internal/domain"
)

// bindValidate mirrors how gin validates request DTOs: go-playground/validator
// with the struct tag name "binding".
func bindValidate(s any) error {
	v := validator.New()
	v.SetTagName("binding")
	return v.Struct(s)
}

// TestActivateHotWalletRequest_ShardCount pins the oneof=4 8 16 rule: only the
// supported hot tiers pass, an omitted value (0) is allowed (handler defaults it
// to 4), and the retired tiers 1/32/64 are rejected.
func TestActivateHotWalletRequest_ShardCount(t *testing.T) {
	cases := []struct {
		name    string
		sc      int16
		wantErr bool
	}{
		{"omitted (0) → ok via omitempty", 0, false},
		{"4 → ok", 4, false},
		{"8 → ok", 8, false},
		{"16 → ok", 16, false},
		{"1 → rejected (cold, not a hot tier)", 1, true},
		{"5 → rejected", 5, true},
		{"32 → rejected (retired tier)", 32, true},
		{"64 → rejected (retired tier)", 64, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := bindValidate(ActivateHotWalletRequest{ShardCount: tc.sc})
			if (err != nil) != tc.wantErr {
				t.Errorf("ShardCount=%d: err=%v, wantErr=%v", tc.sc, err, tc.wantErr)
			}
		})
	}
}

// TestActivateHotWalletRespFrom copies every field, including the shard slice.
func TestActivateHotWalletRespFrom(t *testing.T) {
	r := ActivateHotWalletRespFrom(&domain.ActivateHotWalletResult{
		GroupID:          "GF01",
		ShardCount:       4,
		SettlementAcctNo: "97019000000001",
		ShardAcctNos:     []string{"9701000000001", "9701000000002", "9701000000003", "9701000000004"},
	})
	if r.GroupID != "GF01" || r.ShardCount != 4 || r.SettlementAcctNo != "97019000000001" {
		t.Errorf("scalar fields not copied: %+v", r)
	}
	if len(r.ShardAcctNos) != 4 || r.ShardAcctNos[0] != "9701000000001" {
		t.Errorf("shard_acct_nos not copied: %v", r.ShardAcctNos)
	}
}
