# Convenience targets for OFEM development.
#
# Day-to-day:
#   make build       — build the ofem CLI into ./bin/ofem
#   make test        — run unit tests with the race detector
#   make lint        — run golangci-lint with the repo config
#   make fmt         — gofmt + goimports (mutates files in place)
#   make fmt-check   — read-only gofmt check (fails on unformatted files)
#   make ci          — fmt-check + lint + test + build (run before pushing)
#   make docs-cli    — regenerate docs/cli/ from the cobra command tree
#   make docs        — docs-cli + zensical build (full local docs build)
#   make docs-serve  — docs-cli + zensical serve (live reload)
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

.PHONY: all build test lint fmt fmt-check vet tidy ci clean smoke release-snapshot help docs docs-cli docs-serve

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
	rm -rf $(BIN_DIR) build dist dist-app coverage.out $(CGO_OUT)

release-snapshot:
	goreleaser release --snapshot --clean

# --- Docs site (zensical → ofem.debruyn.dev) ---
#
# The CLI reference under docs/cli/ is generated from the cobra command
# tree by `make docs-cli`. The generated files are committed so the
# Cloudflare Pages build (which only runs zensical, no Go toolchain)
# stays simple. CI fails on drift — see .github/workflows/ci.yml.

docs-cli:
	@mkdir -p docs/cli
	@find docs/cli -maxdepth 1 -type f -name '*.md' -delete
	go run ./cmd/ofem-docs docs/cli

docs: docs-cli
	uvx --from 'zensical>=0.0.42' zensical build

docs-serve: docs-cli
	uvx --from 'zensical>=0.0.42' zensical serve

help:
	@echo "Targets:"
	@awk -F':.*##' '/^[a-zA-Z_-]+:.*##/ { printf "  %-18s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

# --- Phase 1: macOS app + File Provider Extension ---

XCODE_PROJECT      := apple/OneLake.xcodeproj
XCODE_PROJECT_HOST := apple/OneLakeHost.xcodeproj
APPLE_CONFIG       := apple/Local.xcconfig

.PHONY: apple-bootstrap apple-gen apple-gen-host apple-build apple-build-host apple-clean

# First-time setup: copy the xcconfig sample if it's missing and tell the
# user to fill in their team ID.
apple-bootstrap:
	@if [ ! -f $(APPLE_CONFIG) ]; then \
		cp apple/Local.xcconfig.sample $(APPLE_CONFIG); \
		echo "Created $(APPLE_CONFIG). Edit it and set DEVELOPMENT_TEAM."; \
	else \
		echo "$(APPLE_CONFIG) already exists. Nothing to do."; \
	fi

# Regenerate the .xcodeproj from project.yml. Run after touching project.yml.
# --project-root . lets the spec reference source paths from the repo root
# (e.g. "apple/OneLake") while --project apple drops the generated
# .xcodeproj next to the spec.
apple-gen:
	@command -v xcodegen >/dev/null 2>&1 || { echo "xcodegen not installed; run: brew install xcodegen"; exit 1; }
	xcodegen generate --spec apple/project.yml --project-root . --project apple

# Build the OneLake.app target (Debug, arm64) for local dogfooding.
# Depends on cgo-build so the Swift targets always link against a
# fresh libofemcore.a; xcodebuild discovers the archive + header via
# the LIBRARY_SEARCH_PATHS / HEADER_SEARCH_PATHS settings in
# apple/project.yml.
apple-build: cgo-build apple-gen
	xcodebuild -project $(XCODE_PROJECT) \
		-scheme OneLake \
		-configuration Debug \
		-derivedDataPath apple/DerivedData \
		-allowProvisioningUpdates \
		build

# Regenerate the host-app-only Xcode project from project-host.yml. The
# host-only spec omits the OneLakeFileProvider target so contributors on a
# free Apple ID (Personal Team) can smoke-test the cgo bridge — Personal
# Teams cannot sign macOS app extensions. Drop this target once every
# contributor is enrolled in the paid Apple Developer Program.
apple-gen-host:
	@command -v xcodegen >/dev/null 2>&1 || { echo "xcodegen not installed; run: brew install xcodegen"; exit 1; }
	xcodegen generate --spec apple/project-host.yml --project-root . --project apple

# Build only the OneLake host app (no File Provider Extension). Use this
# when you don't have a paid Apple Developer Program account yet; see
# apple/project-host.yml for the why.
apple-build-host: cgo-build apple-gen-host
	xcodebuild -project $(XCODE_PROJECT_HOST) \
		-scheme OneLake \
		-configuration Debug \
		-derivedDataPath apple/DerivedData \
		-allowProvisioningUpdates \
		build

# Removes only generated/build artefacts. apple/Local.xcconfig is intentionally
# preserved: it holds the per-developer DEVELOPMENT_TEAM and is not a build
# output. Use `make apple-bootstrap` to (re)create it from the .sample.
apple-clean:
	rm -rf apple/OneLake.xcodeproj apple/OneLakeHost.xcodeproj apple/OneLake.xcworkspace apple/OneLakeHost.xcworkspace apple/build apple/DerivedData

# --- cgo bridge: libofemcore.a + libofemcore.h ---
#
# Builds the static C archive (and matching header) that the Swift
# host app and File Provider Extension link against. The output lands
# under apple/build/cgo/ so the Xcode targets can pick it up via the
# LIBRARY_SEARCH_PATHS / HEADER_SEARCH_PATHS settings in
# apple/project.yml.

CGO_OUT     := apple/build/cgo
CGO_ARCHIVE := $(CGO_OUT)/libofemcore.a
CGO_HEADER  := $(CGO_OUT)/libofemcore.h

.PHONY: cgo-build cgo-clean

cgo-build: $(CGO_ARCHIVE)

$(CGO_ARCHIVE): $(GO_FILES) go.mod go.sum
	@mkdir -p $(CGO_OUT)
	CGO_ENABLED=1 go build -buildmode=c-archive \
		-trimpath \
		-ldflags '$(LDFLAGS)' \
		-o $(CGO_ARCHIVE) ./core
	@echo "Built $(CGO_ARCHIVE) and $(CGO_HEADER)"

cgo-clean:
	rm -rf $(CGO_OUT)
