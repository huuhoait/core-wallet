package config

import (
	"strings"
	"testing"
)

// TestLoadConfig_DBPoolBounds covers the DB_MAX_CONNS / DB_MIN_CONNS range
// validation guarding the int→int32 narrowing (CodeQL
// go/incorrect-integer-conversion). Every case sets both vars explicitly so the
// result is independent of the ambient environment; all other config fields
// have defaults, so LoadConfig reaches the pool-size check without more setup.
func TestLoadConfig_DBPoolBounds(t *testing.T) {
	tests := []struct {
		name             string
		maxConns         string
		minConns         string
		wantErr          string // "" → expect success
		wantMax, wantMin int32
	}{
		{name: "in range", maxConns: "100", minConns: "10", wantMax: 100, wantMin: 10},
		{name: "min may be zero", maxConns: "50", minConns: "0", wantMax: 50, wantMin: 0},
		{name: "max over MaxInt32", maxConns: "3000000000", minConns: "5", wantErr: "DB_MAX_CONNS out of range"},
		{name: "max below 1", maxConns: "0", minConns: "5", wantErr: "DB_MAX_CONNS out of range"},
		{name: "min negative", maxConns: "50", minConns: "-1", wantErr: "DB_MIN_CONNS out of range"},
		{name: "min over MaxInt32", maxConns: "50", minConns: "4000000000", wantErr: "DB_MIN_CONNS out of range"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Setenv("DB_MAX_CONNS", tt.maxConns)
			t.Setenv("DB_MIN_CONNS", tt.minConns)

			cfg, err := LoadConfig()
			if tt.wantErr != "" {
				if err == nil {
					t.Fatalf("expected error containing %q, got nil", tt.wantErr)
				}
				if !strings.Contains(err.Error(), tt.wantErr) {
					t.Errorf("error = %q, want it to contain %q", err.Error(), tt.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatalf("LoadConfig: unexpected error: %v", err)
			}
			if cfg.DBMaxConns != tt.wantMax {
				t.Errorf("DBMaxConns = %d, want %d", cfg.DBMaxConns, tt.wantMax)
			}
			if cfg.DBMinConns != tt.wantMin {
				t.Errorf("DBMinConns = %d, want %d", cfg.DBMinConns, tt.wantMin)
			}
		})
	}
}
