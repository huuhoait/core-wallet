// Package cdc implements the Debezium CDC relay mode. It manages the Kafka Connect
// connector lifecycle and consumes the CDC change-event topic to route events to
// their final destination topics and mark rows SENT in WLT_OUTBOX.
package cdc

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"time"

	"github.com/rs/zerolog"

	"github.com/huuhoait/core-wallet/outbox-relay/internal/config"
)

// ConnectorManager handles the Debezium connector lifecycle via Kafka Connect REST API.
type ConnectorManager struct {
	cfg    *config.Config
	logger *zerolog.Logger
	client *http.Client
}

// NewConnectorManager creates a manager for the Debezium connector.
func NewConnectorManager(cfg *config.Config, logger *zerolog.Logger) *ConnectorManager {
	return &ConnectorManager{
		cfg:    cfg,
		logger: logger,
		client: &http.Client{Timeout: 30 * time.Second},
	}
}

// EnsureConnector registers (or updates) the Debezium connector if AutoRegister is enabled.
// Idempotent: if the connector already exists with the same config, this is a no-op.
func (m *ConnectorManager) EnsureConnector(ctx context.Context) error {
	if !m.cfg.CDC.AutoRegister {
		m.logger.Info().Msg("CDC auto-register disabled — assuming connector managed externally")
		return nil
	}

	connectorConfig, err := m.buildConnectorConfig()
	if err != nil {
		return fmt.Errorf("cdc: build connector config: %w", err)
	}

	// Check if connector exists
	exists, err := m.connectorExists(ctx)
	if err != nil {
		return fmt.Errorf("cdc: check connector: %w", err)
	}

	if exists {
		// Update existing connector config
		if err := m.updateConnector(ctx, connectorConfig); err != nil {
			return fmt.Errorf("cdc: update connector: %w", err)
		}
		m.logger.Info().Str("connector", m.cfg.CDC.ConnectorName).Msg("Debezium connector updated")
	} else {
		// Create new connector
		if err := m.createConnector(ctx, connectorConfig); err != nil {
			return fmt.Errorf("cdc: create connector: %w", err)
		}
		m.logger.Info().Str("connector", m.cfg.CDC.ConnectorName).Msg("Debezium connector created")
	}
	return nil
}

