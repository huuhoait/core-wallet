// Package producer publishes outbox events to Kafka.
package producer

import (
	"fmt"

	"github.com/IBM/sarama"
	"github.com/rs/zerolog"

	"github.com/huuhoait/core-wallet/outbox-relay/internal/config"
	"github.com/huuhoait/core-wallet/outbox-relay/pkg/models"
)

// Producer publishes outbox events via a synchronous Kafka producer. The worker
// needs the per-message broker ack (and its partition/offset) BEFORE it marks the
// source row SENT, so the outbox guarantee is at-least-once.
type Producer struct {
	sync   sarama.SyncProducer
	logger *zerolog.Logger
}

// NewProducer builds a SyncProducer against cfg.KafkaBrokers with idempotent,
// all-replicas-ack delivery.
func NewProducer(cfg *config.Config, logger *zerolog.Logger) (*Producer, error) {
	sc := sarama.NewConfig()
	sc.Producer.RequiredAcks = sarama.WaitForAll
	sc.Producer.Retry.Max = cfg.MaxRetries
	sc.Producer.Return.Successes = true // required by SyncProducer
	sc.Producer.Idempotent = true
	sc.Net.MaxOpenRequests = 1 // required when Idempotent = true
	sc.Producer.Partitioner = sarama.NewHashPartitioner

	sp, err := sarama.NewSyncProducer(cfg.KafkaBrokers, sc)
	if err != nil {
		return nil, fmt.Errorf("producer: connect to kafka %v: %w", cfg.KafkaBrokers, err)
	}
	logger.Info().Strs("brokers", cfg.KafkaBrokers).Msg("Kafka producer ready")
	return &Producer{sync: sp, logger: logger}, nil
}

// Publish sends one message synchronously and returns the partition+offset it
// landed on (so the caller can record them) plus any error.
func (p *Producer) Publish(msg models.KafkaMessage) (int32, int64, error) {
	headers := make([]sarama.RecordHeader, 0, len(msg.Headers))
	for k, v := range msg.Headers {
		headers = append(headers, sarama.RecordHeader{Key: []byte(k), Value: []byte(v)})
	}
	partition, offset, err := p.sync.SendMessage(&sarama.ProducerMessage{
		Topic:   msg.Topic,
		Key:     sarama.StringEncoder(msg.Key),
		Value:   sarama.ByteEncoder(msg.Value),
		Headers: headers,
	})
	if err != nil {
		return 0, 0, fmt.Errorf("producer: send to %s: %w", msg.Topic, err)
	}
	return partition, offset, nil
}

// Close flushes and closes the underlying producer.
func (p *Producer) Close() error {
	return p.sync.Close()
}
