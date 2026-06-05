// Package config loads the outbox-relay runtime configuration from the
// environment (see .env.example). Defaults mirror pkg/models.WorkerConfig.
package config

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

// RelayMode determines how events are relayed from WLT_OUTBOX to Kafka.
type RelayMode string

const (
	// ModePolling uses Go workers that poll WLT_OUTBOX (FOR UPDATE SKIP LOCKED).
	// Simple, no external dependencies beyond PG + Kafka.
	ModePolling RelayMode = "polling"

	// ModeCDC uses Debezium CDC via Kafka Connect. The relay service manages the
	// Debezium connector and consumes the CDC topic to mark rows SENT. Lower latency,
	// zero polling overhead, but requires Kafka Connect infrastructure.
	ModeCDC RelayMode = "cdc"
)

// Config holds all runtime settings for the relay.
type Config struct {
	// Relay mode: "polling" (default) or "cdc" (Debezium)
	Mode RelayMode

	// Database
	DBHost     string
	DBPort     int
	DBUser     string
	DBPassword string
	DBName     string

	// Kafka
	KafkaBrokers     []string
	KafkaTopicPrefix string

	// Worker (polling mode)
	PollInterval time.Duration
	BatchSize    int
	MaxRetries   int
	RetryDelay   time.Duration
	WorkerCount  int

	// CDC mode (Debezium)
	CDC CDCConfig

	// Monitoring
	MetricsPort int

	// Logging
	LogLevel string
}

// CDCConfig holds Debezium / Kafka Connect settings (used when Mode == ModeCDC).
type CDCConfig struct {
	// Kafka Connect REST endpoint (e.g. http://kafka-connect:8083)
	ConnectURL string
	// Connector name in Kafka Connect
	ConnectorName string
	// CDC topic that Debezium writes to (default: wallet.public.wlt_outbox)
	CDCTopic string
	// Consumer group for the CDC topic consumer
	ConsumerGroup string
	// Slot name for PG logical replication
	SlotName string
	// Publication name for PG logical replication
	PublicationName string
	// Whether to auto-register the Debezium connector on startup
	AutoRegister bool
	// Path to custom connector config JSON (overrides built-in defaults)
	ConnectorConfigPath string
}

// LoadConfig reads configuration from environment variables, applying the
// documented defaults for any that are unset. A set-but-unparseable value is a
// hard error (fail fast) rather than a silent fallback to the default.
func LoadConfig() (*Config, error) {
	c := &Config{
		Mode:             RelayMode(getEnv("RELAY_MODE", "polling")),
		DBHost:           getEnv("DB_HOST", "localhost"),
		DBUser:           getEnv("DB_USER", "wallet_app"),
		DBPassword:       getEnv("DB_PASSWORD", ""),
		DBName:           getEnv("DB_NAME", "wallet"),
		KafkaBrokers:     splitCSV(getEnv("KAFKA_BROKERS", "localhost:9092")),
		KafkaTopicPrefix: getEnv("KAFKA_TOPIC_PREFIX", "wallet"),
		LogLevel:         getEnv("LOG_LEVEL", "info"),
		CDC: CDCConfig{
			ConnectURL:          getEnv("CDC_CONNECT_URL", "http://kafka-connect:8083"),
			ConnectorName:       getEnv("CDC_CONNECTOR_NAME", "wallet-outbox-connector"),
			CDCTopic:            getEnv("CDC_TOPIC", "wallet.public.wlt_outbox"),
			ConsumerGroup:       getEnv("CDC_CONSUMER_GROUP", "outbox-relay-cdc"),
			SlotName:            getEnv("CDC_SLOT_NAME", "wallet_outbox_slot"),
			PublicationName:     getEnv("CDC_PUBLICATION_NAME", "wallet_outbox_publication"),
			AutoRegister:        getEnv("CDC_AUTO_REGISTER", "true") == "true",
			ConnectorConfigPath: getEnv("CDC_CONNECTOR_CONFIG", ""),
		},
	}

	// Validate relay mode
	if c.Mode != ModePolling && c.Mode != ModeCDC {
		return nil, fmt.Errorf("config: RELAY_MODE=%q is invalid; must be 'polling' or 'cdc'", c.Mode)
	}

	var err error
	if c.DBPort, err = getEnvInt("DB_PORT", 5432); err != nil {
		return nil, err
	}
	if c.BatchSize, err = getEnvInt("BATCH_SIZE", 100); err != nil {
		return nil, err
	}
	if c.MaxRetries, err = getEnvInt("MAX_RETRIES", 3); err != nil {
		return nil, err
	}
	if c.WorkerCount, err = getEnvInt("WORKER_COUNT", 4); err != nil {
		return nil, err
	}
	if c.MetricsPort, err = getEnvInt("METRICS_PORT", 9090); err != nil {
		return nil, err
	}
	if c.PollInterval, err = getEnvDuration("POLL_INTERVAL", time.Second); err != nil {
		return nil, err
	}
	if c.RetryDelay, err = getEnvDuration("RETRY_DELAY", 5*time.Second); err != nil {
		return nil, err
	}

	if len(c.KafkaBrokers) == 0 {
		return nil, fmt.Errorf("config: KAFKA_BROKERS must not be empty")
	}
	if c.Mode == ModePolling && c.WorkerCount < 1 {
		return nil, fmt.Errorf("config: WORKER_COUNT must be >= 1, got %d", c.WorkerCount)
	}
	if c.BatchSize < 1 {
		return nil, fmt.Errorf("config: BATCH_SIZE must be >= 1, got %d", c.BatchSize)
	}
	return c, nil
}

// DSN builds the PostgreSQL connection string for pgx. sslmode=disable matches
// the local/test stack (docker-compose.test.yml); override DB_* for TLS targets.
func (c *Config) DSN() string {
	return fmt.Sprintf("postgres://%s:%s@%s:%d/%s?sslmode=disable",
		c.DBUser, c.DBPassword, c.DBHost, c.DBPort, c.DBName)
}

func getEnv(key, def string) string {
	if v, ok := os.LookupEnv(key); ok && v != "" {
		return v
	}
	return def
}

func getEnvInt(key string, def int) (int, error) {
	v, ok := os.LookupEnv(key)
	if !ok || v == "" {
		return def, nil
	}
	n, err := strconv.Atoi(strings.TrimSpace(v))
	if err != nil {
		return 0, fmt.Errorf("config: %s=%q is not an integer: %w", key, v, err)
	}
	return n, nil
}

func getEnvDuration(key string, def time.Duration) (time.Duration, error) {
	v, ok := os.LookupEnv(key)
	if !ok || v == "" {
		return def, nil
	}
	d, err := time.ParseDuration(strings.TrimSpace(v))
	if err != nil {
		return 0, fmt.Errorf("config: %s=%q is not a duration: %w", key, v, err)
	}
	return d, nil
}

func splitCSV(v string) []string {
	parts := strings.Split(v, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}