// Status returns the connector status (RUNNING, PAUSED, FAILED, UNASSIGNED).
func (m *ConnectorManager) Status(ctx context.Context) (string, error) {
	url := fmt.Sprintf("%s/connectors/%s/status", m.cfg.CDC.ConnectURL, m.cfg.CDC.ConnectorName)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return "", err
	}
	resp, err := m.client.Do(req)
	if err != nil {
		return "", fmt.Errorf("cdc: status request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusNotFound {
		return "NOT_FOUND", nil
	}
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("cdc: status returned %d", resp.StatusCode)
	}

	var status struct {
		Connector struct {
			State string `json:"state"`
		} `json:"connector"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&status); err != nil {
		return "", fmt.Errorf("cdc: decode status: %w", err)
	}
	return status.Connector.State, nil
}

// Pause pauses the connector (e.g. during maintenance).
func (m *ConnectorManager) Pause(ctx context.Context) error {
	url := fmt.Sprintf("%s/connectors/%s/pause", m.cfg.CDC.ConnectURL, m.cfg.CDC.ConnectorName)
	req, err := http.NewRequestWithContext(ctx, http.MethodPut, url, nil)
	if err != nil {
		return err
	}
	resp, err := m.client.Do(req)
	if err != nil {
		return fmt.Errorf("cdc: pause: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusAccepted && resp.StatusCode != http.StatusOK {
		return fmt.Errorf("cdc: pause returned %d", resp.StatusCode)
	}
	return nil
}

// Resume resumes a paused connector.
func (m *ConnectorManager) Resume(ctx context.Context) error {
	url := fmt.Sprintf("%s/connectors/%s/resume", m.cfg.CDC.ConnectURL, m.cfg.CDC.ConnectorName)
	req, err := http.NewRequestWithContext(ctx, http.MethodPut, url, nil)
	if err != nil {
		return err
	}
	resp, err := m.client.Do(req)
	if err != nil {
		return fmt.Errorf("cdc: resume: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusAccepted && resp.StatusCode != http.StatusOK {
		return fmt.Errorf("cdc: resume returned %d", resp.StatusCode)
	}
	return nil
}

// Delete removes the connector (cleanup).
func (m *ConnectorManager) Delete(ctx context.Context) error {
	url := fmt.Sprintf("%s/connectors/%s", m.cfg.CDC.ConnectURL, m.cfg.CDC.ConnectorName)
	req, err := http.NewRequestWithContext(ctx, http.MethodDelete, url, nil)
	if err != nil {
		return err
	}
	resp, err := m.client.Do(req)
	if err != nil {
		return fmt.Errorf("cdc: delete: %w", err)
	}
	defer resp.Body.Close()
	return nil
}

func (m *ConnectorManager) connectorExists(ctx context.Context) (bool, error) {
	url := fmt.Sprintf("%s/connectors/%s", m.cfg.CDC.ConnectURL, m.cfg.CDC.ConnectorName)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return false, err
	}
	resp, err := m.client.Do(req)
	if err != nil {
		return false, fmt.Errorf("cdc: check exists: %w", err)
	}
	defer resp.Body.Close()
	return resp.StatusCode == http.StatusOK, nil
}

func (m *ConnectorManager) createConnector(ctx context.Context, connConfig map[string]string) error {
	body := map[string]interface{}{
		"name":   m.cfg.CDC.ConnectorName,
		"config": connConfig,
	}
	return m.doJSON(ctx, http.MethodPost, m.cfg.CDC.ConnectURL+"/connectors", body)
}

func (m *ConnectorManager) updateConnector(ctx context.Context, connConfig map[string]string) error {
	url := fmt.Sprintf("%s/connectors/%s/config", m.cfg.CDC.ConnectURL, m.cfg.CDC.ConnectorName)
	return m.doJSON(ctx, http.MethodPut, url, connConfig)
}

func (m *ConnectorManager) doJSON(ctx context.Context, method, url string, payload interface{}) error {
	b, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, method, url, bytes.NewReader(b))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := m.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		body, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("kafka-connect %s %s returned %d: %s", method, url, resp.StatusCode, body)
	}
	return nil
}

// buildConnectorConfig builds the Debezium PostgreSQL connector configuration.
// If CDC_CONNECTOR_CONFIG points to a file, it loads that; otherwise uses defaults.
func (m *ConnectorManager) buildConnectorConfig() (map[string]string, error) {
	// Load from file if specified
	if m.cfg.CDC.ConnectorConfigPath != "" {
		return m.loadConfigFile(m.cfg.CDC.ConnectorConfigPath)
	}

	// Built-in default config
	return map[string]string{
		"connector.class":        "io.debezium.connector.postgresql.PostgresConnector",
		"database.hostname":      m.cfg.DBHost,
		"database.port":          fmt.Sprintf("%d", m.cfg.DBPort),
		"database.user":          m.cfg.DBUser,
		"database.password":      m.cfg.DBPassword,
		"database.dbname":        m.cfg.DBName,
		"database.server.name":   "wallet-db",
		"topic.prefix":           m.cfg.KafkaTopicPrefix,
		"plugin.name":            "pgoutput",
		"table.include.list":     "public.wlt_outbox",
		"slot.name":              m.cfg.CDC.SlotName,
		"publication.name":       m.cfg.CDC.PublicationName,
		"publication.autocreate.mode": "filtered",

		// Transforms: route each row to its own topic field + extract payload
		"transforms":                             "outbox",
		"transforms.outbox.type":                 "io.debezium.transforms.outbox.EventRouter",
		"transforms.outbox.table.field.event.id": "event_uuid",
		"transforms.outbox.table.field.event.key": "partition_key",
		"transforms.outbox.table.field.event.type": "event_type",
		"transforms.outbox.table.field.event.payload": "payload",
		"transforms.outbox.table.fields.additional.placement": "topic:header,headers:header",
		"transforms.outbox.route.by.field":       "topic",
		"transforms.outbox.route.topic.regex":    "(.*)",
		"transforms.outbox.route.topic.replacement": "$1",

		// Serialization
		"key.converter":                 "org.apache.kafka.connect.storage.StringConverter",
		"value.converter":               "org.apache.kafka.connect.json.JsonConverter",
		"value.converter.schemas.enable": "false",

		// Performance
		"max.batch.size":       "1000",
		"max.queue.size":       "10000",
		"poll.interval.ms":     "500",
		"snapshot.mode":        "never",
		"snapshot.locking.mode": "none",

		// Reliability
		"tombstones.on.delete":                   "false",
		"heartbeat.interval.ms":                  "30000",
		"heartbeat.topics.prefix":                "__debezium-heartbeat",
		"event.processing.failure.handling.mode": "skip",
		"decimal.handling.mode":                  "string",
		"binary.handling.mode":                   "base64",
	}, nil
}

func (m *ConnectorManager) loadConfigFile(path string) (map[string]string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("cdc: read config file %s: %w", path, err)
	}
	var raw struct {
		Config map[string]string `json:"config"`
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		// Try flat map
		var flat map[string]string
		if err2 := json.Unmarshal(data, &flat); err2 != nil {
			return nil, fmt.Errorf("cdc: parse config file: %w", err)
		}
		return flat, nil
	}
	if raw.Config != nil {
		return raw.Config, nil
	}
	var flat map[string]string
	if err := json.Unmarshal(data, &flat); err != nil {
		return nil, fmt.Errorf("cdc: parse config file as flat map: %w", err)
	}
	return flat, nil
}
