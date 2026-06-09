# syntax=docker/dockerfile:1.7
# Multi-stage build for the wallet-service Go binary.

FROM --platform=$BUILDPLATFORM golang:1.26-alpine AS builder
WORKDIR /src

# Cache modules first
COPY go.mod go.sum* ./
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download

COPY . .
ARG VERSION=dev
# Predefined BuildKit platform args — MUST be declared with ARG to enter scope.
# Without these, ${TARGETARCH} is empty and falls back to amd64; the resulting
# x86-64 binary then runs under Rosetta emulation on arm64 hosts (Apple Silicon)
# and crashes with SIGSEGV in runtime.netpoll at startup.
ARG TARGETOS
ARG TARGETARCH
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=${TARGETOS:-linux} GOARCH=${TARGETARCH:-amd64} \
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
