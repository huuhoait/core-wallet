# Outbox Relay — Core Wallet

> Publishes transactional outbox events (`WLT_OUTBOX`) to Kafka.
> Two relay modes switchable via `RELAY_MODE` config:
> **polling** (simple, no extra infra) or **CDC** (Debezium, low-latency).

## Architecture

```
┌─── wallet-service ──────────────────────────────────────────────────────┐
│  Posting SP → INSERT INTO WLT_OUTBOX (atomic, same TX as ledger write)  │
└─────────────────────────────────────┬───────────────────────────────────┘
                                      │
                    ┌─────────────────┼─────────────────┐
                    │                 │                  │
                    ▼                 ▼                  ▼
        ┌─── RELAY_MODE=polling ───┐     ┌─── RELAY_MODE=cdc ──────────────┐
        │                          │     │                                  │
        │  Go Workers (N parallel) │     │  PostgreSQL WAL                  │
        │  poll WLT_OUTBOX         │     │        │                         │
        │  FOR UPDATE SKIP LOCKED  │     │        ▼                         │
        │        │                 │     │  Debezium (Kafka Connect)        │
        │        ▼                 │     │  pgoutput → EventRouter          │
        │  Kafka SyncProducer      │     │        │                         │
        │  (ack=all, idempotent)   │     │        ▼                         │
        │        │                 │     │  Destination Kafka Topics         │
        │        ▼                 │     │        │                         │
        │  Mark SENT (partition/   │     │        ▼                         │
        │  offset stamped)         │     │  CDC Consumer (Go)               │
        │                          │     │  → marks WLT_OUTBOX SENT         │
        └──────────────────────────┘     └──────────────────────────────────┘
```

## Mode Comparison

| Aspect | Polling | CDC (Debezium) |
|--------|---------|----------------|
| **Latency** | `POLL_INTERVAL` (default 1s) | Sub-second (WAL streaming) |
| **Infrastructure** | Go binary + PG + Kafka | + Kafka Connect cluster |
| **Complexity** | Low | Medium (connector lifecycle) |
| **Exactly-once** | At-least-once (idempotent producer) | At-least-once (same) |
| **DB load** | Polling queries (SKIP LOCKED) | Zero (WAL read, no table query) |
| **Failure recovery** | Re-polls FAILED rows | Connector resumes from LSN |
| **Scaling** | N workers (horizontal) | Kafka Connect tasks (horizontal) |
| **Best for** | < 1,000 events/sec | > 1,000 events/sec, low-latency |

## Quick Start

### Polling mode (default)

```bash
cp .env.example .env
# Ensure RELAY_MODE=polling (or unset — it's the default)
make run
```

### CDC mode

```bash
# 1. Start Kafka Connect (Debezium)
docker compose -f ../../docker-compose.yml \
  -f docker-compose.cdc.yml --profile relay up -d

# 2. Set RELAY_MODE=cdc in .env
echo "RELAY_MODE=cdc" >> .env

# 3. Run the relay (it auto-registers the Debezium connector)
make run
```

Or via docker compose directly:

```bash
docker compose -f ../../docker-compose.yml \
  -f docker-compose.cdc.yml --profile relay up -d
```

## Configuration

