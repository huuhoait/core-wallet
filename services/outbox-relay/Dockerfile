# Build stage. Build context is ./services (parent of this service and the
# shared module it replaces via `replace => ../shared`).
FROM golang:1.26-alpine AS builder

WORKDIR /src

# Install dependencies
RUN apk add --no-cache git ca-certificates tzdata

# Cache modules first: the relay module plus the shared module's go.mod.
COPY outbox-relay/go.mod outbox-relay/go.sum ./outbox-relay/
COPY shared/go.mod shared/go.sum* ./shared/
WORKDIR /src/outbox-relay
RUN go mod download

# Copy both module sources (shared beside the service so `../shared` resolves).
WORKDIR /src
COPY shared/ ./shared/
COPY outbox-relay/ ./outbox-relay/
WORKDIR /src/outbox-relay

# Build the application
RUN CGO_ENABLED=0 GOOS=linux go build -a -installsuffix cgo -o bin/relay ./cmd/relay

# Final stage
FROM alpine:latest

RUN apk --no-cache add ca-certificates tzdata

WORKDIR /root/

# Copy binary from builder
COPY --from=builder /src/outbox-relay/bin/relay .

# Copy .env.example
COPY --from=builder /src/outbox-relay/.env.example .

# Expose metrics port
EXPOSE 9090

# Run the application
CMD ["./relay"]