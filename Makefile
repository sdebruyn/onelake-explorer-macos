# Convenience targets for OFEM development.
#
# Day-to-day:
#   make app        — signed macOS app; THE build to run after pulling
#   make build      — Debug build of OneLake.app via xcodebuild
#   make install    — build + install Debug app into /Applications and relaunch
#   make test       — run Swift unit tests (OfemKit + host-app logic)
#   make build-ci   — unsigned compile-only build (used in CI)
#   make clean      — remove build artefacts + unregister from LaunchServices
#   make gen        — regenerate OneLake.xcodeproj from project.yml

XCODE_PROJECT := OneLake.xcodeproj
APPLE_CONFIG  := Local.xcconfig

# Paths used by the install and clean targets.
BUILT_APP   := $(CURDIR)/DerivedData/Build/Products/Debug/OneLake.app
INSTALL_APP := /Applications/OneLake.app
LSREGISTER  := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# Prevent concurrent runs of the test/build targets from contending on the
# SwiftPM build lock. `make -j` can invoke multiple recipe lines in parallel
# within a target; .NOTPARALLEL disables that for the entire Makefile so the
# OfemKit `swift test` and host `xcodebuild` invocations always serialize.
.NOTPARALLEL:

.PHONY: app bootstrap gen build build-ci install test test-integration format format-lint lint scan clean help

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

# Source directories mirrored from project.yml's `sources:` entries (across
# all five targets). Only the *set* of files under these directories matters
# for the "new/removed file" regen case below — see .source-manifest.
XCODEGEN_SOURCE_DIRS := OneLake OneLakeFileProvider Shared OneLakeHostTests OneLakeFileProviderTests

# Filesystem/editor noise that can appear and disappear inside a source
# directory without any actual source change (Finder's .DS_Store, editor
# swap files) — excluded from the snapshot below so it can't trip the
# list-diff guard into a spurious (harmless but noisy) regen. Mirrors the
# same noise patterns already ignored elsewhere in .gitignore.
XCODEGEN_SOURCE_NOISE := .DS_Store *.swp *.swo *~

# FORCE lets .source-manifest's recipe (a cheap `find`) run on every
# invocation while .source-manifest itself still behaves as a normal
# mtime-based prerequisite for the project.pbxproj rule below.
.PHONY: FORCE
FORCE:

# Snapshot of the source tree's file *names* — not their content — one per
# line, sorted for a stable diff. project.pbxproj enumerates file references
# by path, so xcodegen only needs to be told about the project again when a
# file is ADDED or REMOVED; editing an existing file's content never changes
# this list. The recipe always runs (via FORCE), but only overwrites — and
# thus only bumps the mtime of — .source-manifest when the list actually
# changed, via the cmp/mv guard. That mtime is the signal the file target
# below reacts to, so an ordinary content edit correctly does NOT trigger
# a regen, while a new or deleted source file does.
.source-manifest: FORCE
	@find $(XCODEGEN_SOURCE_DIRS) -type f $(foreach n,$(XCODEGEN_SOURCE_NOISE),-not -name '$(n)') 2>/dev/null | sort > $@.tmp
	@cmp -s $@.tmp $@ 2>/dev/null || mv $@.tmp $@
	@rm -f $@.tmp

# FILE target: regenerate the .xcodeproj when project.yml changes, or when
# .source-manifest's mtime advances (a source file was added or removed —
# see above). A clean CI checkout has no .xcodeproj, so the target always
# fires there (file missing → make considers it stale).
# This avoids the unconditional xcodegen run on every build/test invocation
# that the old phony-gen prerequisite caused (build-23), while still
# catching new source files that project.yml's own mtime wouldn't reflect
# (#453 — previously a newly added file was silently absent from the build).
# Note: bootstrap must be called before this target so Local.xcconfig exists
# (xcodegen requires the config files referenced in project.yml at generation
# time). The build/build-ci/test targets list bootstrap + this file target as
# separate prerequisites in the correct order.
#
# --project-root . lets the spec reference source paths from the repo root
# (e.g. "OneLake") while --project . drops the generated .xcodeproj at the
# repo root, next to the spec.
OneLake.xcodeproj/project.pbxproj: project.yml .source-manifest
	@command -v xcodegen >/dev/null 2>&1 || { echo "xcodegen not installed; run: make bootstrap && brew install xcodegen"; exit 1; }
	xcodegen generate --spec project.yml --project-root . --project .

