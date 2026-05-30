# Convenience targets for OFEM development.
#
# Day-to-day:
#   make app         — daemon binary + signed macOS app; THE build to run after pulling
#   make build       — build the ofem daemon binary into ./bin/ofem (Go-only, fast)
#   make test        — run unit tests with the race detector
#   make lint        — run golangci-lint with the repo config
#   make fmt         — gofmt + goimports (mutates files in place)
#   make fmt-check   — read-only gofmt check (fails on unformatted files)
#   make ci          — fmt-check + lint + test + build (run before pushing)
#   make clean       — remove build artifacts
#
# Note: `make ci` deliberately uses fmt-check (read-only) so it matches
# what GitHub Actions does. Use `make fmt` to actually rewrite files.

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

.PHONY: all build test lint fmt fmt-check vet tidy ci clean help

all: ci

$(BIN): $(GO_FILES) go.mod go.sum
	@mkdir -p $(BIN_DIR)
	go build -ldflags '$(LDFLAGS)' -o $(BIN) ./cmd/ofem

build: $(BIN) ## Build the ofem daemon binary into ./bin/ofem

test: ## Run unit tests with the race detector
	go test -race -coverprofile=coverage.out -covermode=atomic ./...

lint: ## Run golangci-lint with the repo config
	golangci-lint run --config .golangci.yml ./...

fmt: ## Reformat Go files with gofmt + goimports (mutates files)
	gofmt -w .
	@if command -v goimports >/dev/null 2>&1; then \
		goimports -w -local github.com/sdebruyn/onelake-explorer-macos .; \
	else \
		echo "goimports not installed; run 'go install golang.org/x/tools/cmd/goimports@latest'"; \
	fi

fmt-check: ## Check formatting (read-only; fails on unformatted files)
	@unformatted=$$(gofmt -l .); \
	if [ -n "$$unformatted" ]; then \
		echo "The following files need gofmt (run 'make fmt'):"; \
		echo "$$unformatted"; \
		exit 1; \
	fi

vet: ## Run go vet
	go vet ./...

tidy: ## Run go mod tidy
	go mod tidy

ci: tidy fmt-check vet lint test build ## Full local CI gate (run before pushing)

clean: ## Remove build artifacts
	rm -rf $(BIN_DIR) build dist dist-app coverage.out

help:
	@echo "Targets:"
	@awk -F':.*##' '/^[a-zA-Z_-]+:.*##/ { printf "  %-18s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

# --- Phase 1: macOS app + File Provider Extension ---

XCODE_PROJECT := apple/OneLake.xcodeproj
APPLE_CONFIG  := apple/Local.xcconfig

.PHONY: apple-bootstrap apple-gen apple-build apple-build-ci apple-test apple-clean app

# One-shot local build of everything runnable: the ofem daemon binary
# (./bin/ofem, needed by the IPC integration test) plus the signed macOS
# app (host + File Provider Extension, with the Go daemon bundled and
# signed). This is THE single build to run after pulling main — `make
# build` and `apple-build` stay available separately for the fast
# Go-only loop and CI.
app: build apple-build ## Build daemon binary + signed macOS app (everything, ready to run)

# Signing knobs that turn a normal build into an unsigned compile-only
# build. CI has no Developer ID identity, so it must NOT pass
# -allowProvisioningUpdates (that reaches Apple for a profile and fails);
# instead it disables code signing entirely. The output is not runnable,
# but it proves the Swift app + .appex still compile — see CODE_REVIEW.md
# M-8.
APPLE_UNSIGNED := CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""

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

# Build the OneLake.app target (Debug, arm64) for local dogfooding. The
# Swift targets talk to the daemon over IPC; there is no cgo archive to
# build first.
apple-build: apple-gen
	xcodebuild -project $(XCODE_PROJECT) \
		-scheme OneLake \
		-configuration Debug \
		-derivedDataPath apple/DerivedData \
		-allowProvisioningUpdates \
		build

# Compile the app + .appex unsigned (no signing identity, no provisioning
# round-trip). This is the CI build gate: it catches Swift compile
# regressions on every PR without needing a Developer ID. The product is
# not runnable. See CODE_REVIEW.md M-8.
apple-build-ci: apple-gen
	xcodebuild -project $(XCODE_PROJECT) \
		-scheme OneLake \
		-configuration Debug \
		-destination 'platform=macOS,arch=arm64' \
		-derivedDataPath apple/DerivedData \
		$(APPLE_UNSIGNED) \
		build

# Run the host-less XCTest bundle unsigned. Includes both the pure
# logic tests (identifier grammar) and the IPC integration test, which
# spawns the ./bin/ofem daemon binary against a temp socket. The
# integration test calls XCTSkip when bin/ofem is missing, so this
# target stays usable on a fresh checkout — but to actually exercise
# the IPC seam, build the daemon binary first (`make build apple-test`
# or just `make app`). CI does this explicitly.
apple-test: apple-gen
	xcodebuild -project $(XCODE_PROJECT) \
		-scheme OneLakeTests \
		-configuration Debug \
		-destination 'platform=macOS,arch=arm64' \
		-derivedDataPath apple/DerivedData \
		$(APPLE_UNSIGNED) \
		test

# Removes generated/build artefacts AND unregisters the built app from
# LaunchServices. apple/Local.xcconfig is preserved (per-developer
# DEVELOPMENT_TEAM, not a build output) — use `make apple-bootstrap` to recreate.
#
# The unregister matters: building the .app in multiple locations (e.g.
# throwaway git worktrees) registers duplicate File Provider providers for the
# same bundle id, after which macOS returns NSFileProviderError.providerNotFound
# (-2001) and the Finder mount never appears. Always run `make apple-clean`
# before removing a worktree you built the app in.
apple-clean:
	@app="$(PWD)/apple/DerivedData/Build/Products/Debug/OneLake.app"; \
	lsreg="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"; \
	if [ -d "$$app" ] && [ -x "$$lsreg" ]; then "$$lsreg" -u "$$app" 2>/dev/null || true; fi
	rm -rf apple/OneLake.xcodeproj apple/OneLake.xcworkspace apple/build apple/DerivedData
