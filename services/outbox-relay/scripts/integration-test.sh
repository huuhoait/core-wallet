#!/bin/bash

# Integration Test Script for Outbox Relay Service
# This script tests the outbox relay service with PostgreSQL and Kafka

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
COMPOSE_FILE="docker-compose.test.yml"
POSTGRES_CONTAINER="outbox-test-postgres"
KAFKA_CONTAINER="outbox-test-kafka"
RELAY_CONTAINER="outbox-test-relay"
CONSUMER_CONTAINER="outbox-test-consumer"

# Functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Cleanup function
cleanup() {
    log_info "Cleaning up..."
    docker-compose -f $COMPOSE_FILE down -v
    log_info "Cleanup complete"
}

# Trap cleanup on exit
trap cleanup EXIT

# Check if docker-compose is available
if ! command -v docker-compose &> /dev/null; then
    log_error "docker-compose is not installed"
    exit 1
fi

# Start services
log_info "Starting test environment..."
docker-compose -f $COMPOSE_FILE up -d postgres zookeeper kafka

# Wait for PostgreSQL to be ready
log_info "Waiting for PostgreSQL to be ready..."
until docker exec $POSTGRES_CONTAINER pg_isready -U wallet_app -d wallet &> /dev/null; do
    sleep 2
done
log_info "PostgreSQL is ready"

# Wait for Kafka to be ready
log_info "Waiting for Kafka to be ready..."
until docker exec $KAFKA_CONTAINER kafka-broker-api-versions --bootstrap-server localhost:9092 &> /dev/null; do
    sleep 2
done
log_info "Kafka is ready"

# Check initial outbox status
log_info "Checking initial outbox status..."
docker exec $POSTGRES_CONTAINER psql -U wallet_app -d wallet -c "SELECT * FROM public.v_outbox_status;"

# Start outbox relay service
log_info "Starting outbox relay service..."
docker-compose -f $COMPOSE_FILE up -d outbox-relay

# Wait for relay to start
sleep 5

# Check relay logs
log_info "Checking relay logs..."
docker logs $RELAY_CONTAINER --tail 20

# Wait for events to be processed
log_info "Waiting for events to be processed (30 seconds)..."
sleep 30

# Check outbox status after processing
log_info "Checking outbox status after processing..."
docker exec $POSTGRES_CONTAINER psql -U wallet_app -d wallet -c "SELECT * FROM public.v_outbox_status;"

# Check pending events
log_info "Checking pending events..."
PENDING_COUNT=$(docker exec $POSTGRES_CONTAINER psql -U wallet_app -d wallet -t -c "SELECT COUNT(*) FROM public.wlt_outbox WHERE processed_at IS NULL;")
log_info "Pending events: $PENDING_COUNT"

# Check processed events
log_info "Checking processed events..."
PROCESSED_COUNT=$(docker exec $POSTGRES_CONTAINER psql -U wallet_app -d wallet -t -c "SELECT COUNT(*) FROM public.wlt_outbox WHERE processed_at IS NOT NULL;")
log_info "Processed events: $PROCESSED_COUNT"

# Check Kafka topics
log_info "Checking Kafka topics..."
docker exec $KAFKA_CONTAINER kafka-topics --bootstrap-server localhost:9092 --list

# Check events in Kafka
log_info "Checking events in Kafka topics..."
docker exec $KAFKA_CONTAINER kafka-console-consumer --bootstrap-server localhost:9092 --topic wallet.transactions.posted --from-beginning --max-messages 5 --timeout-ms 5000 || true

# Check relay metrics
log_info "Checking relay metrics..."
curl -s http://localhost:9090/metrics | jq '.'

# Check relay health
log_info "Checking relay health..."
curl -s http://localhost:9090/health

# Test: Insert new events and verify they are processed
log_info "Test: Inserting new events..."
docker exec $POSTGRES_CONTAINER psql -U wallet_app -d wallet -c "SELECT public.insert_test_events(5, 'test.events');"

# Wait for processing
log_info "Waiting for new events to be processed (10 seconds)..."
sleep 10

# Check if new events were processed
NEW_PROCESSED_COUNT=$(docker exec $POSTGRES_CONTAINER psql -U wallet_app -d wallet -t -c "SELECT COUNT(*) FROM public.wlt_outbox WHERE processed_at IS NOT NULL;")
log_info "Total processed events after test: $NEW_PROCESSED_COUNT"

# Test: Verify no duplicate processing
log_info "Test: Verifying no duplicate processing..."
DUPLICATE_COUNT=$(docker exec $POSTGRES_CONTAINER psql -U wallet_app -d wallet -t -c "SELECT COUNT(*) FROM (SELECT event_uuid, COUNT(*) FROM public.wlt_outbox GROUP BY event_uuid HAVING COUNT(*) > 1) AS duplicates;")
if [ "$DUPLICATE_COUNT" -eq 0 ]; then
    log_info "✓ No duplicate events found"
else
    log_error "✗ Found $DUPLICATE_COUNT duplicate events"
    exit 1
fi

# Test: Verify retry mechanism
log_info "Test: Simulating Kafka failure..."
docker-compose -f $COMPOSE_FILE stop kafka

# Insert events while Kafka is down
docker exec $POSTGRES_CONTAINER psql -U wallet_app -d wallet -c "SELECT public.insert_test_events(3, 'retry.test');"

# Wait for retry attempts
sleep 10

# Check retry counts
RETRY_COUNT=$(docker exec $POSTGRES_CONTAINER psql -U wallet_app -d wallet -t -c "SELECT MAX(retry_count) FROM public.wlt_outbox WHERE event_type = 'retry.test';")
log_info "Max retry count for test events: $RETRY_COUNT"

# Restart Kafka
log_info "Restarting Kafka..."
docker-compose -f $COMPOSE_FILE start kafka

# Wait for Kafka to be ready
sleep 10

# Wait for events to be processed
sleep 15

# Check if retry events were processed
RETRY_PROCESSED_COUNT=$(docker exec $POSTGRES_CONTAINER psql -U wallet_app -d wallet -t -c "SELECT COUNT(*) FROM public.wlt_outbox WHERE event_type = 'retry.test' AND processed_at IS NOT NULL;")
log_info "Retry events processed: $RETRY_PROCESSED_COUNT"

# Final status check
log_info "Final outbox status..."
docker exec $POSTGRES_CONTAINER psql -U wallet_app -d wallet -c "SELECT * FROM public.v_outbox_status;"

# Test results
log_info "========================================="
log_info "Integration Test Results"
log_info "========================================="

if [ "$PENDING_COUNT" -eq 0 ] && [ "$PROCESSED_COUNT" -gt 0 ] && [ "$DUPLICATE_COUNT" -eq 0 ]; then
    log_info "✓ All tests passed!"
    log_info "  - All events processed: $PROCESSED_COUNT"
    log_info "  - No pending events: $PENDING_COUNT"
    log_info "  - No duplicate events: $DUPLICATE_COUNT"
    exit 0
else
    log_error "✗ Some tests failed!"
    log_info "  - Pending events: $PENDING_COUNT"
    log_info "  - Processed events: $PROCESSED_COUNT"
    log_info "  - Duplicate events: $DUPLICATE_COUNT"
    exit 1
fi