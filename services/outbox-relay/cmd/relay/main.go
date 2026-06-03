package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"os/signal"
	"syscall"

	"github.com/joho/godotenv"
	"github.com/rs/zerolog"

	"github.com/huuhoait/core-wallet/outbox-relay/internal/config"
	"github.com/huuhoait/core-wallet/outbox-relay/internal/producer"
	"github.com/huuhoait/core-wallet/outbox-relay/internal/worker"
	"github.com/huuhoait/core-wallet/outbox-relay/pkg/utils"
)

func main() {
	// Load environment variables
	if err := godotenv.Load(); err != nil {
		fmt.Printf("Warning: failed to load .env file: %v\n", err)
	}

	// Initialize logger
	logger := initLogger()

	// Load configuration
	cfg, err := config.LoadConfig()
	if err != nil {
		logger.Fatal().Err(err).Msg("Failed to load configuration")
	}

	logger.Info().
		Str("db_host", cfg.DBHost).
		Str("kafka_brokers", fmt.Sprintf("%v", cfg.KafkaBrokers)).
		Int("worker_count", cfg.WorkerCount).
		Msg("Configuration loaded")

	// Initialize metrics
	metrics := utils.NewMetrics()

	// Initialize repository
	repo, err := worker.NewRepository(context.Background(), cfg, logger)
	if err != nil {
		logger.Fatal().Err(err).Msg("Failed to initialize repository")
	}
	defer repo.Close()

	// Initialize Kafka producer
	kafkaProducer, err := producer.NewProducer(cfg, logger)
	if err != nil {
		logger.Fatal().Err(err).Msg("Failed to initialize Kafka producer")
	}
	defer kafkaProducer.Close()

	// Initialize worker
	w := worker.NewWorker(repo, kafkaProducer, cfg, logger, metrics)

	// Start metrics server
	go startMetricsServer(cfg.MetricsPort, metrics, logger)

	// Start worker
	ctx, cancel := context.WithCancel(context.Background())
	w.Start(ctx)

	// Handle graceful shutdown
	setupGracefulShutdown(cancel, w, logger)

	// Wait for shutdown signal
	<-ctx.Done()
	logger.Info().Msg("Outbox relay service stopped")
}

// initLogger initializes the logger
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

// startMetricsServer starts the HTTP metrics server
func startMetricsServer(port int, metrics *utils.Metrics, logger *zerolog.Logger) {
	mux := http.NewServeMux()

	mux.HandleFunc("/metrics", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		stats := metrics.GetStats()
		if err := json.NewEncoder(w).Encode(stats); err != nil {
			logger.Error().Err(err).Msg("Failed to encode metrics")
			http.Error(w, "Internal server error", http.StatusInternalServerError)
			return
		}
	})

	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		fmt.Fprintf(w, `{"status":"healthy"}`)
	})

	addr := fmt.Sprintf(":%d", port)
	logger.Info().Str("addr", addr).Msg("Starting metrics server")

	if err := http.ListenAndServe(addr, mux); err != nil {
		logger.Fatal().Err(err).Msg("Failed to start metrics server")
	}
}

// setupGracefulShutdown handles graceful shutdown
func setupGracefulShutdown(cancel context.CancelFunc, w *worker.Worker, logger *zerolog.Logger) {
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	go func() {
		sig := <-sigChan
		logger.Info().Str("signal", sig.String()).Msg("Received shutdown signal")

		// Stop worker gracefully
		w.Stop()

		// Cancel context
		cancel()
	}()
}