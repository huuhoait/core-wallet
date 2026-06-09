.PHONY: build run test clean docker-build docker-run deps fmt lint

# Variables
APP_NAME=outbox-relay
BINARY_NAME=relay
BUILD_DIR=bin
DOCKER_IMAGE=$(APP_NAME):latest
DOCKER_REGISTRY=your-registry.com

# Build
build:
	@echo "Building $(APP_NAME)..."
	@mkdir -p $(BUILD_DIR)
	@go build -o $(BUILD_DIR)/$(BINARY_NAME) ./cmd/relay
	@echo "Build complete: $(BUILD_DIR)/$(BINARY_NAME)"

# Run
run:
	@echo "Running $(APP_NAME)..."
	@go run ./cmd/relay/main.go

# Test
test:
	@echo "Running tests..."
	@go test -v ./...

# Clean
clean:
	@echo "Cleaning..."
	@rm -rf $(BUILD_DIR)
	@go clean
	@echo "Clean complete"

# Dependencies
deps:
	@echo "Installing dependencies..."
	@go mod download
	@go mod tidy
	@echo "Dependencies installed"

# Format
fmt:
	@echo "Formatting code..."
	@go fmt ./...
	@echo "Code formatted"

# Lint
lint:
	@echo "Linting code..."
	@golangci-lint run ./...
	@echo "Linting complete"

# Docker build
docker-build:
	@echo "Building Docker image..."
	@docker build -f Dockerfile -t $(DOCKER_IMAGE) ..
	@echo "Docker image built: $(DOCKER_IMAGE)"

# Docker run
docker-run:
	@echo "Running Docker container..."
	@docker run -p 9090:9090 --env-file .env $(DOCKER_IMAGE)

# Docker push
docker-push:
	@echo "Pushing Docker image..."
	@docker tag $(DOCKER_IMAGE) $(DOCKER_REGISTRY)/$(DOCKER_IMAGE)
	@docker push $(DOCKER_REGISTRY)/$(DOCKER_IMAGE)
	@echo "Docker image pushed"

# All
all: clean deps fmt lint build test
	@echo "All tasks completed successfully"