# Phony alias — forces regeneration regardless of timestamps. Useful for
# `make gen` after adding new source files or editing project.yml explicitly.
# Depends on .source-manifest so this run also refreshes the snapshot to the
# current file list; otherwise a contributor following this target's own
# "run after adding source files" advice would leave the manifest stale,
# and the *next* build would trip the list-diff guard for a no-op, redundant
# (if harmless) xcodegen pass.
gen: bootstrap .source-manifest ## Regenerate OneLake.xcodeproj from project.yml (force)
	@command -v xcodegen >/dev/null 2>&1 || { echo "xcodegen not installed; run: make bootstrap && brew install xcodegen"; exit 1; }
	xcodegen generate --spec project.yml --project-root . --project .

# Build the OneLake.app target (Debug, arm64) for local dogfooding. The
# guard below only rejects an UNSET DEVELOPMENT_TEAM (the placeholder in
# Local.xcconfig) — it cannot tell a free team ID from a paid one. A real
# team ID passes the guard, but xcodebuild's -allowProvisioningUpdates
# provisioning step then requires a paid Apple Developer Program team to
# sign the File Provider Extension (a free Personal Team cannot produce a
# runnable build). Contributors without a paid account should use
# `build-ci` instead.
build: bootstrap OneLake.xcodeproj/project.pbxproj ## Build OneLake.app (Debug, signed) for local use
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

# Install the freshly built Debug app into /Applications and relaunch.
#
# Steps, in order, to guarantee the NEW binary is active:
#
#   1. Guard: refuse if INSTALL_APP does not end in /OneLake.app so an
#      accidental override cannot expand rm -rf to a destructive path.
#   2. Quit the host app and poll for it to fully exit.  osascript delivers
#      the Quit Event and returns immediately; the actual shutdown (domain
#      deregistration, XPC teardown) can take several seconds on a loaded
#      system, so polling is safer than a fixed sleep.
#   3. Kill the running FPE (.appex) process (anchored to /Applications so
#      worktree builds are not disturbed) and wait for it to exit.  macOS
#      caches the extension binary and keeps the old process alive after the
#      bundle is replaced on disk.  fileproviderd monitors the registered
#      .appex path — not the inode — so removing the bundle while the process
#      is still winding down can leave the File Provider domain in a faulted
#      state.
#   4. Stage the copy via a .new sibling (cleaning up any leftover from a prior
#      failed install first) so rm -rf only runs after ditto succeeds — a
#      mid-copy ditto failure (disk full, read-only volume) leaves the existing
#      /Applications bundle intact.  ditto (not cp -R) preserves bundle
#      structure, resource forks, and extended attributes correctly on macOS.
#   5. Unregister the DerivedData copy from LaunchServices before launching
#      the /Applications copy.  Without this, both copies are registered
#      under the same bundle ID (dev.debruyn.ofem) — the documented
#      NSFileProviderError.providerNotFound (-2001) failure mode from the
#      clean target comment.  The single remaining registration also removes
#      any osascript display-name ambiguity on the next install run.
#   6. Relaunch so the host re-registers its File Provider domains with macOS.
install: build ## Build and install Debug app into /Applications, then relaunch
	# Guard: refuse if INSTALL_APP does not end in /OneLake.app so an accidental
	# override (e.g. make install INSTALL_APP=/Applications) cannot rm -rf a
	# broader path.
	@case "$(INSTALL_APP)" in */OneLake.app) ;; *) echo "ERROR: INSTALL_APP must end in /OneLake.app (got: $(INSTALL_APP))"; exit 1 ;; esac
	# Quit the host app gracefully; tolerate "not running" (non-zero exit).
	# osascript resolves the app by display name via LaunchServices; the
	# lsregister step below ensures only the /Applications copy is registered
	# at launch time, so there is no ambiguity between copies.
	osascript -e 'tell application "OneLake" to quit' 2>/dev/null || true
	# Poll for the host to fully exit (max 10 s, 0.5 s intervals) — osascript
	# returns after delivering the Quit Event, not after the app has exited.
	@n=0; until ! pgrep -xq 'OneLake' 2>/dev/null || [ $$n -ge 20 ]; do sleep 0.5; n=$$((n+1)); done
	# Terminate the stale /Applications FPE process so macOS reloads the
	# extension from the new bundle; tolerate "not found" (non-zero exit).
	pkill -f '/Applications/OneLake.app/Contents/PlugIns/OneLakeFileProvider.appex' 2>/dev/null || true
	# Poll for the FPE to exit before touching the bundle; fileproviderd
	# monitors the .appex path and may fault the domain if it disappears
	# while the old process is still winding down.
	@n=0; until ! pgrep -f '/Applications/OneLake.app/Contents/PlugIns/OneLakeFileProvider.appex' >/dev/null 2>&1 || [ $$n -ge 20 ]; do sleep 0.5; n=$$((n+1)); done
	# Remove any leftover staging bundle from a previous failed install.
	rm -rf "$(INSTALL_APP).new"
	# Stage the new bundle first so rm -rf only runs after ditto succeeds;
	# if ditto fails (disk full, /Applications temporarily read-only), the
	# existing installation is preserved.
	ditto "$(BUILT_APP)" "$(INSTALL_APP).new"
	rm -rf "$(INSTALL_APP)"
	mv "$(INSTALL_APP).new" "$(INSTALL_APP)"
	# Unregister the DerivedData copy from LaunchServices before launching
	# /Applications/OneLake.app.  A duplicate registration under the same
	# bundle ID (dev.debruyn.ofem) triggers providerNotFound (-2001).
	@if [ -x "$(LSREGISTER)" ]; then "$(LSREGISTER)" -u "$(BUILT_APP)" 2>/dev/null || true; fi
	# Relaunch the host app so it re-registers its File Provider domains with macOS.
	open "$(INSTALL_APP)"

