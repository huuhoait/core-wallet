package kafka

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/IBM/sarama"
	"github.com/rs/zerolog"

	"github.com/huuhoait/core-wallet/outbox-relay/internal/domain"
	"github.com/huuhoait/core-wallet/outbox-relay/internal/usecase"
)

// CDCConsumer is the driving adapter for CDC mode. It consumes the Debezium CDC
// topic (change events from WLT_OUTBOX) and, for each row, drives the
// CDCStatusUpdater use case to flip the source row to SENT. In CDC mode Debezium
// already delivered the row to its destination topic via the EventRouter
// transform — this consumer only keeps the outbox status accurate.
type CDCConsumer struct {
	updater *usecase.CDCStatusUpdater
	metrics usecase.MetricsRecorder
	logger  *zerolog.Logger

	topic  string
	group  sarama.ConsumerGroup
	cancel context.CancelFunc
	wg     sync.WaitGroup
}

// NewCDCConsumer creates a consumer group bound to the CDC topic.
func NewCDCConsumer(brokers []string, groupID, topic string, updater *usecase.CDCStatusUpdater, metrics usecase.MetricsRecorder, logger *zerolog.Logger) (*CDCConsumer, error) {
	sc := sarama.NewConfig()
	sc.Consumer.Group.Rebalance.GroupStrategies = []sarama.BalanceStrategy{sarama.NewBalanceStrategyRoundRobin()}
	sc.Consumer.Offsets.Initial = sarama.OffsetOldest
	sc.Consumer.Offsets.AutoCommit.Enable = true
	sc.Consumer.Offsets.AutoCommit.Interval = 1 * time.Second

	cg, err := sarama.NewConsumerGroup(brokers, groupID, sc)
	if err != nil {
		return nil, fmt.Errorf("kafka: create consumer group: %w", err)
	}

	return &CDCConsumer{
		updater: updater,
		metrics: metrics,
		logger:  logger,
		topic:   topic,
		group:   cg,
	}, nil
}

// Start begins consuming the CDC topic. Non-blocking.
func (c *CDCConsumer) Start(ctx context.Context) {
	ctx, c.cancel = context.WithCancel(ctx)
	c.wg.Add(1)
	go c.run(ctx)
	c.logger.Info().Str("topic", c.topic).Msg("CDC consumer started")
}

// Stop gracefully shuts down the consumer.
func (c *CDCConsumer) Stop() {
	if c.cancel != nil {
		c.cancel()
	}
	c.wg.Wait()
	_ = c.group.Close()
	c.logger.Info().Msg("CDC consumer stopped")
}

func (c *CDCConsumer) run(ctx context.Context) {
	defer c.wg.Done()
	handler := &cdcHandler{updater: c.updater, metrics: c.metrics, logger: c.logger}

	for {
		select {
		case <-ctx.Done():
			return
		default:
		}

		// Consume returns when the session ends (rebalance) — loop to rejoin.
		if err := c.group.Consume(ctx, []string{c.topic}, handler); err != nil {
			if ctx.Err() != nil {
				return
			}
			c.logger.Error().Err(err).Msg("CDC consumer error — retrying in 5s")
			time.Sleep(5 * time.Second)
		}
	}
}

// cdcHandler implements sarama.ConsumerGroupHandler.
type cdcHandler struct {
	updater *usecase.CDCStatusUpdater
	metrics usecase.MetricsRecorder
	logger  *zerolog.Logger
}

func (h *cdcHandler) Setup(sarama.ConsumerGroupSession) error   { return nil }
func (h *cdcHandler) Cleanup(sarama.ConsumerGroupSession) error { return nil }

// ConsumeClaim processes CDC messages. Each is a Debezium change event for a row
// in WLT_OUTBOX; we extract its identity and drive the use case to mark it SENT.
func (h *cdcHandler) ConsumeClaim(session sarama.ConsumerGroupSession, claim sarama.ConsumerGroupClaim) error {
	for msg := range claim.Messages() {
		if err := h.handle(session.Context(), msg); err != nil {
			h.logger.Warn().Err(err).
				Int64("offset", msg.Offset).
				Int32("partition", msg.Partition).
				Msg("CDC message processing failed — skipping")
			h.metrics.IncrementErrors("cdc_process")
		} else {
			h.metrics.IncrementSuccess()
		}
		session.MarkMessage(msg, "")
	}
	return nil
}

// handle parses the Debezium change event into a domain.SentRef and drives the
// use case. Delete/tombstone events are ignored.
func (h *cdcHandler) handle(ctx context.Context, msg *sarama.ConsumerMessage) error {
	var event debeziumEvent
	if err := json.Unmarshal(msg.Value, &event); err != nil {
		return fmt.Errorf("kafka: unmarshal cdc event: %w", err)
	}

	// Skip delete/tombstone events.
	if event.Op == "d" || (event.Payload == nil && event.After == nil) {
		return nil
	}

	eventID := int64(0)
	if event.Payload != nil {
		eventID = event.Payload.EventID
	}
	if eventID == 0 && event.After != nil {
		// Standard Debezium envelope.
		eventID = event.After.EventID
	}

	ref := domain.SentRef{EventID: eventID, Partition: msg.Partition, Offset: msg.Offset}
	if err := h.updater.MarkDelivered(ctx, ref); err != nil {
		if errors.Is(err, domain.ErrZeroEventID) {
			return err
		}
		return fmt.Errorf("kafka: mark delivered event_id=%d: %w", eventID, err)
	}
	return nil
}

// debeziumEvent represents the Debezium change event structure. Supports both
// the standard envelope (with before/after) and the ExtractNewRecordState /
// EventRouter unwrapped form.
type debeziumEvent struct {
	Op      string         `json:"op"`                // c=create, u=update, d=delete, r=read(snapshot)
	Payload *outboxPayload `json:"payload,omitempty"` // unwrapped (EventRouter)
	After   *outboxPayload `json:"after,omitempty"`   // standard envelope
}

type outboxPayload struct {
	EventID      int64           `json:"event_id"`
	EventUUID    string          `json:"event_uuid"`
	EventType    string          `json:"event_type"`
	Topic        string          `json:"topic"`
	PartitionKey string          `json:"partition_key"`
	Payload      json.RawMessage `json:"payload"`
	Status       string          `json:"status"`
}
