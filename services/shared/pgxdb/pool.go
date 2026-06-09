// Package pgxdb builds a pgxpool shared by the wallet services (the HTTP API
// and the outbox relay), which both connect to the same wallet database.
//
// The pool is wired with the defaults the wallet hot path needs:
//   - otelpgx Tracer so every Query/Exec emits a span (a no-op when the global
//     tracer provider is the no-op provider, i.e. OTEL disabled — so it's safe
//     to attach unconditionally).
//   - simple-protocol query mode, which is PgBouncer transaction-mode safe
//     (PgBouncer 1.21+ also needs max_prepared_statements set, which we run at
//     200) — the safest default when routed through PgBouncer.
//   - per-session statement_timeout / lock_timeout / application_name applied in
//     an AfterConnect hook (SET, not SET LOCAL, so they hold for the session).
//
// Provider/exporter setup stays per-service; this package only builds the pool.
package pgxdb

import (
	"context"
	"fmt"
	"time"

	"github.com/exaring/otelpgx"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Config is the connection + tuning surface for Open. A zero MaxConns/MinConns
// leaves pgx's own defaults in place; a zero StatementTimeout/LockTimeout SETs
// the corresponding PG timeout to 0 (disabled). DSN and ApplicationName should
// always be set.
type Config struct {
	DSN              string
	ApplicationName  string
	MaxConns         int32
	MinConns         int32
	MaxConnLifetime  time.Duration
	MaxConnIdleTime  time.Duration
	ConnectTimeout   time.Duration
	StatementTimeout time.Duration
	LockTimeout      time.Duration
}

// Open parses cfg.DSN, applies the tuning above, opens the pool and verifies it
// with a Ping (closing the pool if the Ping fails). The returned pool is ready
// for use; the caller owns Close.
func Open(ctx context.Context, cfg Config) (*pgxpool.Pool, error) {
	pcfg, err := pgxpool.ParseConfig(cfg.DSN)
	if err != nil {
		return nil, fmt.Errorf("pgxdb: parse DSN: %w", err)
	}

	if cfg.MaxConns > 0 {
		pcfg.MaxConns = cfg.MaxConns
	}
	if cfg.MinConns > 0 {
		pcfg.MinConns = cfg.MinConns
	}
	if cfg.MaxConnLifetime > 0 {
		pcfg.MaxConnLifetime = cfg.MaxConnLifetime
	}
	if cfg.MaxConnIdleTime > 0 {
		pcfg.MaxConnIdleTime = cfg.MaxConnIdleTime
	}
	if cfg.ConnectTimeout > 0 {
		pcfg.ConnConfig.ConnectTimeout = cfg.ConnectTimeout
	}

	// PgBouncer transaction mode requires simple protocol (or PgBouncer 1.21+
	// with max_prepared_statements set). Safest default for the wallet hot path.
	pcfg.ConnConfig.DefaultQueryExecMode = pgx.QueryExecModeSimpleProtocol

	appName := cfg.ApplicationName
	if appName == "" {
		appName = "pgxdb"
	}
	pcfg.AfterConnect = func(ctx context.Context, c *pgx.Conn) error {
		stmts := []string{
			fmt.Sprintf("SET statement_timeout = %d", cfg.StatementTimeout.Milliseconds()),
			fmt.Sprintf("SET lock_timeout      = %d", cfg.LockTimeout.Milliseconds()),
			fmt.Sprintf("SET application_name  = '%s'", appName),
		}
		for _, s := range stmts {
			if _, err := c.Exec(ctx, s); err != nil {
				return fmt.Errorf("pgxdb: AfterConnect %q: %w", s, err)
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
		return nil, fmt.Errorf("pgxdb: open pool: %w", err)
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("pgxdb: ping: %w", err)
	}
	return pool, nil
}
