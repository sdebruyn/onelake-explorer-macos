# Convenience targets for OFEM development.
#
# Day-to-day:
#   make app        — signed macOS app; THE build to run after pulling
#   make build      — Debug build of OneLake.app via xcodebuild
#   make test       — run Swift unit tests (OfemKit + host-app logic)
#   make build-ci   — unsigned compile-only build (used in CI)
#   make clean      — remove build artefacts + unregister from LaunchServices
#   make gen        — regenerate OneLake.xcodeproj from project.yml

XCODE_PROJECT := OneLake.xcodeproj
APPLE_CONFIG  := Local.xcconfig

.PHONY: app bootstrap gen build build-ci test test-integration clean help

# Build the signed macOS app. This is THE single build to run after pulling main.
app: build ## Build signed macOS app (THE build to run after pulling)

# Signing knobs that turn a normal build into an unsigned compile-only
# build. CI has no Developer ID identity, so it must NOT pass
# -allowProvisioningUpdates (that reaches Apple for a profile and fails);
# instead it disables code signing entirely. The output is not runnable,
# but it proves the Swift app + .appex still compile.
APPLE_UNSIGNED := CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""

# First-time setup: copy the xcconfig sample if it's missing and tell the
# user to fill in their team ID.
bootstrap: ## Write Local.xcconfig from the sample (first-time setup)
	@if [ ! -f $(APPLE_CONFIG) ]; then \
		cp Local.xcconfig.sample $(APPLE_CONFIG); \
		echo "Created $(APPLE_CONFIG). Edit it and set DEVELOPMENT_TEAM."; \
	else \
		echo "$(APPLE_CONFIG) already exists. Nothing to do."; \
	fi

# Regenerate the .xcodeproj from project.yml. Run after touching project.yml.
# --project-root . lets the spec reference source paths from the repo root
# (e.g. "OneLake") while --project . drops the generated .xcodeproj at the
# repo root, next to the spec.
gen: bootstrap ## Regenerate OneLake.xcodeproj from project.yml
	@command -v xcodegen >/dev/null 2>&1 || { echo "xcodegen not installed; run: make bootstrap && brew install xcodegen"; exit 1; }
	xcodegen generate --spec project.yml --project-root . --project .

# Build the OneLake.app target (Debug, arm64) for local dogfooding.
build: gen ## Build OneLake.app (Debug, signed) for local use
	@if grep -q 'REPLACE_WITH_YOUR_TEAM_ID' $(APPLE_CONFIG) 2>/dev/null; then \
		echo "ERROR: $(APPLE_CONFIG) still has the placeholder DEVELOPMENT_TEAM."; \
		echo "       Edit it and set your real Apple Developer Team ID."; \
		exit 1; \
	fi
	xcodebuild -project $(XCODE_PROJECT) \
		-scheme OneLake \
		-configuration Debug \
		-derivedDataPath DerivedData \
		-allowProvisioningUpdates \
		build

# Compile the app + .appex unsigned (no signing identity, no provisioning
# round-trip). This is the CI build gate: it catches Swift compile
# regressions on every PR without needing a Developer ID. The product is
# not runnable.
build-ci: gen ## Compile app + .appex unsigned (CI gate)
	xcodebuild -project $(XCODE_PROJECT) \
		-scheme OneLake \
		-configuration Debug \
		-destination 'platform=macOS,arch=arm64' \
		-derivedDataPath DerivedData \
		$(APPLE_UNSIGNED) \
		build

# Run unit tests:
#   OfemKit                   — engine logic + identifier-grammar contract (swift test)
#   OneLakeHostTests          — host-app pure logic (write fence, icon state,
#                               mount-path helper, sign-in coordinator,
#                               domain identifier composition)
#   OneLakeFileProviderTests  — FPE callback logic (error mapping, anchor encode/
#                               decode, engine lifecycle, XPC service side)
test: gen ## Run Swift unit tests (OfemKit + host-app logic + FPE logic)
	cd Packages/OfemKit && swift test
	rm -rf DerivedData/HostTests.xcresult DerivedData/FPETests.xcresult
	xcodebuild -project $(XCODE_PROJECT) \
		-scheme OneLakeHostTests \
		-configuration Debug \
		-destination 'platform=macOS,arch=arm64' \
		-derivedDataPath DerivedData \
		-enableCodeCoverage YES \
		-resultBundlePath DerivedData/HostTests.xcresult \
		$(APPLE_UNSIGNED) \
		test
	xcodebuild -project $(XCODE_PROJECT) \
		-scheme OneLakeFileProviderTests \
		-configuration Debug \
		-destination 'platform=macOS,arch=arm64' \
		-derivedDataPath DerivedData \
		-enableCodeCoverage YES \
		-resultBundlePath DerivedData/FPETests.xcresult \
		$(APPLE_UNSIGNED) \
		test

# Run the live integration tests against a real Fabric workspace.
#
# Requires injected bearer tokens and workspace coordinates in the environment:
#   OFEM_TOKEN_ONELAKE      bearer token, audience https://storage.azure.com/
#   OFEM_TOKEN_FABRIC       bearer token, audience https://analysis.windows.net/powerbi/api
#   OFEM_TEST_WORKSPACE_ID  Fabric workspace GUID
#   OFEM_TEST_LAKEHOUSE_ID  Lakehouse item GUID
#
# Mint the tokens locally with the Azure CLI (see docs/auth.md); CI provisions
# them via OIDC in .github/workflows/integration.yml.
test-integration: ## Run live integration tests (needs OFEM_TOKEN_* + OFEM_TEST_* env)
	cd Packages/OfemKit && OFEM_INTEGRATION=1 swift test --filter IntegrationTests

# Removes generated/build artefacts AND unregisters the built app from
# LaunchServices. Local.xcconfig is preserved (per-developer
# DEVELOPMENT_TEAM, not a build output) — use `make bootstrap` to recreate.
#
# The unregister matters: building the .app in multiple locations (e.g.
# throwaway git worktrees) registers duplicate File Provider providers for the
# same bundle id, after which macOS returns NSFileProviderError.providerNotFound
# (-2001) and the Finder mount never appears. Always run `make clean`
# before removing a worktree you built the app in.
clean: ## Remove build artefacts and unregister app from LaunchServices
	@lsreg="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"; \
	if [ -x "$$lsreg" ]; then \
		for app in \
			"$(CURDIR)/DerivedData/Build/Products/Debug/OneLake.app" \
			"$(CURDIR)/build/Release/Build/Products/Release/OneLake.app" \
			"$(CURDIR)/build/Export/OneLake.app"; do \
			if [ -d "$$app" ]; then "$$lsreg" -u "$$app" 2>/dev/null || true; fi; \
		done; \
	fi
	rm -rf OneLake.xcodeproj OneLake.xcworkspace build DerivedData

help: ## Show available targets
	@echo "Targets:"
	@awk -F':.*##' '/^[a-zA-Z_-]+:.*##/ { printf "  %-12s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
