# Outbox Relay Service

## Overview

The Outbox Relay Service is a Go-based service that reliably publishes events from the `WLT_OUTBOX` table to Kafka. It serves as a **fallback mechanism** when Debezium CDC is unavailable or as the primary event delivery mechanism.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    PostgreSQL Database                     │
│  ┌──────────────────────────────────────────────────┐   │
│  │  WLT_OUTBOX (transactional outbox)                │   │
│  │  - event_uuid (PK)                                 │   │
│  │  - event_type                                     │   │
│  │  - payload (JSONB)                                │   │
│  │  - created_at                                     │   │
│  │  - processed_at (NULL = pending)                  │   │
│  └──────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
                            │
                            │ Poll (SKIP LOCKED)
                            ▼
┌─────────────────────────────────────────────────────────┐
│              Outbox Relay Service (Go)                    │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐   │
│  │  Worker 1    │  │  Worker 2    │  │  Worker N    │   │
│  │  (Polling)   │  │  (Polling)   │  │  (Polling)   │   │
│  └──────────────┘  └──────────────┘  └──────────────┘   │
│         │                 │                 │            │
│         └─────────────────┴─────────────────┘            │
│                           │                               │
│                    Kafka Producer                          │
└─────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────┐
│                    Kafka Cluster                          │
│  Topics: wallet.transactions, wallet.withdrawals, ...     │
└─────────────────────────────────────────────────────────┘
```

## Features

### 1. Concurrent Processing
- Multiple worker goroutines (configurable, default: 4)
- Each worker polls for pending events using `SELECT ... FOR UPDATE SKIP LOCKED`
- Ensures no duplicate processing across workers

### 2. Atomic Event Delivery
- Events are marked as processed only after successful Kafka publication
- Uses `processed_at` timestamp to track delivery status
- Retry count incremented on failure

### 3. Error Handling & Retry
- Automatic retry on Kafka publication failure
- Configurable max retries (default: 3)
- Exponential backoff for retries
- Dead letter queue for permanently failed events (TODO)

### 4. Monitoring & Metrics
- HTTP metrics endpoint at `/metrics`
- Health check endpoint at `/health`
- Tracks:
  - Events fetched/processed/failed
  - Kafka publish success/failure
  - Success rate
  - Uptime
  - Processing time

### 5. Graceful Shutdown
- Handles SIGINT and SIGTERM signals
- Completes in-flight processing before shutdown
- Closes database and Kafka connections properly

## Configuration

### Environment Variables

```bash
# Database
DB_HOST=localhost
DB_PORT=5432
DB_USER=wallet_app
DB_PASSWORD=your_password
DB_NAME=wallet

# Kafka
KAFKA_BROKERS=localhost:9092
KAFKA_TOPIC_PREFIX=wallet

# Worker
POLL_INTERVAL=1s
BATCH_SIZE=100
MAX_RETRIES=3
RETRY_DELAY=5s
WORKER_COUNT=4

# Monitoring
METRICS_PORT=9090

# Logging
LOG_LEVEL=info
```

### Configuration File (.env)

```env
DB_HOST=postgres
DB_PORT=5432
DB_USER=wallet_app
DB_PASSWORD=wallet_password
DB_NAME=wallet

KAFKA_BROKERS=kafka-1:9092,kafka-2:9092,kafka-3:9092
KAFKA_TOPIC_PREFIX=wallet

POLL_INTERVAL=1s
BATCH_SIZE=100
MAX_RETRIES=3
RETRY_DELAY=5s
WORKER_COUNT=4

METRICS_PORT=9090

LOG_LEVEL=info
```

## Database Schema

The service expects the following table structure:

```sql
CREATE TABLE public.wlt_outbox (
    id          BIGINT        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_uuid   UUID          NOT NULL UNIQUE,
    event_type   VARCHAR(64)   NOT NULL,
    payload     JSONB         NOT NULL,
    created_at   TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    processed_at TIMESTAMPTZ,
    retry_count  INT           NOT NULL DEFAULT 0
);

