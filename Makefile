# Convenience targets for OFE development.
#
# Day-to-day:
#   make build       — build the ofe CLI into ./bin/ofe
#   make test        — run unit tests with the race detector
#   make lint        — run golangci-lint with the repo config
#   make fmt         — gofmt + goimports (the same checks CI runs)
#   make ci          — fmt + lint + test + build (run before pushing)
#   make clean       — remove build artifacts
#
# Release maintainer:
#   make release-snapshot  — run goreleaser locally to validate the config

BIN_DIR := bin
BIN     := $(BIN_DIR)/ofe

GO_FILES := $(shell find . -name '*.go' -not -path './.claude/*')

VERSION ?= dev
COMMIT  := $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
DATE    := $(shell date -u +%Y-%m-%dT%H:%M:%SZ)

LDFLAGS := -s -w \
	-X github.com/sdebruyn/onelake-explorer-macos/internal/buildinfo.Version=$(VERSION) \
	-X github.com/sdebruyn/onelake-explorer-macos/internal/buildinfo.Commit=$(COMMIT) \
	-X github.com/sdebruyn/onelake-explorer-macos/internal/buildinfo.Date=$(DATE)

.PHONY: all build test lint fmt vet tidy ci clean smoke release-snapshot help

all: ci

$(BIN): $(GO_FILES) go.mod go.sum
	@mkdir -p $(BIN_DIR)
	go build -ldflags '$(LDFLAGS)' -o $(BIN) ./cmd/ofe

build: $(BIN)

test:
	go test -race -coverprofile=coverage.out -covermode=atomic ./...

lint:
	golangci-lint run --config .golangci.yml ./...

fmt:
	gofmt -w .
	@if command -v goimports >/dev/null 2>&1; then \
		goimports -w -local github.com/sdebruyn/onelake-explorer-macos .; \
	else \
		echo "goimports not installed; run 'go install golang.org/x/tools/cmd/goimports@latest'"; \
	fi

vet:
	go vet ./...

tidy:
	go mod tidy

smoke: build
	@$(BIN) --version
	@$(BIN) status

ci: tidy fmt vet lint test build smoke

clean:
	rm -rf $(BIN_DIR) build dist coverage.out

release-snapshot:
	goreleaser release --snapshot --clean

help:
	@echo "Targets:"
	@awk -F':.*##' '/^[a-zA-Z_-]+:.*##/ { printf "  %-18s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
