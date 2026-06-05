// Package debezium manages the Debezium PostgreSQL connector via the Kafka
// Connect REST API. It satisfies usecase.ConnectorController. The Kafka Connect
// HTTP wire format is confined to this package.
package debezium

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"time"

	"github.com/huuhoait/core-wallet/outbox-relay/internal/usecase"
)

// Settings is everything the connector manager needs, filled by the composition
// root from config so this adapter never imports the config package.
type Settings struct {
	// Kafka Connect REST endpoint (e.g. http://kafka-connect:8083).
	ConnectURL string
	// Connector name registered in Kafka Connect.
	ConnectorName string
	// Whether to auto-register / update the connector on startup.
	AutoRegister bool
	// Optional path to a connector config JSON (overrides the built-in default).
	ConnectorConfigPath string
	// PG logical-replication slot + publication names.
	SlotName        string
	PublicationName string
	// Source DB coordinates Debezium connects to.
	DBHost     string
	DBPort     int
	DBUser     string
	DBPassword string
	DBName     string
	// Kafka topic prefix Debezium uses.
	TopicPrefix string
}

// ConnectorManager handles the Debezium connector lifecycle. It satisfies
// usecase.ConnectorController.
type ConnectorManager struct {
	cfg    Settings
	logger *slog.Logger
	client *http.Client
}

var _ usecase.ConnectorController = (*ConnectorManager)(nil)

// NewConnectorManager creates a manager for the Debezium connector.
func NewConnectorManager(cfg Settings, logger *slog.Logger) *ConnectorManager {
	return &ConnectorManager{
		cfg:    cfg,
		logger: logger,
		client: &http.Client{Timeout: 30 * time.Second},
	}
}

// Ensure registers (or updates) the Debezium connector if AutoRegister is on.
// Idempotent: an existing connector is updated in place.
func (m *ConnectorManager) Ensure(ctx context.Context) error {
	if !m.cfg.AutoRegister {
		m.logger.Info("CDC auto-register disabled — assuming connector managed externally")
		return nil
	}

	connectorConfig, err := m.buildConnectorConfig()
	if err != nil {
		return fmt.Errorf("debezium: build connector config: %w", err)
	}

	exists, err := m.connectorExists(ctx)
	if err != nil {
		return fmt.Errorf("debezium: check connector: %w", err)
	}

	if exists {
		if err := m.updateConnector(ctx, connectorConfig); err != nil {
			return fmt.Errorf("debezium: update connector: %w", err)
		}
		m.logger.Info("Debezium connector updated", slog.String("connector", m.cfg.ConnectorName))
	} else {
		if err := m.createConnector(ctx, connectorConfig); err != nil {
			return fmt.Errorf("debezium: create connector: %w", err)
		}
		m.logger.Info("Debezium connector created", slog.String("connector", m.cfg.ConnectorName))
	}
	return nil
}

