package utils

import (
	"sync"
	"time"
)

// Metrics tracks worker performance metrics
type Metrics struct {
	mu sync.RWMutex

	// Counters
	EventsFetched    int64
	EventsProcessed  int64
	EventsFailed     int64
	KafkaPublished   int64
	KafkaFailed      int64

	// Errors by type
	Errors map[string]int64

	// Timing
	LastFetchTime    time.Time
	LastProcessTime  time.Time
	TotalProcessTime time.Duration

	// Start time
	startTime time.Time
}

// NewMetrics creates a new metrics instance
func NewMetrics() *Metrics {
	return &Metrics{
		Errors:    make(map[string]int64),
		startTime: time.Now(),
	}
}

// IncrementSuccess increments the success counter
func (m *Metrics) IncrementSuccess() {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.EventsProcessed++
	m.KafkaPublished++
	m.LastProcessTime = time.Now()
}

// IncrementErrors increments the error counter for a specific error type
func (m *Metrics) IncrementErrors(errorType string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.EventsFailed++
	m.Errors[errorType]++
}

// RecordFetch records a fetch operation
func (m *Metrics) RecordFetch(count int) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.EventsFetched += int64(count)
	m.LastFetchTime = time.Now()
}

// RecordProcessTime records the time taken to process a batch
func (m *Metrics) RecordProcessTime(duration time.Duration) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.TotalProcessTime += duration
}

// GetStats returns current metrics
func (m *Metrics) GetStats() map[string]interface{} {
	m.mu.RLock()
	defer m.mu.RUnlock()

	uptime := time.Since(m.startTime)

	return map[string]interface{}{
		"uptime_seconds":            uptime.Seconds(),
		"events_fetched":            m.EventsFetched,
		"events_processed":          m.EventsProcessed,
		"events_failed":             m.EventsFailed,
		"kafka_published":            m.KafkaPublished,
		"kafka_failed":               m.KafkaFailed,
		"errors":                     m.Errors,
		"last_fetch_time":            m.LastFetchTime,
		"last_process_time":          m.LastProcessTime,
		"total_process_time_seconds": m.TotalProcessTime.Seconds(),
		"success_rate":              m.calculateSuccessRate(),
	}
}

// calculateSuccessRate calculates the success rate
func (m *Metrics) calculateSuccessRate() float64 {
	total := m.EventsProcessed + m.EventsFailed
	if total == 0 {
		return 0
	}
	return float64(m.EventsProcessed) / float64(total) * 100
}

// Reset resets all metrics (useful for testing)
func (m *Metrics) Reset() {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.EventsFetched = 0
	m.EventsProcessed = 0
	m.EventsFailed = 0
	m.KafkaPublished = 0
	m.KafkaFailed = 0
	m.Errors = make(map[string]int64)
	m.LastFetchTime = time.Time{}
	m.LastProcessTime = time.Time{}
	m.TotalProcessTime = 0
}