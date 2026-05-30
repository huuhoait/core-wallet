# syntax=docker/dockerfile:1.7
# Multi-stage build for the wallet-service Go binary.

FROM golang:1.23-alpine AS builder
WORKDIR /src

# Cache modules first
COPY go.mod go.sum* ./
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download

COPY . .
ARG VERSION=dev
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH:-amd64} \
    go build \
      -trimpath \
      -ldflags="-s -w -X main.version=${VERSION}" \
      -o /out/wallet-service \
      ./cmd/server

FROM gcr.io/distroless/static-debian12:nonroot
WORKDIR /app
COPY --from=builder /out/wallet-service /app/wallet-service
USER nonroot:nonroot
EXPOSE 8080
HEALTHCHECK --interval=10s --timeout=3s --retries=3 \
  CMD ["/app/wallet-service", "-healthz"] || exit 1
ENTRYPOINT ["/app/wallet-service"]
