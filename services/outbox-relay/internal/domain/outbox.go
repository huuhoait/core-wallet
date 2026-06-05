// Package domain holds the pure types of the outbox relay. It has no framework
// or infrastructure imports (no pgx, sarama, net/http) — only the standard
// library — so the inner layers can depend on it freely.
package domain

import "time"

// OutboxEvent is one row of the wallet WLT_OUTBOX table (the transactional
// outbox written by the posting stored procedures). The relay reads PENDING /
// FAILED rows and publishes them to the topic the producer already chose.
type OutboxEvent struct {
	EventID      int64     // event_id (PK)
	EventUUID    string    // event_uuid
	EventType    string    // event_type
	Topic        string    // topic — the destination Kafka topic, decided at write time
	PartitionKey string    // partition_key — the Kafka message key
	Payload      []byte    // payload (jsonb)
	Headers      []byte    // headers (jsonb object; nil when SQL NULL)
	Attempts     int       // attempts so far
	CreatedAt    time.Time // created_at
}

// KafkaMessage is one message to publish.
type KafkaMessage struct {
	Topic   string
	Key     string
	Value   []byte
	Headers map[string]string
}

// SentRef records where a successfully published event landed, so the relay can
// stamp kafka_partition / kafka_offset back onto the outbox row.
type SentRef struct {
	EventID   int64
	Partition int32
	Offset    int64
}
