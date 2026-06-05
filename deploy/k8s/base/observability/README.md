# Observability Stack — Core Wallet

> Unified monitoring for both AWS EKS and on-premise Kubernetes.
> Same manifests, same dashboards, same alerts — zero platform divergence.

## Architecture

```
┌─── wallet-service Pods ─────────────────────────────────────────────────┐
│  Go app emits:                                                           │
│    • OTel traces (OTLP gRPC :4317)                                      │
│    • Structured JSON logs (stdout → Loki via OTel)                       │
│    • Prometheus metrics (/metrics, scraped)                              │
└────────────────────┬────────────────────────────────────────────────────┘
                     │
                     ▼
┌─── OTel Collector (observability namespace) ────────────────────────────┐
│                                                                          │
│  Receivers:  OTLP (gRPC :4317, HTTP :4318)                              │
│  Processors: batch, memory_limiter, resource                            │
│  Exporters:                                                              │
│    traces  → Tempo :4317                                                │
│    metrics → Prometheus (remote write :9090)                            │
│    logs    → Loki :3100                                                 │
│                                                                          │
└───┬──────────────────────┬──────────────────────┬───────────────────────┘
    │                      │                      │
    ▼                      ▼                      ▼
┌────────┐         ┌──────────────┐       ┌──────────┐
│ Tempo  │         │  Prometheus  │       │   Loki   │
│ (trace │         │  (metrics +  │       │  (logs)  │
│  store)│         │   alerting)  │       │          │
└───┬────┘         └──────┬───────┘       └─────┬────┘
    │                      │                     │
    └──────────────────────┼─────────────────────┘
                           ▼
                    ┌──────────────┐
                    │   Grafana    │
                    │  (unified    │
                    │   dashboard) │
                    │              │
                    │  Datasources:│
                    │  • Prometheus│
                    │  • Tempo     │
                    │  • Loki      │
                    └──────────────┘
```

## Components

| Component | Image | Purpose | Retention |
|-----------|-------|---------|-----------|
| OTel Collector | `otel/opentelemetry-collector-contrib:0.96.0` | Receive, process, route telemetry | — |
| Tempo | `grafana/tempo:2.4.1` | Distributed trace storage | 3 days |
| Prometheus | `prom/prometheus:v2.51.2` | Metrics + alerting rules | 15 days |
| Loki | `grafana/loki:2.9.6` | Log aggregation | 30 days |
| Grafana | `grafana/grafana:10.4.2` | Visualization + exploration | — |

## Deploy

```bash
# Deploy observability stack
kubectl apply -k deploy/k8s/base/observability

# Verify
kubectl -n observability get pods
kubectl -n observability port-forward svc/grafana 3000:3000
# Open http://localhost:3000 (admin / see grafana-admin secret)
```

## Grafana Features

- **Metrics → Traces**: Click a spike in the latency graph → jump to exemplar traces in Tempo
- **Traces → Logs**: Select a trace span → see correlated logs in Loki (by `trace_id`)
- **Service Map**: Auto-generated topology from Tempo span-metrics
- **Alerting**: Prometheus alert rules fire → Grafana shows in unified alert view

## Alert Rules (built-in)

| Alert | Severity | Condition |
|-------|----------|-----------|
| `BatchUnbalanced` | Critical (P1) | ΣDR ≠ ΣCR — double-entry violation |
| `HighErrorRate` | High (P2) | 5xx > 0.5% for 2 minutes |
| `TimeoutSpike` | High (P2) | >50 timeouts in 5 minutes |
| `HighLockContention` | Medium (P3) | VERSION_CONFLICT > 5% |
| `PodCrashLooping` | Medium (P3) | >3 restarts in 15 minutes |
| `PgBouncerPoolNearFull` | High (P2) | Pool > 85% utilized |
| `ReplicationLagHigh` | Medium (P3) | Replica lag > 5 seconds |

## Works on Both Platforms

| Concern | AWS EKS | On-Premise |
|---------|---------|------------|
| Storage | EBS gp3 (dynamic PVC) | Local NVMe / Ceph (StorageClass) |
| Ingress to Grafana | ALB + ACM cert | nginx-ingress + cert-manager |
| Alert routing | SNS / PagerDuty | Alertmanager → Slack / webhook |
| Long-term storage | S3 (Tempo/Loki backend) | MinIO / NFS |

For production at scale, consider:
- Tempo: switch from `local` to `s3` backend
- Loki: switch from filesystem to `s3`/`gcs` store
- Prometheus: add Thanos sidecar for long-term + HA
