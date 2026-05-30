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

	// ---- adapter → usecase → http -----------------------------------------
	walletRepo := repo.NewPgWalletRepo(pool, readPool, cfg.DB.StatementTimeout, cfg.DB.LockTimeout)
	walletSvc := usecase.NewWalletService(walletRepo, logger)

	server, err := netHTTP.New(cfg.HTTP, walletSvc, logger)
	if err != nil {
		return fmt.Errorf("http server: %w", err)
	}

	// ---- block until signal -----------------------------------------------
	if err := server.Start(rootCtx); err != nil {
		return fmt.Errorf("http: %w", err)
	}
	logger.Info("server stopped cleanly")
	return nil
}
