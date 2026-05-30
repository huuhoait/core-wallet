// Package db builds a pgxpool wired with OpenTelemetry tracing and
// PgBouncer-safe defaults.
package db

import (
	"context"
	"fmt"

	"github.com/exaring/otelpgx"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/ewallet-pg/wallet-service/internal/config"
)

// NewPool builds a pgxpool with:
//   - otelpgx Tracer for span instrumentation on every Query/Exec
//   - simple_protocol query mode (PgBouncer transaction-mode safe)
//   - per-session statement_timeout / lock_timeout from config
//   - app.application_name so PgBouncer + PG logs can attribute traffic
func NewPool(ctx context.Context, cfg config.DB) (*pgxpool.Pool, error) {
	pcfg, err := pgxpool.ParseConfig(cfg.DSN)
	if err != nil {
		return nil, fmt.Errorf("parse DSN: %w", err)
	}

	pcfg.MaxConns = cfg.MaxConns
	pcfg.MinConns = cfg.MinConns
	pcfg.MaxConnLifetime = cfg.MaxConnLifetime
	pcfg.MaxConnIdleTime = cfg.MaxConnIdleTime
	pcfg.ConnConfig.ConnectTimeout = cfg.ConnectTimeout

	// PgBouncer transaction mode requires simple protocol (or PgBouncer
	// 1.21+ with max_prepared_statements set, which we have at 200).
	// Simple protocol is the safest default for the wallet hot path.
	pcfg.ConnConfig.DefaultQueryExecMode = pgx.QueryExecModeSimpleProtocol

	// Per-session settings applied via the AfterConnect hook. SET (not
	// SET LOCAL) so the session keeps these for its lifetime.
	pcfg.AfterConnect = func(ctx context.Context, c *pgx.Conn) error {
		stmts := []string{
			fmt.Sprintf("SET statement_timeout = %d", cfg.StatementTimeout.Milliseconds()),
			fmt.Sprintf("SET lock_timeout      = %d", cfg.LockTimeout.Milliseconds()),
			"SET application_name = 'wallet-service'",
		}
		for _, s := range stmts {
			if _, err := c.Exec(ctx, s); err != nil {
				return fmt.Errorf("AfterConnect %q: %w", s, err)
			}
		}
		return nil
	}

	pcfg.ConnConfig.Tracer = otelpgx.NewTracer(
		otelpgx.WithIncludeQueryParameters(),
		otelpgx.WithTrimSQLInSpanName(),
	)

	pool, err := pgxpool.NewWithConfig(ctx, pcfg)
	if err != nil {
		return nil, fmt.Errorf("open pool: %w", err)
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("ping: %w", err)
	}
	return pool, nil
}
