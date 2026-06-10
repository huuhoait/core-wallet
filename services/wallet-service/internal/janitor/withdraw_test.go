package janitor

import (
	"log/slog"
	"testing"
	"time"
)

func TestValidateConfig(t *testing.T) {
	cases := []struct {
		name      string
		interval  time.Duration
		batchSize int
		timeout   time.Duration
		wantErr   bool
	}{
		{"all valid", time.Minute, 100, time.Minute, false},
		{"zero interval", 0, 100, time.Minute, true},
		{"negative interval", -time.Second, 100, time.Minute, true},
		{"zero batch", time.Minute, 0, time.Minute, true},
		{"negative batch", time.Minute, -1, time.Minute, true},
		{"zero timeout", time.Minute, 100, 0, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := validateConfig(tc.interval, tc.batchSize, tc.timeout)
			if (err != nil) != tc.wantErr {
				t.Fatalf("validateConfig err = %v, wantErr = %v", err, tc.wantErr)
			}
		})
	}
}

func TestNewWithdraw_NilPool(t *testing.T) {
	// Valid scalar args, but a nil pool must still be rejected.
	if _, err := NewWithdraw(nil, time.Minute, 100, time.Minute, slog.Default()); err == nil {
		t.Fatal("NewWithdraw(nil pool) = nil error, want error")
	}
}
