// Package db builds a pgxpool wired with OpenTelemetry tracing and
// PgBouncer-safe defaults. The pool construction itself lives in the shared
// github.com/ewallet-pg/pgxdb module (used by both this service and the outbox
// relay); this package just maps the service's config.DB onto pgxdb.Config.
package db

import (
	"context"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/ewallet-pg/shared/pgxdb"
	"github.com/ewallet-pg/wallet-service/internal/config"
)

// NewPool builds a pgxpool via the shared builder:
//   - otelpgx Tracer for span instrumentation on every Query/Exec
//   - simple_protocol query mode (PgBouncer transaction-mode safe)
//   - per-session statement_timeout / lock_timeout from config
//   - application_name = wallet-service so PgBouncer + PG logs can attribute traffic
func NewPool(ctx context.Context, cfg config.DB) (*pgxpool.Pool, error) {
	return pgxdb.Open(ctx, pgxdb.Config{
		DSN:              cfg.DSN,
		ApplicationName:  "wallet-service",
		MaxConns:         cfg.MaxConns,
		MinConns:         cfg.MinConns,
		MaxConnLifetime:  cfg.MaxConnLifetime,
		MaxConnIdleTime:  cfg.MaxConnIdleTime,
		ConnectTimeout:   cfg.ConnectTimeout,
		StatementTimeout: cfg.StatementTimeout,
		LockTimeout:      cfg.LockTimeout,
	})
}