| Variable | Default | Mode | Description |
|----------|---------|------|-------------|
| `RELAY_MODE` | `polling` | Both | `polling` or `cdc` |
| `DB_HOST` | `localhost` | Both | PostgreSQL host |
| `DB_PORT` | `5432` | Both | PostgreSQL port |
| `DB_USER` | `wallet_app` | Both | PostgreSQL user |
| `DB_PASSWORD` | | Both | PostgreSQL password |
| `DB_NAME` | `wallet` | Both | Database name |
| `KAFKA_BROKERS` | `localhost:9092` | Both | Kafka broker list |
| `KAFKA_TOPIC_PREFIX` | `wallet` | Both | Topic prefix |
| `POLL_INTERVAL` | `1s` | Polling | How often to poll |
| `BATCH_SIZE` | `100` | Polling | Rows per poll cycle |
| `MAX_RETRIES` | `3` | Polling | Retries before DEAD |
| `WORKER_COUNT` | `4` | Polling | Parallel workers |
| `CDC_CONNECT_URL` | `http://kafka-connect:8083` | CDC | Kafka Connect REST |
| `CDC_CONNECTOR_NAME` | `wallet-outbox-connector` | CDC | Connector name |
| `CDC_TOPIC` | `wallet.public.wlt_outbox` | CDC | CDC change topic |
| `CDC_CONSUMER_GROUP` | `outbox-relay-cdc` | CDC | Consumer group |
| `CDC_SLOT_NAME` | `wallet_outbox_slot` | CDC | PG replication slot |
| `CDC_PUBLICATION_NAME` | `wallet_outbox_publication` | CDC | PG publication |
| `CDC_AUTO_REGISTER` | `true` | CDC | Auto-register connector |
| `CDC_CONNECTOR_CONFIG` | | CDC | Path to custom config JSON |
| `METRICS_PORT` | `9090` | Both | Metrics/health HTTP port |

## How CDC Mode Works

1. **Startup**: the relay registers (or updates) a Debezium connector via the Kafka Connect REST API
2. **Debezium** captures `INSERT` events on `WLT_OUTBOX` from the PostgreSQL WAL (logical replication)
3. **EventRouter transform** routes each event to its `topic` column value (the final destination topic)
4. **CDC Consumer** (in the relay Go binary) consumes the raw CDC topic to update `WLT_OUTBOX.status = 'SENT'`
5. **Health monitor** periodically checks connector status; auto-resumes if paused

### Debezium EventRouter

The key configuration is the [Outbox Event Router](https://debezium.io/documentation/reference/transformations/outbox-event-router.html):

```
WLT_OUTBOX row:
  event_uuid = "abc-123"
  topic = "wallet.withdraw.posted"     ← destination topic
  partition_key = "9701000000001"       ← Kafka message key
  payload = {"acct_no": "...", ...}     ← Kafka message value
  event_type = "WITHDRAW_POSTED"        ← header

Debezium EventRouter routes to:
  Topic: wallet.withdraw.posted
  Key: 9701000000001
  Value: {"acct_no": "...", ...}
  Headers: {eventType: WITHDRAW_POSTED, topic: wallet.withdraw.posted}
```

## PostgreSQL Setup (CDC mode)

CDC requires logical replication to be enabled:

```sql
-- postgresql.conf (already set in the project's pg config)
wal_level = replica        -- or 'logical' (replica includes logical)
max_replication_slots = 5
max_wal_senders = 5

-- Create the publication (Debezium can auto-create, but explicit is safer)
CREATE PUBLICATION wallet_outbox_publication FOR TABLE wlt_outbox;
```

## Switching Modes at Runtime

Modes are **mutually exclusive** — run ONE at a time. To switch:

```bash
# From polling → CDC:
#   1. Stop the polling relay
#   2. Set RELAY_MODE=cdc
#   3. Start the relay (it picks up where polling left off — PENDING rows)
#   4. Debezium streams only NEW inserts (snapshot.mode=never)
#   5. Any remaining PENDING rows from polling era → re-poll fallback worker (TODO)

# From CDC → polling:
#   1. Stop the CDC relay
#   2. Pause/delete the Debezium connector (avoids WAL bloat)
#   3. Set RELAY_MODE=polling
#   4. Start the relay (polls all PENDING/FAILED rows)
```

## Endpoints

| Path | Method | Description |
|------|--------|-------------|
| `/health` | GET | Liveness + current mode |
| `/metrics` | GET | JSON metrics (events processed, errors, latency) |
| `/config` | GET | Current runtime configuration (sanitized) |

## Development

```bash
make build     # build binary
make run       # run locally
make test      # go test
make lint      # golangci-lint
```