CREATE INDEX idx_outbox_processed ON public.wlt_outbox(processed_at) WHERE processed_at IS NULL;
CREATE INDEX idx_outbox_created ON public.wlt_outbox(created_at);
```

## Kafka Topics

Events are published to topics with the following naming convention:

```
{KAFKA_TOPIC_PREFIX}.{event_type}
```

Examples:
- `wallet.transactions.posted`
- `wallet.withdrawals.posted`
- `wallet.reversals.posted`

## Running the Service

### Build

```bash
cd services/outbox-relay
go mod tidy
go build -o bin/relay cmd/relay/main.go
```

### Run

```bash
# Using environment variables
export DB_HOST=localhost
export DB_PASSWORD=your_password
./bin/relay

# Or using .env file
cp .env.example .env
# Edit .env with your configuration
./bin/relay
```

### Docker

```bash
docker build -t outbox-relay .
docker run -p 9090:9090 --env-file .env outbox-relay
```

## Monitoring

### Health Check

```bash
curl http://localhost:9090/health
```

Response:
```json
{"status":"healthy"}
```

### Metrics

```bash
curl http://localhost:9090/metrics
```

Response:
```json
{
  "uptime_seconds": 3600,
  "events_fetched": 1000,
  "events_processed": 950,
  "events_failed": 50,
  "kafka_published": 950,
  "kafka_failed": 50,
  "errors": {
    "fetch_failed": 10,
    "process_failed": 40
  },
  "last_fetch_time": "2026-06-03T16:30:00Z",
  "last_process_time": "2026-06-03T16:30:05Z",
  "total_process_time_seconds": 300,
  "success_rate": 95.0
}
```

## Deployment

### Kubernetes

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: outbox-relay
spec:
  replicas: 2
  selector:
    matchLabels:
      app: outbox-relay
  template:
    metadata:
      labels:
        app: outbox-relay
    spec:
      containers:
      - name: relay
        image: outbox-relay:latest
        env:
        - name: DB_HOST
          valueFrom:
            secretKeyRef:
              name: postgres-secret
              key: host
        - name: DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: postgres-secret
              key: password
        - name: KAFKA_BROKERS
          value: "kafka-1:9092,kafka-2:9092,kafka-3:9092"
        ports:
        - containerPort: 9090
        livenessProbe:
          httpGet:
            path: /health
            port: 9090
          initialDelaySeconds: 10
          periodSeconds: 30
        readinessProbe:
          httpGet:
            path: /health
            port: 9090
          initialDelaySeconds: 5
          periodSeconds: 10
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 500m
            memory: 256Mi
---
apiVersion: v1
kind: Service
metadata:
  name: outbox-relay
spec:
  selector:
    app: outbox-relay
  ports:
  - port: 9090
    targetPort: 9090
```

### Docker Compose

```yaml
version: '3.8'

services:
  outbox-relay:
    build: ./services/outbox-relay
    ports:
      - "9090:9090"
    environment:
      - DB_HOST=postgres
      - DB_PORT=5432
      - DB_USER=wallet_app
      - DB_PASSWORD=wallet_password
      - DB_NAME=wallet
      - KAFKA_BROKERS=kafka-1:9092,kafka-2:9092,kafka-3:9092
      - KAFKA_TOPIC_PREFIX=wallet
      - WORKER_COUNT=4
      - LOG_LEVEL=info
    depends_on:
      - postgres
      - kafka
    restart: unless-stopped
```

## Performance Considerations

### Throughput

With default configuration (4 workers, batch size 100):
- **Expected throughput**: ~400 events/sec (4 workers × 100 events/batch × 1 poll/sec)
- **Latency**: < 100ms p99 for event delivery

### Scaling

