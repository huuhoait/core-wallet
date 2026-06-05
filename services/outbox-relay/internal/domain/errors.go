package domain

import "errors"

// ErrZeroEventID is returned when a CDC change event carries no usable event_id,
// so the relay cannot identify which WLT_OUTBOX row to mark SENT.
var ErrZeroEventID = errors.New("outbox: event_id is 0 — cannot mark SENT")
