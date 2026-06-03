package models

import (
	"time"
)

// OutboxEvent represents a row from WLT_OUTBOX table
type OutboxEvent struct {
	ID          int64     `json:"id"`
	EventUUID   string    `json:"event_uuid"`
	EventType   string    `json:"event_type"`
	Payload     []byte    `json:"payload"`
	CreatedAt   time.Time `json:"created_at"`
	ProcessedAt *time.Time `json:"processed_at,omitempty"`
	RetryCount  int       `json:"retry_count"`
}

// KafkaMessage represents a message to be sent to Kafka
type KafkaMessage struct {
	Topic   string          `json:"topic"`
	Key     string          `json:"key"`
	Value   []byte          `json:"value"`
	Headers map[string]string `json:"headers"`
}

// WorkerConfig holds configuration for the outbox worker
type WorkerConfig struct {
	// Database
	DBHost     string `env:"DB_HOST" envDefault:"localhost"`
	DBPort     int    `env:"DB_PORT" envDefault:"5432"`
	DBUser     string `env:"DB_USER" envDefault:"wallet_app"`
	DBPassword string `env:"DB_PASSWORD" envDefault:""`
	DBName     string `env:"DB_NAME" envDefault:"wallet"`
	
	// Kafka
	KafkaBrokers []string `env:"KAFKA_BROKERS" envDefault:"localhost:9092"`
	KafkaTopic   string   `env:"KAFKA_TOPIC_PREFIX" envDefault:"wallet"`
	
	// Worker
	PollInterval   time.Duration `env:"POLL_INTERVAL" envDefault:"1s"`
	BatchSize      int           `env:"BATCH_SIZE" envDefault:"100"`
	MaxRetries     int           `env:"MAX_RETRIES" envDefault:"3"`
	RetryDelay     time.Duration `env:"RETRY_DELAY" envDefault:"5s"`
	WorkerCount    int           `env:"WORKER_COUNT" envDefault:"4"`
	
	// Monitoring
	MetricsPort int `env:"METRICS_PORT" envDefault:"9090"`
	
	// Logging
	LogLevel string `env:"LOG_LEVEL" envDefault:"info"`
}