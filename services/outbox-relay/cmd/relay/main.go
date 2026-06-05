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
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/joho/godotenv"
	"github.com/rs/zerolog"

	"github.com/huuhoait/core-wallet/outbox-relay/internal/config"
	"github.com/huuhoait/core-wallet/outbox-relay/internal/debezium"
	"github.com/huuhoait/core-wallet/outbox-relay/internal/kafka"
	"github.com/huuhoait/core-wallet/outbox-relay/internal/metrics"
	"github.com/huuhoait/core-wallet/outbox-relay/internal/ops"
	"github.com/huuhoait/core-wallet/outbox-relay/internal/repo"
	"github.com/huuhoait/core-wallet/outbox-relay/internal/usecase"
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

	m := metrics.New()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Operational HTTP endpoints (metrics/health/config).
	go startOpsServer(cfg, m, logger)

	switch cfg.Mode {
	case config.ModePolling:
		runPolling(ctx, cancel, cfg, m, logger)
	case config.ModeCDC:
		runCDC(ctx, cancel, cfg, m, logger)
	default:
		logger.Fatal().Str("mode", string(cfg.Mode)).Msg("Unknown relay mode")
	}
}

// runPolling wires and runs the Go-worker polling relay.
func runPolling(ctx context.Context, cancel context.CancelFunc, cfg *config.Config, m *metrics.Metrics, logger *zerolog.Logger) {
	logger.Info().Int("workers", cfg.WorkerCount).Msg("Starting in POLLING mode")

	outboxRepo, err := repo.New(ctx, cfg.DSN(), cfg.DBName, cfg.DBHost, logger)
	if err != nil {
		logger.Fatal().Err(err).Msg("Failed to initialize repository")
	}
	defer outboxRepo.Close()

	producer, err := kafka.NewSyncProducer(cfg.KafkaBrokers, cfg.MaxRetries, logger)
	if err != nil {
		logger.Fatal().Err(err).Msg("Failed to initialize Kafka producer")
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
func runCDC(ctx context.Context, cancel context.CancelFunc, cfg *config.Config, m *metrics.Metrics, logger *zerolog.Logger) {
	logger.Info().
		Str("connect_url", cfg.CDC.ConnectURL).
		Str("connector", cfg.CDC.ConnectorName).
		Str("cdc_topic", cfg.CDC.CDCTopic).
		Bool("auto_register", cfg.CDC.AutoRegister).
		Msg("Starting in CDC mode (Debezium)")

	outboxRepo, err := repo.New(ctx, cfg.DSN(), cfg.DBName, cfg.DBHost, logger)
	if err != nil {
		logger.Fatal().Err(err).Msg("CDC: failed to initialize repository")
	}
	defer outboxRepo.Close()

	connMgr := debezium.NewConnectorManager(debeziumSettings(cfg), logger)
	if err := connMgr.Ensure(ctx); err != nil {
		logger.Fatal().Err(err).Msg("CDC: failed to ensure Debezium connector")
	}

	updater := usecase.NewCDCStatusUpdater(outboxRepo)
	consumer, err := kafka.NewCDCConsumer(cfg.KafkaBrokers, cfg.CDC.ConsumerGroup, cfg.CDC.CDCTopic, updater, m, logger)
	if err != nil {
		logger.Fatal().Err(err).Msg("CDC: failed to create consumer")
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
func monitorConnector(ctx context.Context, mgr usecase.ConnectorController, logger *zerolog.Logger) {
	ticker := time.NewTicker(30 * time.Second)
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
				logger.Warn().Str("status", status).Msg("CDC: connector not running")
				if status == "PAUSED" {
					_ = mgr.Resume(ctx)
				}
			}
		}
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

func startOpsServer(cfg *config.Config, m *metrics.Metrics, logger *zerolog.Logger) {
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
		logger.Fatal().Err(err).Msg("Failed to start metrics server")
	}
}

// waitForSignal blocks until SIGINT/SIGTERM, then runs cleanup and cancels ctx.
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
