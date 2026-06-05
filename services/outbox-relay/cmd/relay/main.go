package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/joho/godotenv"
	"github.com/rs/zerolog"

	"github.com/huuhoait/core-wallet/outbox-relay/internal/cdc"
	"github.com/huuhoait/core-wallet/outbox-relay/internal/config"
	"github.com/huuhoait/core-wallet/outbox-relay/internal/producer"
	"github.com/huuhoait/core-wallet/outbox-relay/internal/worker"
	"github.com/huuhoait/core-wallet/outbox-relay/pkg/utils"
)

func main() {
	if err := godotenv.Load(); err != nil {
		fmt.Printf("Warning: failed to load .env file: %v\n", err)
	}

	logger := initLogger()

	cfg, err := config.LoadConfig()
	if err != nil {
		logger.Fatal().Err(err).Msg("Failed to load configuration")
	}

	logger.Info().
		Str("mode", string(cfg.Mode)).
		Str("db_host", cfg.DBHost).
		Str("kafka_brokers", fmt.Sprintf("%v", cfg.KafkaBrokers)).
		Msg("Configuration loaded")

	metrics := utils.NewMetrics()

	ctx, cancel := context.WithCancel(context.Background())

	// Start metrics + health server
	go startMetricsServer(cfg.MetricsPort, cfg, metrics, logger)

	// ── Route to the configured relay mode ──
	switch cfg.Mode {
	case config.ModePolling:
		runPollingMode(ctx, cancel, cfg, logger, metrics)
	case config.ModeCDC:
		runCDCMode(ctx, cancel, cfg, logger, metrics)
	default:
		logger.Fatal().Str("mode", string(cfg.Mode)).Msg("Unknown relay mode")
	}
}

// runPollingMode is the original Go-worker polling approach.
func runPollingMode(ctx context.Context, cancel context.CancelFunc, cfg *config.Config, logger *zerolog.Logger, metrics *utils.Metrics) {
	logger.Info().Int("workers", cfg.WorkerCount).Msg("Starting in POLLING mode")

	repo, err := worker.NewRepository(ctx, cfg, logger)
	if err != nil {
		logger.Fatal().Err(err).Msg("Failed to initialize repository")
	}
	defer repo.Close()

	kafkaProducer, err := producer.NewProducer(cfg, logger)
	if err != nil {
		logger.Fatal().Err(err).Msg("Failed to initialize Kafka producer")
	}
	defer kafkaProducer.Close()

	w := worker.NewWorker(repo, kafkaProducer, cfg, logger, metrics)
	w.Start(ctx)

	// Wait for shutdown
	waitForSignal(cancel, func() { w.Stop() }, logger)
}

// runCDCMode uses Debezium CDC to capture changes from WLT_OUTBOX and route them
// to destination topics. The Go service manages the connector lifecycle and
// consumes the CDC topic to update outbox status.
func runCDCMode(ctx context.Context, cancel context.CancelFunc, cfg *config.Config, logger *zerolog.Logger, metrics *utils.Metrics) {
	logger.Info().
		Str("connect_url", cfg.CDC.ConnectURL).
		Str("connector", cfg.CDC.ConnectorName).
		Str("cdc_topic", cfg.CDC.CDCTopic).
		Bool("auto_register", cfg.CDC.AutoRegister).
		Msg("Starting in CDC mode (Debezium)")

	// 1. Open a DB pool for marking rows SENT
	pool, err := pgxpool.New(ctx, cfg.DSN())
	if err != nil {
		logger.Fatal().Err(err).Msg("CDC: failed to open DB pool")
	}
	defer pool.Close()

	// 2. Manage the Debezium connector
	connMgr := cdc.NewConnectorManager(cfg, logger)
	if err := connMgr.EnsureConnector(ctx); err != nil {
		logger.Fatal().Err(err).Msg("CDC: failed to ensure Debezium connector")
	}

	// 3. Start the CDC consumer (marks rows SENT as Debezium publishes them)
	consumer, err := cdc.NewCDCConsumer(cfg, pool, logger, metrics)
	if err != nil {
		logger.Fatal().Err(err).Msg("CDC: failed to create consumer")
	}
	consumer.Start(ctx)

	// 4. Monitor connector health in background
	go monitorConnector(ctx, connMgr, logger)

	// Wait for shutdown
	waitForSignal(cancel, func() {
		consumer.Stop()
		// Optionally pause (not delete) the connector on graceful shutdown
		// so it resumes cleanly next time:
		_ = connMgr.Pause(context.Background())
	}, logger)
}

// monitorConnector periodically checks the Debezium connector health and logs warnings.
func monitorConnector(ctx context.Context, mgr *cdc.ConnectorManager, logger *zerolog.Logger) {
	ticker := NewSafeTicker(30 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			status, err := mgr.Status(ctx)
			if err != nil {
				logger.Warn().Err(err).Msg("CDC: connector health check failed")
				continue
			}
			if status != "RUNNING" {
				logger.Warn().Str("status", status).Msg("CDC: connector not running — attempting resume")
				if status == "PAUSED" {
					_ = mgr.Resume(ctx)
				}
			}
		}
	}
}

// waitForSignal blocks until SIGINT/SIGTERM, then calls cleanup and cancels ctx.
func waitForSignal(cancel context.CancelFunc, cleanup func(), logger *zerolog.Logger) {
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	sig := <-sigChan
	logger.Info().Str("signal", sig.String()).Msg("Received shutdown signal")

	cleanup()
	cancel()
	logger.Info().Msg("Outbox relay service stopped")
}

func initLogger() *zerolog.Logger {
	level, err := zerolog.ParseLevel(os.Getenv("LOG_LEVEL"))
	if err != nil {
		level = zerolog.InfoLevel
	}
	logger := zerolog.New(os.Stdout).Level(level).With().
		Timestamp().
		Str("service", "outbox-relay").
		Logger()
	return &logger
}

func startMetricsServer(port int, cfg *config.Config, metrics *utils.Metrics, logger *zerolog.Logger) {
	mux := http.NewServeMux()

	mux.HandleFunc("/metrics", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		stats := metrics.GetStats()
		if err := json.NewEncoder(w).Encode(stats); err != nil {
			http.Error(w, "Internal server error", http.StatusInternalServerError)
			return
		}
	})

	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		fmt.Fprintf(w, `{"status":"healthy","mode":"%s"}`, cfg.Mode)
	})

	mux.HandleFunc("/config", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		info := map[string]interface{}{
			"mode":          cfg.Mode,
			"kafka_brokers": cfg.KafkaBrokers,
			"batch_size":    cfg.BatchSize,
			"worker_count":  cfg.WorkerCount,
		}
		if cfg.Mode == config.ModeCDC {
			info["cdc_connect_url"] = cfg.CDC.ConnectURL
			info["cdc_connector"] = cfg.CDC.ConnectorName
			info["cdc_topic"] = cfg.CDC.CDCTopic
		}
		json.NewEncoder(w).Encode(info)
	})

	addr := fmt.Sprintf(":%d", port)
	logger.Info().Str("addr", addr).Msg("Starting metrics/health server")
	if err := http.ListenAndServe(addr, mux); err != nil {
		logger.Fatal().Err(err).Msg("Failed to start metrics server")
	}
}

// --- helpers ---

type safeTicker struct {
	C <-chan time.Time
	t *time.Ticker
}

func NewSafeTicker(d time.Duration) *safeTicker {
	t := time.NewTicker(d)
	return &safeTicker{C: t.C, t: t}
}

func (s *safeTicker) Stop() { s.t.Stop() }
