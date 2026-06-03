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

// Config holds all runtime settings for the relay.
type Config struct {
	// Database
	DBHost     string
	DBPort     int
	DBUser     string
	DBPassword string
	DBName     string

	// Kafka
	KafkaBrokers     []string
	KafkaTopicPrefix string

	// Worker
	PollInterval time.Duration
	BatchSize    int
	MaxRetries   int
	RetryDelay   time.Duration
	WorkerCount  int

	// Monitoring
	MetricsPort int

	// Logging
	LogLevel string
}

// LoadConfig reads configuration from environment variables, applying the
// documented defaults for any that are unset. A set-but-unparseable value is a
// hard error (fail fast) rather than a silent fallback to the default.
func LoadConfig() (*Config, error) {
	c := &Config{
		DBHost:           getEnv("DB_HOST", "localhost"),
		DBUser:           getEnv("DB_USER", "wallet_app"),
		DBPassword:       getEnv("DB_PASSWORD", ""),
		DBName:           getEnv("DB_NAME", "wallet"),
		KafkaBrokers:     splitCSV(getEnv("KAFKA_BROKERS", "localhost:9092")),
		KafkaTopicPrefix: getEnv("KAFKA_TOPIC_PREFIX", "wallet"),
		LogLevel:         getEnv("LOG_LEVEL", "info"),
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
	if c.WorkerCount < 1 {
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
