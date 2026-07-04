package janitor

import (
	"log/slog"
	"testing"
	"time"
)

func TestValidateRetention(t *testing.T) {
	cases := []struct {
		name       string
		interval   time.Duration
		apiDays    int
		outboxDays int
		batchSize  int
		timeout    time.Duration
		wantErr    bool
	}{
		{"all valid", 24 * time.Hour, 3, 7, 10000, time.Minute, false},
		{"zero interval", 0, 3, 7, 10000, time.Minute, true},
		{"zero batch", 24 * time.Hour, 3, 7, 0, time.Minute, true},
		{"zero timeout", 24 * time.Hour, 3, 7, 10000, 0, true},
		{"api days zero", 24 * time.Hour, 0, 7, 10000, time.Minute, true},
		{"api days negative", 24 * time.Hour, -1, 7, 10000, time.Minute, true},
		{"outbox days zero", 24 * time.Hour, 3, 0, 10000, time.Minute, true},
		{"outbox days negative", 24 * time.Hour, 3, -5, 10000, time.Minute, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := validateRetention(tc.interval, tc.apiDays, tc.outboxDays, tc.batchSize, tc.timeout)
			if (err != nil) != tc.wantErr {
				t.Fatalf("validateRetention err = %v, wantErr = %v", err, tc.wantErr)
			}
		})
	}
}

func TestNewRetention_NilPool(t *testing.T) {
	// Valid scalar args, but a nil pool must still be rejected.
	if _, err := NewRetention(nil, 24*time.Hour, 3, 7, 10000, time.Minute, slog.Default()); err == nil {
		t.Fatal("NewRetention(nil pool) = nil error, want error")
	}
}
