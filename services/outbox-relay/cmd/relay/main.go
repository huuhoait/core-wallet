// Command relay is the outbox-relay composition root. It loads config, builds the
// adapters (postgres repo, kafka producer/consumer, debezium connector, metrics,
// ops server), wires them into the usecase services, and runs the selected relay
// mode until SIGINT/SIGTERM.
//
//	config → logger → metrics → ops server
//	                          ├─ polling: repo + producer → usecase.PollingRelay
//	                          └─ cdc:     repo + connector + consumer → usecase.CDCStatusUpdater
package main

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/joho/godotenv"

	"github.com/ewallet-pg/shared/pgxdb"
	"github.com/huuhoait/core-wallet/outbox-relay/internal/config"
	"github.com/huuhoait/core-wallet/outbox-relay/internal/debezium"
	"github.com/huuhoait/core-wallet/outbox-relay/internal/kafka"
	"github.com/huuhoait/core-wallet/outbox-relay/internal/metrics"
	"github.com/huuhoait/core-wallet/outbox-relay/internal/ops"
	"github.com/huuhoait/core-wallet/outbox-relay/internal/repo"
	"github.com/huuhoait/core-wallet/outbox-relay/internal/telemetry"
	"github.com/huuhoait/core-wallet/outbox-relay/internal/usecase"
)

func main() {
	if err := godotenv.Load(); err != nil {
		fmt.Printf("Warning: failed to load .env file: %v\n", err)
	}

	logger := initLogger()

	cfg, err := config.LoadConfig()
	if err != nil {
		fatal(logger, "Failed to load configuration", err)
	}

	logger.Info("Configuration loaded",
		slog.String("mode", string(cfg.Mode)),
		slog.String("db_host", cfg.DBHost),
		slog.Any("kafka_brokers", cfg.KafkaBrokers))

	m := metrics.New()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// OpenTelemetry: install the propagator + tracer provider so the producer can
	// continue the trace the posting SP stamped into each outbox row. No-op (and
	// no collector needed) when OTEL_ENABLED=false.
	shutdownOtel, err := telemetry.Setup(ctx, cfg.Otel, cfg.Env)
	if err != nil {
		fatal(logger, "Failed to initialize OpenTelemetry", err)
	}
	defer func() {
		shCtx, cancelSh := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancelSh()
		_ = shutdownOtel(shCtx)
	}()
	logger.Info("OpenTelemetry initialized",
		slog.Bool("enabled", cfg.Otel.Enabled),
		slog.String("endpoint", cfg.Otel.Endpoint))

	// Operational HTTP endpoints (metrics/health/config).
	go startOpsServer(cfg, m, logger)

	switch cfg.Mode {
	case config.ModePolling:
		runPolling(ctx, cancel, cfg, m, logger)
	case config.ModeCDC:
		runCDC(ctx, cancel, cfg, m, logger)
	default:
		logger.Error("Unknown relay mode", slog.String("mode", string(cfg.Mode)))
		os.Exit(1)
	}
}

// runPolling wires and runs the Go-worker polling relay.
func runPolling(ctx context.Context, cancel context.CancelFunc, cfg *config.Config, m *metrics.Metrics, logger *slog.Logger) {
	logger.Info("Starting in POLLING mode", slog.Int("workers", cfg.WorkerCount))

	outboxRepo, err := repo.New(ctx, poolConfig(cfg), cfg.DBName, cfg.DBHost, logger)
	if err != nil {
		fatal(logger, "Failed to initialize repository", err)
	}
	defer outboxRepo.Close()

	producer, err := kafka.NewSyncProducer(cfg.KafkaBrokers, cfg.MaxRetries, logger)
	if err != nil {
		fatal(logger, "Failed to initialize Kafka producer", err)
	}
	defer func() { _ = producer.Close() }()

	relay := usecase.NewPollingRelay(outboxRepo, producer, m, usecase.PollingSettings{
		WorkerCount:  cfg.WorkerCount,
		BatchSize:    cfg.BatchSize,
		MaxRetries:   cfg.MaxRetries,
		PollInterval: cfg.PollInterval,
	}, logger)
	relay.Start(ctx)

	waitForSignal(cancel, relay.Stop, logger)
}

// runCDC wires and runs the Debezium CDC relay: it ensures the connector, starts
// the CDC consumer that marks rows SENT, and monitors connector health.
func runCDC(ctx context.Context, cancel context.CancelFunc, cfg *config.Config, m *metrics.Metrics, logger *slog.Logger) {
	logger.Info("Starting in CDC mode (Debezium)",
		slog.String("connect_url", cfg.CDC.ConnectURL),
		slog.String("connector", cfg.CDC.ConnectorName),
		slog.String("cdc_topic", cfg.CDC.CDCTopic),
		slog.Bool("auto_register", cfg.CDC.AutoRegister))

	outboxRepo, err := repo.New(ctx, poolConfig(cfg), cfg.DBName, cfg.DBHost, logger)
	if err != nil {
		fatal(logger, "CDC: failed to initialize repository", err)
	}
	defer outboxRepo.Close()

	connMgr := debezium.NewConnectorManager(debeziumSettings(cfg), logger)
	if err := connMgr.Ensure(ctx); err != nil {
		fatal(logger, "CDC: failed to ensure Debezium connector", err)
	}

	updater := usecase.NewCDCStatusUpdater(outboxRepo)
	consumer, err := kafka.NewCDCConsumer(cfg.KafkaBrokers, cfg.CDC.ConsumerGroup, cfg.CDC.CDCTopic, updater, m, logger)
	if err != nil {
		fatal(logger, "CDC: failed to create consumer", err)
	}
	consumer.Start(ctx)

	go monitorConnector(ctx, connMgr, logger)

	waitForSignal(cancel, func() {
		consumer.Stop()
		// Pause (not delete) the connector on graceful shutdown so it resumes
		// cleanly next time.
		_ = connMgr.Pause(context.Background())
	}, logger)
}

