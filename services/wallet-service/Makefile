SHELL := /bin/bash

BIN      ?= wallet-service
VERSION  ?= dev
PKG      := github.com/ewallet-pg/wallet-service

GOFLAGS  := -trimpath
LDFLAGS  := -s -w -X main.version=$(VERSION)

DB_DSN ?= postgres://wallet_app:wallet_app_dev@localhost:6432/wallet?sslmode=disable

.PHONY: help
help: ## Show available targets
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*## / {printf "  %-22s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

.PHONY: tidy
tidy: ## go mod tidy
	go mod tidy

.PHONY: build
build: ## build the binary
	CGO_ENABLED=0 go build $(GOFLAGS) -ldflags='$(LDFLAGS)' -o bin/$(BIN) ./cmd/server

.PHONY: run
run: ## run against local PgBouncer (port 6432)
	DB_DSN='$(DB_DSN)' \
	OTEL_ENABLED=false \
	GIN_MODE=debug \
	go run ./cmd/server

.PHONY: test
test: ## go test
	go test -race -count=1 ./...

.PHONY: lint
lint: ## golangci-lint (requires `brew install golangci-lint`)
	golangci-lint run ./...

.PHONY: vet
vet: ## go vet
	go vet ./...

.PHONY: docker-build
docker-build: ## Build the docker image
	docker build -t ewallet-pg/$(BIN):$(VERSION) .

.PHONY: smoke
smoke: ## Quick smoke test (requires running stack — wallet_schema.sql + wallet_sp.sql deployed)
	@echo "--- topup ---"; \
	curl -sS -X POST http://localhost:8080/v1/transactions/topup \
	  -H 'Content-Type: application/json' \
	  -H 'X-Caller-Subject: smoke_test' -H 'X-Channel: TREASURY' \
	  -d '{"acct_no":"9701000000000001","amount":"1000000","reference":"SMOKE-TOPUP-001"}' \
	  | jq .