To increase throughput:
1. Increase `WORKER_COUNT` (more concurrent workers)
2. Increase `BATCH_SIZE` (more events per batch)
3. Decrease `POLL_INTERVAL` (more frequent polling)

### Database Load

- Each worker maintains 2 DB connections (1 for polling, 1 for updates)
- With 4 workers: 8 concurrent connections
- `SELECT ... FOR UPDATE SKIP LOCKED` ensures no lock contention

### Kafka Load

- Synchronous producer ensures at-least-once delivery
- `acks=all` ensures durability
- Consider async producer for higher throughput (at cost of potential duplicates)

## Troubleshooting

### Events Not Being Processed

1. Check if events exist in `WLT_OUTBOX`:
   ```sql
   SELECT COUNT(*) FROM public.wlt_outbox WHERE processed_at IS NULL;
   ```

2. Check worker logs for errors:
   ```bash
   docker logs outbox-relay
   ```

3. Verify database connectivity:
   ```bash
   psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c "SELECT 1"
   ```

4. Verify Kafka connectivity:
   ```bash
   kafka-topics.sh --bootstrap-server $KAFKA_BROKERS --list
   ```

### High Error Rate

1. Check Kafka topic exists:
   ```bash
   kafka-topics.sh --bootstrap-server $KAFKA_BROKERS --topic wallet.transactions.posted --describe
   ```

2. Check Kafka broker health:
   ```bash
   kafka-broker-api-versions --bootstrap-server $KAFKA_BROKERS
   ```

3. Check database connection pool:
   - Monitor `pg_stat_activity` for connection leaks
   - Check `max_connections` setting

### Memory Issues

1. Reduce `BATCH_SIZE` if memory usage is high
2. Reduce `WORKER_COUNT` if CPU usage is high
3. Monitor metrics endpoint for memory leaks

## Debezium CDC Setup (Primary Mechanism)

### Overview

Debezium CDC is the **primary** mechanism for event delivery. The Go polling worker serves as a **fallback** when Debezium is unavailable.

### Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    PostgreSQL Database                     │
│  ┌──────────────────────────────────────────────────┐   │
│  │  WLT_OUTBOX (transactional outbox)                │   │
│  └──────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
                            │
                            │ WAL Log Streaming
                            ▼
┌─────────────────────────────────────────────────────────┐
│              Debezium Connect (CDC)                      │
│  - Captures WAL changes                                 │
│  - Emits events to Kafka                                │
│  - Low latency, high throughput                         │
└─────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────┐
│                    Kafka Cluster                          │
│  Topics: wallet.wlt_outbox.cdc                          │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│              Outbox Relay Service (Fallback)              │
│  - Polls WLT_OUTBOX using SKIP LOCKED                    │
│  - Only active when Debezium is down                     │
│  - Ensures no events are lost                           │
└─────────────────────────────────────────────────────────┘
```

### Debezium Configuration

Create a Debezium connector using the provided configuration:

```bash
# Register the connector
curl -X POST http://localhost:8083/connectors \
  -H "Content-Type: application/json" \
  -d @debezium/config.json
```

### Configuration Details

The `debezium/config.json` file includes:

- **Connector**: PostgreSQL CDC connector
- **Tables**: Only `public.wlt_outbox` (filtered)
- **Transforms**: 
  - `ExtractNewRecordState`: Unwrap Debezium envelope
  - `RegexRouter`: Route to `wallet.{table_name}.cdc`
- **Snapshot**: `schema_only` (no initial data dump)
- **Slot**: `wallet_outbox_slot` (logical replication slot)
- **Publication**: `wallet_outbox_publication` (filtered publication)

### Monitoring Debezium

```bash
# Check connector status
curl http://localhost:8083/connectors/wallet-outbox-connector/status

# Check connector metrics
curl http://localhost:8083/connectors/wallet-outbox-connector/metrics

