# Convenience targets for OFEM development.
#
# Day-to-day:
#   make build       — build the ofem CLI into ./bin/ofem
#   make test        — run unit tests with the race detector
#   make lint        — run golangci-lint with the repo config
#   make fmt         — gofmt + goimports (mutates files in place)
#   make fmt-check   — read-only gofmt check (fails on unformatted files)
#   make ci          — fmt-check + lint + test + build (run before pushing)
#   make clean       — remove build artifacts
#
# Note: `make ci` deliberately uses fmt-check (read-only) so it matches
# what GitHub Actions does. Use `make fmt` to actually rewrite files.
#
# Release maintainer:
#   make release-snapshot  — run goreleaser locally to validate the config

BIN_DIR := bin
BIN     := $(BIN_DIR)/ofem

GO_FILES := $(shell find . -name '*.go' -not -path './.claude/*')

VERSION ?= dev
COMMIT  := $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
DATE    := $(shell date -u +%Y-%m-%dT%H:%M:%SZ)

LDFLAGS := -s -w \
	-X github.com/sdebruyn/onelake-explorer-macos/internal/buildinfo.Version=$(VERSION) \
	-X github.com/sdebruyn/onelake-explorer-macos/internal/buildinfo.Commit=$(COMMIT) \
	-X github.com/sdebruyn/onelake-explorer-macos/internal/buildinfo.Date=$(DATE)

.PHONY: all build test lint fmt fmt-check vet tidy ci clean smoke release-snapshot help

all: ci

$(BIN): $(GO_FILES) go.mod go.sum
	@mkdir -p $(BIN_DIR)
	go build -ldflags '$(LDFLAGS)' -o $(BIN) ./cmd/ofem

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

fmt-check:
	@unformatted=$$(gofmt -l .); \
	if [ -n "$$unformatted" ]; then \
		echo "The following files need gofmt (run 'make fmt'):"; \
		echo "$$unformatted"; \
		exit 1; \
	fi

vet:
	go vet ./...

tidy:
	go mod tidy

smoke: build
	@$(BIN) --version
	@$(BIN) status

ci: tidy fmt-check vet lint test build smoke

clean:
	rm -rf $(BIN_DIR) build dist dist-app coverage.out

release-snapshot:
	goreleaser release --snapshot --clean

help:
	@echo "Targets:"
	@awk -F':.*##' '/^[a-zA-Z_-]+:.*##/ { printf "  %-18s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