// monitorConnector periodically checks the Debezium connector health, resuming
// it if it has paused.
func monitorConnector(ctx context.Context, mgr usecase.ConnectorController, logger *slog.Logger) {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			status, err := mgr.Status(ctx)
			if err != nil {
				logger.Warn("CDC: connector health check failed", slog.Any("error", err))
				continue
			}
			if status != "RUNNING" {
				logger.Warn("CDC: connector not running", slog.String("status", status))
				if status == "PAUSED" {
					_ = mgr.Resume(ctx)
				}
			}
		}
	}
}

// poolConfig projects the relay config onto the shared pgxdb pool builder,
// giving the relay the same PgBouncer-safe, OTel-traced, timeout-bounded pool
// the wallet API uses.
func poolConfig(cfg *config.Config) pgxdb.Config {
	return pgxdb.Config{
		DSN:              cfg.DSN(),
		ApplicationName:  "outbox-relay",
		MaxConns:         cfg.DBMaxConns,
		MinConns:         cfg.DBMinConns,
		MaxConnLifetime:  cfg.DBMaxConnLifetime,
		MaxConnIdleTime:  cfg.DBMaxConnIdleTime,
		ConnectTimeout:   cfg.DBConnectTimeout,
		StatementTimeout: cfg.DBStatementTimeout,
		LockTimeout:      cfg.DBLockTimeout,
	}
}

// debeziumSettings projects the relay config onto the connector adapter's settings.
func debeziumSettings(cfg *config.Config) debezium.Settings {
	return debezium.Settings{
		ConnectURL:          cfg.CDC.ConnectURL,
		ConnectorName:       cfg.CDC.ConnectorName,
		AutoRegister:        cfg.CDC.AutoRegister,
		ConnectorConfigPath: cfg.CDC.ConnectorConfigPath,
		SlotName:            cfg.CDC.SlotName,
		PublicationName:     cfg.CDC.PublicationName,
		DBHost:              cfg.DBHost,
		DBPort:              cfg.DBPort,
		DBUser:              cfg.DBUser,
		DBPassword:          cfg.DBPassword,
		DBName:              cfg.DBName,
		TopicPrefix:         cfg.KafkaTopicPrefix,
	}
}

func startOpsServer(cfg *config.Config, m *metrics.Metrics, logger *slog.Logger) {
	srv := ops.New(cfg.MetricsPort, ops.Info{
		Mode:          string(cfg.Mode),
		KafkaBrokers:  cfg.KafkaBrokers,
		BatchSize:     cfg.BatchSize,
		WorkerCount:   cfg.WorkerCount,
		CDCEnabled:    cfg.Mode == config.ModeCDC,
		CDCConnectURL: cfg.CDC.ConnectURL,
		CDCConnector:  cfg.CDC.ConnectorName,
		CDCTopic:      cfg.CDC.CDCTopic,
	}, m, logger)
	if err := srv.ListenAndServe(); err != nil {
		fatal(logger, "Failed to start metrics server", err)
	}
}

// waitForSignal blocks until SIGINT/SIGTERM, then runs cleanup and cancels ctx.
func waitForSignal(cancel context.CancelFunc, cleanup func(), logger *slog.Logger) {
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	sig := <-sigChan
	logger.Info("Received shutdown signal", slog.String("signal", sig.String()))

	cleanup()
	cancel()
	logger.Info("Outbox relay service stopped")
}

// initLogger builds the JSON slog logger. The JSON handler stamps time + level;
// the service field tags every line. LOG_LEVEL (debug|info|warn|error) sets the
// threshold, defaulting to info.
func initLogger() *slog.Logger {
	h := slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: parseLevel(os.Getenv("LOG_LEVEL"))})
	return slog.New(h).With(slog.String("service", "outbox-relay"))
}

// parseLevel maps a LOG_LEVEL string to a slog.Level, defaulting to info for an
// empty or unrecognised value.
func parseLevel(s string) slog.Level {
	if s == "" {
		return slog.LevelInfo
	}
	var l slog.Level
	if err := l.UnmarshalText([]byte(s)); err != nil {
		return slog.LevelInfo
	}
	return l
}

// fatal logs at error level and exits non-zero (slog has no Fatal helper).
func fatal(logger *slog.Logger, msg string, err error) {
	logger.Error(msg, slog.Any("error", err))
	os.Exit(1)
}
