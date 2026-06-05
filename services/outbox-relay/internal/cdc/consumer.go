package cdc

import (
	"context"
	"encoding/json"
	"fmt"
	"sync"
	"time"

	"github.com/IBM/sarama"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/rs/zerolog"

	"github.com/huuhoait/core-wallet/outbox-relay/internal/config"
	"github.com/huuhoait/core-wallet/outbox-relay/pkg/utils"
)

// CDCConsumer consumes the Debezium CDC topic (change events from WLT_OUTBOX)
// and marks the corresponding rows as SENT. In CDC mode, Debezium already
// publishes to the final destination topics via the EventRouter transform —
// this consumer's job is to update the outbox status so dead-letter/retry logic
// and operational dashboards work correctly.
type CDCConsumer struct {
	cfg     *config.Config
	pool    *pgxpool.Pool
	logger  *zerolog.Logger
	metrics *utils.Metrics

	consumer sarama.ConsumerGroup
	cancel   context.CancelFunc
	wg       sync.WaitGroup
}

// NewCDCConsumer creates a consumer that listens to the Debezium CDC topic.
func NewCDCConsumer(cfg *config.Config, pool *pgxpool.Pool, logger *zerolog.Logger, metrics *utils.Metrics) (*CDCConsumer, error) {
	sc := sarama.NewConfig()
	sc.Consumer.Group.Rebalance.GroupStrategies = []sarama.BalanceStrategy{sarama.NewBalanceStrategyRoundRobin()}
	sc.Consumer.Offsets.Initial = sarama.OffsetOldest
	sc.Consumer.Offsets.AutoCommit.Enable = true
	sc.Consumer.Offsets.AutoCommit.Interval = 1 * time.Second

	cg, err := sarama.NewConsumerGroup(cfg.KafkaBrokers, cfg.CDC.ConsumerGroup, sc)
	if err != nil {
		return nil, fmt.Errorf("cdc: create consumer group: %w", err)
	}

	return &CDCConsumer{
		cfg:      cfg,
		pool:     pool,
		logger:   logger,
		metrics:  metrics,
		consumer: cg,
	}, nil
}

// Start begins consuming the CDC topic. Non-blocking.
func (c *CDCConsumer) Start(ctx context.Context) {
	ctx, c.cancel = context.WithCancel(ctx)
	c.wg.Add(1)
	go c.run(ctx)
	c.logger.Info().
		Str("topic", c.cfg.CDC.CDCTopic).
		Str("group", c.cfg.CDC.ConsumerGroup).
		Msg("CDC consumer started")
}

// Stop gracefully shuts down the consumer.
func (c *CDCConsumer) Stop() {
	if c.cancel != nil {
		c.cancel()
	}
	c.wg.Wait()
	_ = c.consumer.Close()
	c.logger.Info().Msg("CDC consumer stopped")
}

func (c *CDCConsumer) run(ctx context.Context) {
	defer c.wg.Done()
	handler := &cdcHandler{
		pool:    c.pool,
		logger:  c.logger,
		metrics: c.metrics,
	}

	for {
		select {
		case <-ctx.Done():
			return
		default:
		}

		// Consume returns when the session ends (rebalance) — loop to rejoin.
		if err := c.consumer.Consume(ctx, []string{c.cfg.CDC.CDCTopic}, handler); err != nil {
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
	pool    *pgxpool.Pool
	logger  *zerolog.Logger
	metrics *utils.Metrics
}

func (h *cdcHandler) Setup(sarama.ConsumerGroupSession) error   { return nil }
func (h *cdcHandler) Cleanup(sarama.ConsumerGroupSession) error { return nil }

// ConsumeClaim processes CDC messages. Each message is a Debezium change event
// for a row in WLT_OUTBOX. We extract the event_id and mark it SENT.
func (h *cdcHandler) ConsumeClaim(session sarama.ConsumerGroupSession, claim sarama.ConsumerGroupClaim) error {
	for msg := range claim.Messages() {
		if err := h.processMessage(session.Context(), msg); err != nil {
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

// processMessage extracts the event_id from the CDC message and marks it SENT.
func (h *cdcHandler) processMessage(ctx context.Context, msg *sarama.ConsumerMessage) error {
	// Parse the Debezium change event
	var event debeziumEvent
	if err := json.Unmarshal(msg.Value, &event); err != nil {
		return fmt.Errorf("cdc: unmarshal event: %w", err)
	}

	// Skip delete/tombstone events
	if event.Op == "d" || event.Payload == nil {
		return nil
	}

	eventID := event.Payload.EventID
	if eventID == 0 {
		// Try extracting from After (standard Debezium envelope)
		if event.After != nil {
			eventID = event.After.EventID
		}
	}
	if eventID == 0 {
		return fmt.Errorf("cdc: event_id is 0 — cannot mark SENT")
	}

	// Mark as SENT in WLT_OUTBOX (the actual Kafka delivery was done by Debezium → EventRouter)
	_, err := h.pool.Exec(ctx, `
		UPDATE public.wlt_outbox
		   SET status     = 'SENT',
		       sent_at    = now(),
		       attempts   = attempts + 1,
		       kafka_partition = $2,
		       kafka_offset    = $3,
		       updated_at = now(),
		       updated_by = 'outbox-relay-cdc'
		 WHERE event_id = $1
		   AND status IN ('PENDING', 'FAILED')`,
		eventID, msg.Partition, msg.Offset)
	if err != nil {
		return fmt.Errorf("cdc: mark sent event_id=%d: %w", eventID, err)
	}
	return nil
}

// debeziumEvent represents the Debezium change event structure.
// Supports both the standard envelope (with before/after) and the
// ExtractNewRecordState / EventRouter unwrapped form.
type debeziumEvent struct {
	Op      string          `json:"op"`                // c=create, u=update, d=delete, r=read(snapshot)
	Payload *outboxPayload  `json:"payload,omitempty"` // unwrapped (EventRouter)
	After   *outboxPayload  `json:"after,omitempty"`   // standard envelope
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
