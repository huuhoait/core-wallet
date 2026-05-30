// Package config is the single source of truth for runtime configuration.
// All values come from environment variables and have safe defaults for dev.
package config

import (
	"fmt"
	"time"

	"github.com/caarlos0/env/v11"
)

type Config struct {
	HTTP HTTP
	DB   DB
	Otel Otel
	Env  string `env:"APP_ENV" envDefault:"dev"` // dev | staging | prod
}

type HTTP struct {
	Addr            string        `env:"HTTP_ADDR"             envDefault:":8080"`
	Mode            string        `env:"GIN_MODE"              envDefault:"release"` // release | debug | test
	ServiceName     string        `env:"OTEL_SERVICE_NAME"     envDefault:"wallet-service"`
	ReadTimeout     time.Duration `env:"HTTP_READ_TIMEOUT"     envDefault:"15s"`
	WriteTimeout    time.Duration `env:"HTTP_WRITE_TIMEOUT"    envDefault:"15s"`
	IdleTimeout     time.Duration `env:"HTTP_IDLE_TIMEOUT"     envDefault:"60s"`
	ShutdownTimeout time.Duration `env:"HTTP_SHUTDOWN_TIMEOUT" envDefault:"15s"`
	// RequestTimeout caps the duration of one business request (handler ctx).
	// Outer ring of the timeout stack: PG lock_timeout (1.5s) < statement_timeout
	// (2.5s) < this ctx deadline. Default 10s leaves slack for idempotency
	// gate FOR UPDATE waits + cold-pool acquire + PgBouncer queueing.
	RequestTimeout  time.Duration `env:"HTTP_REQUEST_TIMEOUT"  envDefault:"10s"`
}

type DB struct {
	// DSN typically points at PgBouncer (port 6432) in production.
	DSN             string        `env:"DB_DSN,required"     envExpand:"true"`
	// ReadDSN routes the lag-tolerant reads (account/client profile + statement
	// list) at a read replica. Empty → those reads use the primary DSN (no
	// replica; strong consistency). Balance-realtime/tx-detail/ops stay on DSN.
	ReadDSN         string        `env:"DB_READ_DSN"         envExpand:"true"`
	MaxConns        int32         `env:"DB_MAX_CONNS"        envDefault:"50"`
	MinConns        int32         `env:"DB_MIN_CONNS"        envDefault:"5"`
	MaxConnLifetime time.Duration `env:"DB_MAX_CONN_LIFETIME" envDefault:"30m"`
	MaxConnIdleTime time.Duration `env:"DB_MAX_CONN_IDLE"    envDefault:"5m"`
	ConnectTimeout  time.Duration `env:"DB_CONNECT_TIMEOUT"  envDefault:"5s"`
	StatementTimeout time.Duration `env:"DB_STATEMENT_TIMEOUT" envDefault:"2500ms"`
	LockTimeout     time.Duration `env:"DB_LOCK_TIMEOUT"     envDefault:"1500ms"`
	// TxMaxRetries is how many times a write that failed with a RETRYABLE
	// conflict (serialization_failure 40001 / deadlock 40P01) is re-run on a
	// fresh snapshot. Default 0 = NO retry: the conflict surfaces to the caller
	// as a retryable 409 (unchanged behaviour). Raise to 2-3 to absorb
	// hot-account contention server-side once the conflict rate is understood;
	// posting SPs are idempotent, so retries cannot double-post.
	TxMaxRetries    int           `env:"DB_TX_MAX_RETRIES"   envDefault:"0"`
}

type Otel struct {
	Enabled       bool   `env:"OTEL_ENABLED"        envDefault:"true"`
	Endpoint      string `env:"OTEL_EXPORTER_OTLP_ENDPOINT" envDefault:"otel-collector:4317"`
	Insecure      bool   `env:"OTEL_EXPORTER_OTLP_INSECURE" envDefault:"true"`
	SamplingRatio float64 `env:"OTEL_TRACES_SAMPLER_ARG"    envDefault:"1.0"`
}

// Load reads the env into Config. Required vars without defaults cause an error.
func Load() (*Config, error) {
	c := &Config{}
	if err := env.Parse(c); err != nil {
		return nil, fmt.Errorf("config: %w", err)
	}
	return c, nil
}
