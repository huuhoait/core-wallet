// Package ops exposes the relay's operational HTTP endpoints (/metrics, /health,
// /config). It is a thin presentation adapter: it reads from a StatsProvider and
// renders JSON, holding no business logic.
package ops

import (
	"encoding/json"
	"fmt"
	"net/http"

	"github.com/rs/zerolog"
)

// StatsProvider is the read side of the metrics the server renders.
// Satisfied by *metrics.Metrics.
type StatsProvider interface {
	GetStats() map[string]any
}

// Info is the static configuration the /config and /health endpoints display.
type Info struct {
	Mode          string
	KafkaBrokers  []string
	BatchSize     int
	WorkerCount   int
	CDCEnabled    bool
	CDCConnectURL string
	CDCConnector  string
	CDCTopic      string
}

// Server renders the operational endpoints.
type Server struct {
	addr   string
	info   Info
	stats  StatsProvider
	logger *zerolog.Logger
}

// New builds the ops server bound to :port.
func New(port int, info Info, stats StatsProvider, logger *zerolog.Logger) *Server {
	return &Server{
		addr:   fmt.Sprintf(":%d", port),
		info:   info,
		stats:  stats,
		logger: logger,
	}
}

// ListenAndServe starts the server and blocks. Run it in a goroutine.
func (s *Server) ListenAndServe() error {
	mux := http.NewServeMux()
	mux.HandleFunc("/metrics", s.handleMetrics)
	mux.HandleFunc("/health", s.handleHealth)
	mux.HandleFunc("/config", s.handleConfig)

	s.logger.Info().Str("addr", s.addr).Msg("Starting metrics/health server")
	return http.ListenAndServe(s.addr, mux)
}

func (s *Server) handleMetrics(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(s.stats.GetStats()); err != nil {
		http.Error(w, "Internal server error", http.StatusInternalServerError)
	}
}

func (s *Server) handleHealth(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_, _ = fmt.Fprintf(w, `{"status":"healthy","mode":"%s"}`, s.info.Mode)
}

func (s *Server) handleConfig(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	info := map[string]any{
		"mode":          s.info.Mode,
		"kafka_brokers": s.info.KafkaBrokers,
		"batch_size":    s.info.BatchSize,
		"worker_count":  s.info.WorkerCount,
	}
	if s.info.CDCEnabled {
		info["cdc_connect_url"] = s.info.CDCConnectURL
		info["cdc_connector"] = s.info.CDCConnector
		info["cdc_topic"] = s.info.CDCTopic
	}
	if err := json.NewEncoder(w).Encode(info); err != nil {
		http.Error(w, "Internal server error", http.StatusInternalServerError)
	}
}
