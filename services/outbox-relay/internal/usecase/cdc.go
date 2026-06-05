package usecase

import (
	"context"

	"github.com/huuhoait/core-wallet/outbox-relay/internal/domain"
)

// CDCStatusUpdater is the input port for CDC mode. In CDC mode Debezium already
// publishes each WLT_OUTBOX row to its destination topic (via the EventRouter
// transform); the relay's remaining job is to flip the source row to SENT so the
// retry / dead-letter logic and operational dashboards stay accurate.
//
// The Kafka CDC consumer (internal/kafka) is the driving adapter: it parses each
// Debezium change event into a domain.SentRef and calls MarkDelivered. Keeping
// this behind a use case (rather than the consumer touching the repo directly)
// preserves the inbound-adapter → usecase → driven-port direction.
type CDCStatusUpdater struct {
	repo OutboxRepository
}

// NewCDCStatusUpdater wires the CDC status updater.
func NewCDCStatusUpdater(repo OutboxRepository) *CDCStatusUpdater {
	return &CDCStatusUpdater{repo: repo}
}

// MarkDelivered records that Debezium delivered the row identified by ref,
// flipping it to SENT (stamping partition/offset). Returns ErrZeroEventID when
// the change event carried no usable event_id.
func (u *CDCStatusUpdater) MarkDelivered(ctx context.Context, ref domain.SentRef) error {
	if ref.EventID == 0 {
		return domain.ErrZeroEventID
	}
	return u.repo.MarkSent(ctx, ref)
}
