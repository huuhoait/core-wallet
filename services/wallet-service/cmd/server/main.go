// wallet-service/cmd/server is the binary entry point.
//
// It wires dependencies (config → otel → pgxpool → repo → usecase → http),
// then blocks on the HTTP server until SIGINT/SIGTERM.
package main

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/ewallet-pg/wallet-service/internal/config"
	"github.com/ewallet-pg/wallet-service/internal/db"
	"github.com/ewallet-pg/wallet-service/internal/eod"
	netHTTP "github.com/ewallet-pg/wallet-service/internal/http"
	"github.com/ewallet-pg/wallet-service/internal/repo"
	"github.com/ewallet-pg/wallet-service/internal/telemetry"
	"github.com/ewallet-pg/wallet-service/internal/usecase"
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	}))
	slog.SetDefault(logger)

	if err := run(logger); err != nil {
		logger.Error("startup failed", slog.Any("error", err))
		os.Exit(1)
	}
}

func run(logger *slog.Logger) error {
	rootCtx, stop := signal.NotifyContext(context.Background(),
		syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	// ---- config ------------------------------------------------------------
	cfg, err := config.Load()
	if err != nil {
		return fmt.Errorf("load config: %w", err)
	}
	logger.Info("config loaded",
		slog.String("env", cfg.Env),
		slog.String("http.addr", cfg.HTTP.Addr),
		slog.Bool("otel.enabled", cfg.Otel.Enabled))

	// ---- OpenTelemetry -----------------------------------------------------
	shutdownOtel, err := telemetry.Setup(rootCtx, cfg.Otel, cfg.HTTP.ServiceName, cfg.Env)
	if err != nil {
		return fmt.Errorf("otel setup: %w", err)
	}
	defer func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = shutdownOtel(ctx)
	}()

	// ---- PostgreSQL pool ---------------------------------------------------
	pool, err := db.NewPool(rootCtx, cfg.DB)
	if err != nil {
		return fmt.Errorf("db pool: %w", err)
	}
	defer pool.Close()
	logger.Info("db pool ready",
		slog.Int("max_conns", int(cfg.DB.MaxConns)),
		slog.Int("min_conns", int(cfg.DB.MinConns)))

	// ---- read pool (replica) for lag-tolerant reads ------------------------
	// Only the account/client-profile + statement-list reads use this (see repo).
	// Empty DB_READ_DSN → reuse the primary pool (no replica; strong consistency).
	readPool := pool
	if cfg.DB.ReadDSN != "" {
		readCfg := cfg.DB
		readCfg.DSN = cfg.DB.ReadDSN
		readPool, err = db.NewPool(rootCtx, readCfg)
		if err != nil {
			return fmt.Errorf("db read pool: %w", err)
		}
		defer readPool.Close()
		logger.Info("db read pool ready (replica)")
	} else {
		logger.Info("db read pool = primary (DB_READ_DSN unset)")
	}

	// ---- PII pool (wallet_pii_ro) for the unmasked client read -------------
	// Only GET /v1/ops/clients/:client_no uses this (see repo/client.go).
	// Empty DB_PII_DSN → reuse the primary pool (dev superuser sees raw PII; in
	// prod set a wallet_pii_ro DSN so wallet_app stays unable to read raw PII).
	piiPool := pool
	if cfg.DB.PIIDSN != "" {
		piiCfg := cfg.DB
		piiCfg.DSN = cfg.DB.PIIDSN
		piiPool, err = db.NewPool(rootCtx, piiCfg)
		if err != nil {
			return fmt.Errorf("db pii pool: %w", err)
		}
		defer piiPool.Close()
		logger.Info("db pii pool ready (wallet_pii_ro)")
	} else {
		logger.Info("db pii pool = primary (DB_PII_DSN unset)")
	}

	// ---- adapter → usecase → http -----------------------------------------
	walletRepo := repo.NewPgWalletRepo(pool, readPool, piiPool, cfg.DB.StatementTimeout, cfg.DB.LockTimeout, cfg.DB.TxMaxRetries)
	walletSvc := usecase.NewWalletService(walletRepo, logger)

	server, err := netHTTP.New(cfg.HTTP, walletSvc, logger)
	if err != nil {
		return fmt.Errorf("http server: %w", err)
	}

	// ---- end-of-day scheduler (opt-in; one replica) ------------------------
	// Runs on a SEPARATE direct pool as wallet_eod (bypassing PgBouncer) with
	// statement_timeout disabled — run_eod is a long, resumable batch that
	// COMMITs between chunks. Deferred in reverse order so the scheduler drains
	// (eodDone) before its pool closes.
	if cfg.EOD.Enabled {
		if cfg.EOD.DSN == "" {
			return fmt.Errorf("EOD_ENABLED=true but EOD_DSN is empty")
		}
		eodCfg := cfg.DB
		eodCfg.DSN = cfg.EOD.DSN
		eodCfg.MaxConns, eodCfg.MinConns = 2, 0
		eodCfg.StatementTimeout = 0 // batch: no OLTP statement cap
		eodCfg.LockTimeout = 0      // wait for locks rather than abort a chunk
		eodPool, err := db.NewPool(rootCtx, eodCfg)
		if err != nil {
			return fmt.Errorf("eod pool: %w", err)
		}
		defer eodPool.Close()

		// Two daily jobs on the same direct pool (modern-core split):
		//   customer EOD — run_eod for the PRIOR calendar day, overnight (RunAt)
		//   GL close     — run_gl_close for TODAY's accounting day, at the cutoff
		custEOD, err := eod.New(eodPool, "customer-eod", "run_eod", eod.PriorDay,
			cfg.EOD.RunAt, cfg.EOD.Timezone, cfg.EOD.RunTimeout, logger)
		if err != nil {
			return fmt.Errorf("eod scheduler: %w", err)
		}
		glClose, err := eod.New(eodPool, "gl-close", "run_gl_close", eod.CurrentDay,
			cfg.EOD.GLCutoff, cfg.EOD.Timezone, cfg.EOD.RunTimeout, logger)
		if err != nil {
			return fmt.Errorf("gl-close scheduler: %w", err)
		}
		eodDone := make(chan struct{})
		go func() { defer close(eodDone); _ = custEOD.Start(rootCtx) }()
		glDone := make(chan struct{})
		go func() { defer close(glDone); _ = glClose.Start(rootCtx) }()
		defer func() { <-eodDone; <-glDone }()
		logger.Info("eod schedulers enabled",
			slog.String("customer_eod_at", cfg.EOD.RunAt),
			slog.String("gl_close_at", cfg.EOD.GLCutoff),
			slog.String("tz", cfg.EOD.Timezone))
	} else {
		logger.Info("eod scheduler disabled (EOD_ENABLED unset)")
	}

	// ---- block until signal -----------------------------------------------
	if err := server.Start(rootCtx); err != nil {
		return fmt.Errorf("http: %w", err)
	}
	logger.Info("server stopped cleanly")
	return nil
}
