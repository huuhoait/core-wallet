// Package kafkax centralises the sarama broker-connection setup for the wallet
// platform's Kafka clients. Today only the outbox-relay connects to Kafka, but
// keeping the producer/consumer wiring here gives any future service one place
// for the platform's delivery defaults (idempotent all-replicas-ack producer,
// round-robin oldest-offset consumer group).
//
// It deliberately exposes only the raw sarama clients — span/propagation and
// message-handling logic stays in the owning service, since that is
// domain-specific (e.g. the relay's traceparent extract→inject).
package kafkax

import (
	"fmt"
	"time"

	"github.com/IBM/sarama"
)

// NewSyncProducer builds a synchronous producer with at-least-once delivery:
// all-replicas ack + idempotent writes (which require MaxOpenRequests=1) and a
// hash partitioner. maxRetries bounds the per-send retry budget. A synchronous
// producer is required when the caller needs the broker ack (partition/offset)
// before recording progress — e.g. the outbox relay marking a row SENT.
func NewSyncProducer(brokers []string, maxRetries int) (sarama.SyncProducer, error) {
	sc := sarama.NewConfig()
	sc.Producer.RequiredAcks = sarama.WaitForAll
	sc.Producer.Retry.Max = maxRetries
	sc.Producer.Return.Successes = true // required by SyncProducer
	sc.Producer.Idempotent = true
	sc.Net.MaxOpenRequests = 1 // required when Idempotent = true
	sc.Producer.Partitioner = sarama.NewHashPartitioner

	sp, err := sarama.NewSyncProducer(brokers, sc)
	if err != nil {
		return nil, fmt.Errorf("kafkax: connect producer to %v: %w", brokers, err)
	}
	return sp, nil
}

// NewConsumerGroup builds a consumer group with round-robin rebalancing,
// oldest-offset initial position, and 1s auto-commit — the defaults the relay's
// CDC consumer uses to keep outbox row status accurate.
func NewConsumerGroup(brokers []string, groupID string) (sarama.ConsumerGroup, error) {
	sc := sarama.NewConfig()
	sc.Consumer.Group.Rebalance.GroupStrategies = []sarama.BalanceStrategy{sarama.NewBalanceStrategyRoundRobin()}
	sc.Consumer.Offsets.Initial = sarama.OffsetOldest
	sc.Consumer.Offsets.AutoCommit.Enable = true
	sc.Consumer.Offsets.AutoCommit.Interval = 1 * time.Second

	cg, err := sarama.NewConsumerGroup(brokers, groupID, sc)
	if err != nil {
		return nil, fmt.Errorf("kafkax: create consumer group %q: %w", groupID, err)
	}
	return cg, nil
}