// Status returns the connector state (RUNNING, PAUSED, FAILED, UNASSIGNED, or
// NOT_FOUND when the connector does not exist).
func (m *ConnectorManager) Status(ctx context.Context) (string, error) {
	url := fmt.Sprintf("%s/connectors/%s/status", m.cfg.ConnectURL, m.cfg.ConnectorName)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return "", err
	}
	resp, err := m.client.Do(req)
	if err != nil {
		return "", fmt.Errorf("debezium: status request: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()

	if resp.StatusCode == http.StatusNotFound {
		return "NOT_FOUND", nil
	}
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("debezium: status returned %d", resp.StatusCode)
	}

	var status struct {
		Connector struct {
			State string `json:"state"`
		} `json:"connector"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&status); err != nil {
		return "", fmt.Errorf("debezium: decode status: %w", err)
	}
	return status.Connector.State, nil
}

// Pause pauses the connector (e.g. during maintenance).
func (m *ConnectorManager) Pause(ctx context.Context) error {
	return m.lifecycle(ctx, "pause")
}

// Resume resumes a paused connector.
func (m *ConnectorManager) Resume(ctx context.Context) error {
	return m.lifecycle(ctx, "resume")
}

// Delete removes the connector (cleanup).
func (m *ConnectorManager) Delete(ctx context.Context) error {
	url := fmt.Sprintf("%s/connectors/%s", m.cfg.ConnectURL, m.cfg.ConnectorName)
	req, err := http.NewRequestWithContext(ctx, http.MethodDelete, url, nil)
	if err != nil {
		return err
	}
	resp, err := m.client.Do(req)
	if err != nil {
		return fmt.Errorf("debezium: delete: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()
	return nil
}

func (m *ConnectorManager) lifecycle(ctx context.Context, action string) error {
	url := fmt.Sprintf("%s/connectors/%s/%s", m.cfg.ConnectURL, m.cfg.ConnectorName, action)
	req, err := http.NewRequestWithContext(ctx, http.MethodPut, url, nil)
	if err != nil {
		return err
	}
	resp, err := m.client.Do(req)
	if err != nil {
		return fmt.Errorf("debezium: %s: %w", action, err)
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusAccepted && resp.StatusCode != http.StatusOK {
		return fmt.Errorf("debezium: %s returned %d", action, resp.StatusCode)
	}
	return nil
}

func (m *ConnectorManager) connectorExists(ctx context.Context) (bool, error) {
	url := fmt.Sprintf("%s/connectors/%s", m.cfg.ConnectURL, m.cfg.ConnectorName)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return false, err
	}
	resp, err := m.client.Do(req)
	if err != nil {
		return false, fmt.Errorf("debezium: check exists: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()
	return resp.StatusCode == http.StatusOK, nil
}

func (m *ConnectorManager) createConnector(ctx context.Context, connConfig map[string]string) error {
	body := map[string]any{
		"name":   m.cfg.ConnectorName,
		"config": connConfig,
	}
	return m.doJSON(ctx, http.MethodPost, m.cfg.ConnectURL+"/connectors", body)
}

func (m *ConnectorManager) updateConnector(ctx context.Context, connConfig map[string]string) error {
	url := fmt.Sprintf("%s/connectors/%s/config", m.cfg.ConnectURL, m.cfg.ConnectorName)
	return m.doJSON(ctx, http.MethodPut, url, connConfig)
}

func (m *ConnectorManager) doJSON(ctx context.Context, method, url string, payload any) error {
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
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode >= 400 {
		body, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("kafka-connect %s %s returned %d: %s", method, url, resp.StatusCode, body)
	}
	return nil
}

// buildConnectorConfig builds the Debezium PostgreSQL connector configuration.
// If ConnectorConfigPath is set, it loads that file; otherwise uses defaults.
func (m *ConnectorManager) buildConnectorConfig() (map[string]string, error) {
	if m.cfg.ConnectorConfigPath != "" {
		return m.loadConfigFile(m.cfg.ConnectorConfigPath)
	}

	return map[string]string{
		"connector.class":             "io.debezium.connector.postgresql.PostgresConnector",
		"database.hostname":           m.cfg.DBHost,
		"database.port":               fmt.Sprintf("%d", m.cfg.DBPort),
		"database.user":               m.cfg.DBUser,
		"database.password":           m.cfg.DBPassword,
		"database.dbname":             m.cfg.DBName,
		"database.server.name":        "wallet-db",
		"topic.prefix":                m.cfg.TopicPrefix,
		"plugin.name":                 "pgoutput",
		"table.include.list":          "public.wlt_outbox",
		"slot.name":                   m.cfg.SlotName,
		"publication.name":            m.cfg.PublicationName,
		"publication.autocreate.mode": "filtered",

		// Transforms: route each row to its own topic field + extract payload
		"transforms":                                          "outbox",
		"transforms.outbox.type":                              "io.debezium.transforms.outbox.EventRouter",
		"transforms.outbox.table.field.event.id":              "event_uuid",
		"transforms.outbox.table.field.event.key":             "partition_key",
		"transforms.outbox.table.field.event.type":            "event_type",
		"transforms.outbox.table.field.event.payload":         "payload",
		"transforms.outbox.table.fields.additional.placement": "topic:header,headers:header",
		"transforms.outbox.route.by.field":                    "topic",
		"transforms.outbox.route.topic.regex":                 "(.*)",
		"transforms.outbox.route.topic.replacement":           "$1",

		// Serialization
		"key.converter":                  "org.apache.kafka.connect.storage.StringConverter",
		"value.converter":                "org.apache.kafka.connect.json.JsonConverter",
		"value.converter.schemas.enable": "false",

		// Performance
		"max.batch.size":        "1000",
		"max.queue.size":        "10000",
		"poll.interval.ms":      "500",
		"snapshot.mode":         "never",
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
		return nil, fmt.Errorf("debezium: read config file %s: %w", path, err)
	}
	var raw struct {
		Config map[string]string `json:"config"`
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		// Try flat map.
		var flat map[string]string
		if err2 := json.Unmarshal(data, &flat); err2 != nil {
			return nil, fmt.Errorf("debezium: parse config file: %w", err)
		}
		return flat, nil
	}
	if raw.Config != nil {
		return raw.Config, nil
	}
	var flat map[string]string
	if err := json.Unmarshal(data, &flat); err != nil {
		return nil, fmt.Errorf("debezium: parse config file as flat map: %w", err)
	}
	return flat, nil
}
