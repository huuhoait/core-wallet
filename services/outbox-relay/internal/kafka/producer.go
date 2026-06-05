// Package kafka holds the broker adapters: a synchronous producer that satisfies
// usecase.EventPublisher (polling mode) and a Debezium CDC consumer that drives
// usecase.CDCStatusUpdater (CDC mode). Sarama is confined to this package.
package kafka

import (
	"fmt"
	"log/slog"

	"github.com/IBM/sarama"

	"github.com/huuhoait/core-wallet/outbox-relay/internal/domain"
	"github.com/huuhoait/core-wallet/outbox-relay/internal/usecase"
)

// SyncProducer publishes outbox events via a synchronous Kafka producer. The
// relay needs the per-message broker ack (and its partition/offset) BEFORE it
// marks the source row SENT, so the outbox guarantee is at-least-once. It
// satisfies usecase.EventPublisher.
type SyncProducer struct {
	sync   sarama.SyncProducer
	logger *slog.Logger
}

var _ usecase.EventPublisher = (*SyncProducer)(nil)

// NewSyncProducer builds a SyncProducer against brokers with idempotent,
// all-replicas-ack delivery. maxRetries bounds the per-send retry budget.
func NewSyncProducer(brokers []string, maxRetries int, logger *slog.Logger) (*SyncProducer, error) {
	sc := sarama.NewConfig()
	sc.Producer.RequiredAcks = sarama.WaitForAll
	sc.Producer.Retry.Max = maxRetries
	sc.Producer.Return.Successes = true // required by SyncProducer
	sc.Producer.Idempotent = true
	sc.Net.MaxOpenRequests = 1 // required when Idempotent = true
	sc.Producer.Partitioner = sarama.NewHashPartitioner

	sp, err := sarama.NewSyncProducer(brokers, sc)
	if err != nil {
		return nil, fmt.Errorf("kafka: connect to %v: %w", brokers, err)
	}
	logger.Info("Kafka producer ready", slog.Any("brokers", brokers))
	return &SyncProducer{sync: sp, logger: logger}, nil
}

// Publish sends one message synchronously and returns the partition+offset it
// landed on (so the caller can record them) plus any error.
func (p *SyncProducer) Publish(msg domain.KafkaMessage) (int32, int64, error) {
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
		return 0, 0, fmt.Errorf("kafka: send to %s: %w", msg.Topic, err)
	}
	return partition, offset, nil
}

// Close flushes and closes the underlying producer.
func (p *SyncProducer) Close() error { return p.sync.Close() }
