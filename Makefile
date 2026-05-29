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

build: $(BIN) ## Build the ofem CLI into ./bin/ofem

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

smoke: build ## Build then run --version + status smoke test
	@$(BIN) --version
	@$(BIN) status

ci: tidy fmt-check vet lint test build smoke ## Full local CI gate (run before pushing)

clean: ## Remove build artifacts
	rm -rf $(BIN_DIR) build dist dist-app coverage.out

release-snapshot: ## Run goreleaser locally to validate the config (snapshot)
	goreleaser release --snapshot --clean

# --- Docs site (zensical → ofem.debruyn.dev) ---
#
# The CLI reference under docs/cli/ is generated from the cobra command
# tree by `make docs-cli`. The generated files are committed so the
# Cloudflare Pages build (which only runs zensical, no Go toolchain)
# stays simple. CI fails on drift — see .github/workflows/ci.yml.
#
# docs/cli/ is exclusively generator-owned: every `ofem*.md` file in
# there is rewritten on each `make docs-cli` run. Never hand-edit
# files there — see docs/cli/README.md. The `mkdir -p` keeps a clean
# checkout working (the find would otherwise error on a missing
# directory) and the glob is scoped to `ofem*.md` so the generator
# can never silently nuke a future hand-written `_index.md`, overview
# page, or sibling doc that lives alongside the generated files.

docs-cli:
	@mkdir -p docs/cli
	@find docs/cli -maxdepth 1 -type f -name 'ofem*.md' -delete
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

.PHONY: apple-bootstrap apple-gen apple-gen-host apple-build apple-build-host apple-build-ci apple-test apple-clean

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

# Run the host-less smoke XCTest bundle unsigned. Pure logic tests
# (identifier grammar) — no daemon, no signing, no host app launch.
apple-test: apple-gen
	xcodebuild -project $(XCODE_PROJECT) \
		-scheme OneLakeTests \
		-configuration Debug \
		-destination 'platform=macOS,arch=arm64' \
		-derivedDataPath apple/DerivedData \
		$(APPLE_UNSIGNED) \
		test

# Regenerate the host-app-only Xcode project from project-host.yml. The
# host-only spec omits the OneLakeFileProvider target so contributors on a
# free Apple ID (Personal Team) can smoke-test the host app — Personal
# Teams cannot sign macOS app extensions. Drop this target once every
# contributor is enrolled in the paid Apple Developer Program.
apple-gen-host:
	@command -v xcodegen >/dev/null 2>&1 || { echo "xcodegen not installed; run: brew install xcodegen"; exit 1; }
	xcodegen generate --spec apple/project-host.yml --project-root . --project apple

# Build only the OneLake host app (no File Provider Extension). Use this
# when you don't have a paid Apple Developer Program account yet; see
# apple/project-host.yml for the why.
apple-build-host: apple-gen-host
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