# Compile the app + .appex unsigned (no signing identity, no provisioning
# round-trip). This is the CI build gate: it catches Swift compile
# regressions on every PR without needing a Developer ID. The product is
# not runnable. Recommended as the first build for a new contributor — it
# works on a fresh checkout with no Apple account, free or paid.
build-ci: bootstrap OneLake.xcodeproj/project.pbxproj ## Compile app + .appex unsigned (CI gate)
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
test: bootstrap OneLake.xcodeproj/project.pbxproj ## Run Swift unit tests (OfemKit + host-app logic + FPE logic)
	@# Run all three suites in a single shell with set -e so any failure fails the
	@# target immediately. OfemKit (swift test) and the two xcodebuild suites must
	@# run sequentially — .NOTPARALLEL above prevents make -j from interleaving
	@# them, which would contend on the SwiftPM build lock (build-10).
	@set -e; \
	cd Packages/OfemKit && swift test; \
	cd "$(CURDIR)"; \
	rm -rf DerivedData/HostTests.xcresult DerivedData/FPETests.xcresult; \
	xcodebuild -project $(XCODE_PROJECT) \
		-scheme OneLakeHostTests \
		-configuration Debug \
		-destination 'platform=macOS,arch=arm64' \
		-derivedDataPath DerivedData \
		-enableCodeCoverage YES \
		-resultBundlePath DerivedData/HostTests.xcresult \
		$(APPLE_UNSIGNED) \
		test; \
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
	@if [ -x "$(LSREGISTER)" ]; then \
		for app in \
			"$(CURDIR)/DerivedData/Build/Products/Debug/OneLake.app" \
			"$(CURDIR)/build/Release/Build/Products/Release/OneLake.app" \
			"$(CURDIR)/build/Export/OneLake.app" \
			"$(INSTALL_APP)"; do \
			if [ -d "$$app" ]; then "$(LSREGISTER)" -u "$$app" 2>/dev/null || true; fi; \
		done; \
	fi
	rm -rf OneLake.xcodeproj OneLake.xcworkspace build DerivedData .source-manifest

# SwiftFormat (nicklockwood/SwiftFormat 0.61.1) — the version is pinned so
# local and CI agree. Install: brew install swiftformat (or the exact version).
# The .swiftformat config at the repo root controls rules and excludes.
format: ## Reformat Swift sources in place (swiftformat .)
	@command -v swiftformat >/dev/null 2>&1 || { echo "swiftformat not installed; run: brew install swiftformat"; exit 1; }
	swiftformat .

format-lint: ## Lint formatting without modifying files (mirrors CI gate)
	@command -v swiftformat >/dev/null 2>&1 || { echo "swiftformat not installed; run: brew install swiftformat"; exit 1; }
	swiftformat --lint .

# SwiftLint (realm/SwiftLint 0.63.3) — the version is pinned so local and
# CI agree. Install: brew install swiftlint.
# The .swiftlint.yml config at the repo root controls rules and excludes.
# Exits non-zero on error-level violations; warnings do not fail the run.
lint: ## Run SwiftLint (mirrors CI gate; warnings only, errors fail)
	@command -v swiftlint >/dev/null 2>&1 || { echo "swiftlint not installed; run: brew install swiftlint"; exit 1; }
	swiftlint lint --quiet

# Periphery (peripheryapp/periphery 3.7.4) — dead-code detection. The version
# is pinned so local and CI agree. Install: brew install periphery.
# The .periphery.yml config at the repo root controls targets and exclusions.
# Runs in strict mode (any finding is an error). Baseline is clean.
scan: ## Run periphery dead-code scan (mirrors CI gate)
	@command -v periphery >/dev/null 2>&1 || { echo "periphery not installed; run: brew install periphery"; exit 1; }
	periphery scan --format xcode

help: ## Show available targets
	@echo "Targets:"
	@awk -F':.*##' '/^[a-zA-Z_-]+:.*##/ { printf "  %-12s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