# View connector configuration
curl http://localhost:8083/connectors/wallet-outbox-connector/config
```

### Fallback Strategy

When Debezium is unavailable:

1. **Detection**: Monitor Debezium connector health
2. **Activation**: Start Go polling worker
3. **Processing**: Worker polls `WLT_OUTBOX` using `SKIP LOCKED`
4. **Recovery**: When Debezium recovers, stop worker

### Testing Debezium

```bash
# Start test environment with Debezium
docker-compose -f docker-compose.test.yml up -d

# Register Debezium connector
curl -X POST http://localhost:8083/connectors \
  -H "Content-Type: application/json" \
  -d @debezium/config.json

# Insert test events
docker exec outbox-test-postgres psql -U wallet_app -d wallet \
  -c "SELECT public.insert_test_events(5, 'debezium.test');"

# Verify events in Kafka
docker exec outbox-test-kafka kafka-console-consumer \
  --bootstrap-server localhost:9092 \
  --topic wallet.wlt_outbox.cdc \
  --from-beginning \
  --max-messages 5
```

### Debezium vs Go Polling Worker

| Feature | Debezium CDC | Go Polling Worker |
|---------|--------------|-------------------|
| **Latency** | < 10ms | 100-500ms |
| **Throughput** | High (10k+ events/sec) | Medium (400 events/sec) |
| **Resource Usage** | Low | Medium |
| **Complexity** | High (requires Kafka Connect) | Low |
| **Reliability** | High (WAL-based) | High (SKIP LOCKED) |
| **Role** | Primary | Fallback |

## Integration Testing

### Run Integration Tests

```bash
# Make test script executable
chmod +x scripts/integration-test.sh

# Run tests
./scripts/integration-test.sh
```

### Test Coverage

The integration test script covers:
1. Service startup and health checks
2. Event processing from `WLT_OUTBOX` to Kafka
3. No duplicate processing verification
4. Retry mechanism testing
5. Kafka failure simulation
6. Metrics verification

### Manual Testing

```bash
# Start test environment
docker-compose -f docker-compose.test.yml up -d

# Check logs
docker-compose -f docker-compose.test.yml logs -f outbox-relay

# Insert test events
docker exec outbox-test-postgres psql -U wallet_app -d wallet \
  -c "SELECT public.insert_test_events(10, 'manual.test');"

# Check metrics
curl http://localhost:9090/metrics | jq '.'

# Check Kafka topics
docker exec outbox-test-kafka kafka-topics --bootstrap-server localhost:9092 --list

# Consume events
docker exec outbox-test-kafka kafka-console-consumer \
  --bootstrap-server localhost:9092 \
  --topic wallet.manual.test \
  --from-beginning \
  --max-messages 10

# Cleanup
docker-compose -f docker-compose.test.yml down -v
```

## Future Enhancements

- [ ] Add dead letter queue for permanently failed events
- [ ] Implement circuit breaker for Kafka
- [ ] Add support for event filtering by type
- [ ] Implement batch Kafka publishing (for higher throughput)
- [ ] Add Prometheus metrics export
- [ ] Add distributed tracing (OpenTelemetry)
- [ ] Implement event replay functionality
- [ ] Add support for event prioritization
- [ ] Implement automatic Debezium health monitoring
- [ ] Add seamless failover between Debezium and polling worker

## References

- [HLD §6.3 - Withdraw Flow](../../docs/hld/wallet_HLD.md#63-withdraw-sync-internal---handoff-to-treasury-with-disbursement-tracking)
- [DLD §2.11 - WLT_OUTBOX](../../docs/dld/wallet_DLD.md#211-wlt_outbox-transactional-outbox)
- [Debezium Documentation](https://debezium.io/documentation/)
- [Sarama Documentation](https://pkg.go.dev/github.com/IBM/sarama)
- [PostgreSQL SKIP LOCKED](https://www.postgresql.org/docs/current/sql-select.html#SQL-FOR-UPDATE-SHARE-SKIP-LOCKED)

## License

Copyright © 2026 Core Wallet Team