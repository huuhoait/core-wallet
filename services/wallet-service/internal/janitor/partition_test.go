package janitor

import (
	"log/slog"
	"testing"
	"time"
)

func TestValidatePartitionConfig(t *testing.T) {
	cases := []struct {
		name      string
		interval  time.Duration
		lookahead int
		timeout   time.Duration
		wantErr   bool
	}{
		{"all valid", 24 * time.Hour, 3, time.Minute, false},
		{"zero interval", 0, 3, time.Minute, true},
		{"negative interval", -time.Second, 3, time.Minute, true},
		{"zero lookahead", 24 * time.Hour, 0, time.Minute, true},
		{"negative lookahead", 24 * time.Hour, -1, time.Minute, true},
		{"zero timeout", 24 * time.Hour, 3, 0, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := validatePartitionConfig(tc.interval, tc.lookahead, tc.timeout)
			if (err != nil) != tc.wantErr {
				t.Fatalf("validatePartitionConfig err = %v, wantErr = %v", err, tc.wantErr)
			}
		})
	}
}

func TestNewPartition_NilPool(t *testing.T) {
	// Valid scalar args, but a nil pool must still be rejected.
	if _, err := NewPartition(nil, 24*time.Hour, 3, time.Minute, slog.Default()); err == nil {
		t.Fatal("NewPartition(nil pool) = nil error, want error")
	}
}
