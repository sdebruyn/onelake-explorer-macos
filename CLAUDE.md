# CLAUDE.md

Project context for Claude Code sessions on this repo.

## What this project is

OFEM — OneLake Explorer for macOS. Native Finder integration with Microsoft Fabric OneLake, distributed via Homebrew cask, written in Go (core + CLI) and Swift (host app + File Provider Extension). MIT licensed, open source from day one.

## Hard constraints (do not violate)

- No system-level changes for the end user (no kext, no Reduced Security, no Recovery Mode).
- Authentication: interactive browser or device code only. No service principals, no client secrets.
- Multi-tenant + multi-account simultaneously, identified by user-chosen short aliases.
- Install via Homebrew cask.
- No external runtime dependency for end users (no Python / .NET / Node).
- macOS 14 Sonoma or later, arm64-only.
- Project communication: code/docs/comments/commits in English. Sam and Claude speak Dutch.

## Key decisions (where to look)

- All product and tech decisions are in `README.md`, `PLAN.md`, and `docs/*`.
- Phasing: `PLAN.md` — Phase 0 internal core, Phase 1 MVP signed `.app` with File Provider Extension, Phase 2 host app GUI, Phase 3 polish.
- Mount mechanism: File Provider Extension, never FUSE-T. See `docs/macos-mount.md` for the rejected alternatives.
- Auth: `docs/auth.md` — MSAL Go, own multi-tenant Entra App Registration, Keychain-backed cache, per-account `PublicClientApplication`.
- OneLake API: `docs/onelake-api.md` — ADLS Gen2 DFS endpoint for I/O (audience `https://storage.azure.com/`), Fabric REST for discovery (Power BI Service audience `https://analysis.windows.net/powerbi/api`). Two distinct audiences — a single one returns 401 on Fabric REST. See `docs/auth.md`.
- Tech stack: `docs/tech-stack.md` — Go for core + CLI + daemon, Swift for `.app` and `.appex`. The daemon owns the engine/cache; the Swift targets are thin JSON-RPC clients over the daemon's unix socket (no cgo — removed in the SIMPLIFICATION).
- Telemetry: `docs/telemetry.md` — opt-out, App Insights free tier, tenant IDs collected but never UPN / workspace / file names.
- Packaging: `docs/packaging-homebrew.md` — GoReleaser + xcodebuild + notarytool, DMG via Homebrew cask.
- Prerequisites: `docs/prerequisites.md` — splits local dev vs publishing/signing.

## Style and conventions

- Conventional Commits enforced by commitlint in CI.
- CalVer versioning: `YYYY.MM.PATCH` (e.g. `2026.05.1`).
- Trunk-based development; `main` protected; PR + passing CI required.
- `gofmt` + `goimports` + `golangci-lint` mandatory.
- TOML for config files; SQLite for the metadata cache.
- Bundle ID and config namespace: `dev.debruyn.ofem`. Display name in Finder: `OneLake`.
- Mount path on disk: `~/Library/CloudStorage/OneLake-<alias>/<workspace>/<folder>?/<item>/...` (ASCII hyphen, matching OneDrive / Google Drive). macOS picks the parent — File Provider does not let us anchor under `~/OneLake/`; see `docs/file-provider-domain-nesting.md`.
- Finder sidebar shows each domain by the label macOS composes from `<CFBundleDisplayName>` and `NSFileProviderDomain.displayName` (empirically `OneLake — <alias>` with em-dash, OneDrive-style). The em-dash is **display only**; on disk it stays ASCII.
- Logical identifier hierarchy (inside the domain): `<alias>/<workspace>/<folder>?/<item>/...`.

## Where things live

- `cmd/ofem/` — CLI entrypoint.
- `internal/auth/`, `internal/onelake/`, `internal/fabric/`, `internal/cache/`, `internal/sync/`, `internal/fp/`, `internal/ipc/`, `internal/daemon/`, `internal/telemetry/`, `internal/config/`, `internal/log/` — Go core packages. `internal/fp/` is the File Provider domain model the daemon serves over IPC.
- `apple/` — Xcode project, host app, File Provider Extension. `apple/Shared/` holds the IPC client + CoreBridge shared by both Swift targets.
- `docs/` — all design docs.
- `homebrew/` — cask template (also lives in separate `homebrew-ofem` tap repo for release publishing).
- `.github/` — workflows, issue templates, FUNDING.yml.

## Useful commands

```bash
# Build CLI
go build -o bin/ofem ./cmd/ofem

# Run unit tests
go test ./...

# Run integration tests (needs a real Fabric workspace)
OFEM_INTEGRATION=1 go test ./...

# Lint
golangci-lint run

# Build CLI + signed macOS app in one shot (THE build to run after pulling)
make app

# Build only the macOS app (Go daemon is compiled inside the Xcode postBuildScript)
make apple-build
```

## Things to avoid

- Don't suggest FUSE-T, macFUSE, or any kernel-extension-based approach. Sam already rejected the FUSE-T intermediate stage.
- Don't over-engineer protective UX layers. Sam prefers less intrusive defaults — silent retry over notifications, last-write-wins over conflict-copy, no client-side write guards when the server already enforces.
- Don't add features beyond the current phase's exit criteria. Each phase has clear deliverables in PLAN.md.
- Don't introduce Python, .NET, Node, or any runtime dependency for end users.
- Don't suggest making it cross-platform (Windows / Linux). It's macOS-only.
- Don't suggest service-principal auth or client-secret flows.

## When in doubt

- Read the doc in `docs/` first. They are intentionally detailed.
- If a decision needs to be made and it's not documented, ask Sam in Dutch before guessing.
- If you create a new design doc, link it from README.md.

## Open questions / known unknowns

- Exact behavior of paused Fabric capacity workspaces on the File Provider domain — italic icon needs API-level confirmation.
- Whether MSAL Go's cache extensibility plays nicely with the macOS Keychain library we pick — needs a small spike during Phase 0.

## Resolved spikes

- **Nesting per-account domains under one `~/OneLake/` parent.** Not possible. `replicatedKnownFolder` is the iCloud-style Desktop/Documents takeover API (macOS 15+) and not a custom-parent mechanism. Each domain lands at `~/Library/CloudStorage/OneLake-<alias>/`. See `docs/file-provider-domain-nesting.md`.
