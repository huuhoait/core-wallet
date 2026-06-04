# Production — Single AZ Deployment

> Production environment running in a **single Availability Zone**.
> Optimized for cost while maintaining high availability within the zone.

## Architecture

```
┌─── Single Availability Zone ────────────────────────────────────────────┐
│                                                                          │
│  ┌─── Ingress (nginx + TLS) ─────────────────────────────────────────┐  │
│  │  wallet-api.prod.local → :8080                                     │  │
│  └────────────────────────────────┬───────────────────────────────────┘  │
│                                   │                                      │
│  ┌─── wallet-service (3–8 pods) ──┼──────────────────────────────────┐  │
│  │                                ▼                                   │  │
│  │  ┌──────────────────┐   ┌──────────────────┐                     │  │
│  │  │ wallet-service   │   │ PgBouncer sidecar│                     │  │
│  │  │ (Go, 500m–2 CPU) │──▶│ (tx pooling)     │                     │  │
│  │  │ HPA: CPU 65%     │   │ 16 server conns  │                     │  │
│  │  └──────────────────┘   └────────┬─────────┘                     │  │
│  │                                   │                                │  │
│  │  ┌──────────────────┐            │         ┌──────────────────┐  │  │
│  │  │ Pod 2            │            │         │ Pod 3            │  │  │
│  │  │ (same layout)    │            │         │ (same layout)    │  │  │
│  │  └──────────────────┘            │         └──────────────────┘  │  │
│  └───────────────────────────────────┼────────────────────────────────┘  │
│                                      │ localhost:6432 → :5432            │
│  ┌─── PostgreSQL 17 (StatefulSet) ───┼────────────────────────────────┐  │
│  │                                   ▼                                │  │
│  │  ┌──────────────────────────────────────────────────────────────┐ │  │
│  │  │  pg-primary-0 (8 vCPU, 32 GB, 500 GB NVMe)                   │ │  │
│  │  │                                                               │ │  │
│  │  │  • shared_buffers = 8 GB                                      │ │  │
│  │  │  • max_connections = 300                                      │ │  │
│  │  │  • WAL: 2–8 GB, checkpoint 15 min                            │ │  │
│  │  │  • Autovacuum: aggressive (4 workers, scale 0.02)            │ │  │
│  │  │  • pg_stat_statements + track_io_timing                       │ │  │
│  │  │  • pg_exporter sidecar → Prometheus                          │ │  │
│  │  └──────────────────────────────────────────────────────────────┘ │  │
│  │                                                                    │  │
│  │  Storage: PVC 500 GB (StorageClass: fast-ssd)                     │  │
│  └────────────────────────────────────────────────────────────────────┘  │
│                                                                          │
│  ┌─── Observability ─────────────────────────────────────────────────┐  │
│  │  OTel Collector → Tempo (traces) + Prometheus (metrics) + Loki    │  │
│  │  Grafana (dashboards + alerting)                                   │  │
│  └────────────────────────────────────────────────────────────────────┘  │
│                                                                          │
│  ┌─── Vault (secrets) ───────────────────────────────────────────────┐  │
│  │  KV v2 → VSO → K8s Secrets (auto-sync, 1h refresh)               │  │
│  └────────────────────────────────────────────────────────────────────┘  │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

## Sizing (targets 2,000 TPS sustained)

| Component | Spec | Notes |
|-----------|------|-------|
| **wallet-service** | 3–8 pods, 500m–2 CPU, 512 MB–1 GB | HPA on CPU 65% |
| **PgBouncer** | Sidecar per pod, 16 conns/pool | 3 pods × 16 = 48 server conns |
| **PostgreSQL** | 1 pod, 8 vCPU, 32 GB, 500 GB NVMe | Tuned for wallet OLTP |
| **Node(s)** | 2–3 × (16 vCPU, 64 GB) or 1 dedicated DB node + 2 app nodes |

## Deploy

```bash
# 1. Deploy Vault + Observability (one-time)
kubectl apply -k deploy/k8s/base/vault
kubectl apply -k deploy/k8s/base/observability

# 2. Initialize Vault (one-time)
bash deploy/k8s/base/vault/setup-vault.sh

# 3. Deploy wallet stack (DB + service)
kubectl apply -k deploy/k8s/overlays/production-1az

# 4. Load schema (first time only)
kubectl -n wallet exec -it pg-primary-0 -- bash -c '
  PGPASSWORD=$POSTGRES_PASSWORD psql -U postgres -d wallet \
    -f /path/to/schema.sql \
    -f /path/to/partitions.sql \
    -f /path/to/seed.sql
'
# Or copy files in:
kubectl cp db/export/schema.sql wallet/pg-primary-0:/tmp/schema.sql
kubectl -n wallet exec pg-primary-0 -- \
  psql -U postgres -d wallet -f /tmp/schema.sql

# 5. Verify
kubectl -n wallet get pods
kubectl -n wallet logs -l app.kubernetes.io/name=wallet-service --tail=20
curl -k https://wallet-api.prod.local/healthz
```

## Single-AZ Trade-offs

| ✅ Advantages | ⚠️ Trade-offs |
|:---|:---|
| Lower cost (no cross-AZ transfer) | Full outage if AZ goes down |
| Lower latency (no cross-AZ hop) | No geographic redundancy |
| Simpler networking | DB backup to off-site is critical |
| PgBouncer sidecar = 0 network hop | |

## Backup Strategy (critical for single-AZ)

Since there's no multi-AZ standby, backups are essential:

```bash
# Daily pg_basebackup to off-site (cron job or K8s CronJob)
kubectl -n wallet exec pg-primary-0 -- \
  pg_basebackup -D /tmp/backup -Ft -z -P -U postgres

# WAL archiving to S3/MinIO (continuous)
# Add to postgresql.conf:
#   archive_mode = on
#   archive_command = '... copy to S3/MinIO ...'
```

| Backup type | Frequency | Retention | Target |
|:---|:---|:---|:---|
| pg_basebackup (full) | Daily 02:00 | 7 days | S3 / NFS / off-site |
| WAL archive (continuous) | Realtime | 72 hours | S3 / MinIO |
| pg_dump (logical) | Weekly | 30 days | S3 / cold storage |

## Upgrade to Multi-AZ

When ready to move to multi-AZ HA:

1. Add a streaming replica in a second AZ
2. Re-enable `topologySpreadConstraints` in the deployment
3. Use CloudNativePG operator for automatic failover
4. Switch PgBouncer to point to a virtual IP / DNS managed by the operator
