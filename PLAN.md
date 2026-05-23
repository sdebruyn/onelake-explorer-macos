# Implementation plan

A phased roadmap from empty repo to a polished, signed, notarized `OneLake.app` distributed via Homebrew. The Go core library is shared across every phase; only the presentation layer (CLI, `.app`, File Provider Extension, GUI, polish) changes.

## Phase 0 — Core library and debug CLI (internal only)

**Goal**: validate auth, OneLake API, cache, and sync logic without any UI. Not shipped publicly.

| Milestone | Deliverable |
|---|---|
| 0.1 | Repo scaffolding: `go.mod`, `cmd/ofem`, `internal/{auth,onelake,fabric,cache,sync,ipc,telemetry,config,log}`, basic `cobra` CLI with `ofem version`, `ofem help` |
| 0.2 | `internal/auth`: MSAL Go integration, `ofem login` interactive browser flow, device-code fallback, Keychain-backed token cache, multi-account registry |
| 0.3 | `internal/fabric`: typed client for `GET /workspaces`, `GET /workspaces/{id}/items`, `GET /workspaces/{id}/folders`; pagination |
| 0.4 | `internal/onelake`: typed client for ADLS Gen2 path operations on the OneLake DFS endpoint; retries; `Retry-After`-aware throttling |
| 0.5 | `internal/cache`: SQLite (`modernc.org/sqlite`) schema for file metadata; LRU blob cache with size cap |
| 0.6 | Debug CLI: `ofem debug ls <alias:/workspace/item/path>`, `ofem debug cat`, `ofem debug stat` |
| 0.7 | `internal/telemetry`: App Insights client, opt-out behavior, schema, event emission helpers |
| 0.8 | Unit tests for all internal packages; integration tests gated by `OFEM_INTEGRATION=1` against a real Fabric workspace |
| 0.9 | CI: lint (`golangci-lint`), test (`go test`), commitlint, build verify |

**Exit criteria**: I can run `ofem login work`, `ofem login client-a`, `ofem debug ls work:/`, and see all workspaces and items as plain text. All telemetry events fire and are queryable in App Insights. >80% coverage on `internal/*` packages.

**Estimate**: 3–5 weeks of focused part-time work.

## Phase 1 — MVP: signed `.app` with File Provider Extension

**Goal**: first public release. Users do `brew install --cask ofem`, run `ofem login`, and see their OneLake in Finder.

| Milestone | Deliverable |
|---|---|
| 1.1 | `core/`: cgo-exported façade with C-ABI symbols and generated header for Swift |
| 1.2 | `apple/OneLake.xcodeproj`: Swift host app skeleton; entitlements (App Sandbox, App Group, network client, Keychain access group) |
| 1.3 | `apple/OneLakeFileProvider.appex`: extension skeleton, manifest, entitlements; minimal `NSFileProviderReplicatedExtension` returning an empty root |
| 1.4 | Bridge `OneLakeFileProvider` → `libofemcore`: account list and root container enumeration via Go core |
| 1.5 | Workspace and item enumeration; folder enumeration; file metadata |
| 1.6 | File content fetching (`fetchContents`) with streaming and range support |
| 1.7 | File upload / modify / delete; folder create / delete |
| 1.8 | macOS metadata filtering (`.DS_Store` etc) in upload path |
| 1.9 | Adaptive-polling refresh driven by the daemon → `NSFileProviderManager.signalEnumerator` |
| 1.10 | Per-account domain registration; multi-account end-to-end |
| 1.11 | `ofem daemon` subcommands (`install`, `uninstall`, `start`, `stop`, `status`); LaunchAgent plist |
| 1.12 | Apple Developer Program enrollment; Developer ID Application cert; App Store Connect API key |
| 1.13 | Signing + notarization in GitHub Actions; DMG via `create-dmg` |
| 1.14 | `homebrew-ofem` tap; cask formula; GoReleaser hookup |
| 1.15 | First-run disclosure; `ofem config set telemetry off` works |
| 1.16 | Beta testing on Sam's own Macs + 2-3 willing volunteers |
| 1.17 | Tag `v2026.MM.1`; first public release; README badges go green |

**Exit criteria**: `brew install --cask ofem` on a clean Mac succeeds; `ofem login`; OneLake appears in Finder with all configured accounts; opening, editing, creating, deleting files all work and round-trip to OneLake. App Insights shows events from external installs.

**Estimate**: 6–10 weeks after Phase 0 is done.

## Phase 2 — Host app GUI and menu bar

**Goal**: replace the CLI for account management for users who don't live in a terminal.

| Milestone | Deliverable |
|---|---|
| 2.1 | SwiftUI account-management screen in the host app: list, add, remove, switch default |
| 2.2 | Menu bar status icon (`NSStatusItem`): sync state, recent activity, pause/resume, open Finder, open settings, quit |
| 2.3 | First-run guided flow in the host app instead of CLI |
| 2.4 | Settings screen: telemetry toggle, cache max size, parallelism, log level |
| 2.5 | macOS notification on certain error classes (configurable; default off per Sam's preference) |

**Exit criteria**: a non-technical user can install OFEM, sign in, and use OneLake in Finder without ever touching Terminal.

**Estimate**: 4–6 weeks after Phase 1.

## Phase 3 — Polish

| Milestone | Deliverable |
|---|---|
| 3.1 | Spotlight metadata for OneLake items (file type, modification time, size, source workspace) |
| 3.2 | Quick Look extension for OneLake-specific files (e.g. preview Parquet schemas inline) |
| 3.3 | Smart prefetch heuristics (recently-opened folders, opened-with-app patterns) |
| 3.4 | Bandwidth throttling controls (max up/down KBps, schedule) |
| 3.5 | Performance audit; reduce memory footprint of the daemon to <50 MB at idle |
| 3.6 | Accessibility audit: VoiceOver, keyboard navigation in host app and menu bar |
| 3.7 | Documentation site on Zensical at `https://ofem.debruyn.dev` or similar |

**Estimate**: ongoing; no fixed end.

---

## Cross-cutting workstreams

These don't fit neatly into one phase:

- **Documentation**: each phase ships with updated `docs/`. Significant behavior changes update README. Docs site is set up in Phase 3 but `docs/` markdown is authoritative throughout.
- **Telemetry analysis**: review App Insights weekly for top errors, adoption by tenant, version uptake. Inform roadmap prioritization.
- **Security**: respond to GitHub Private Security Advisories within 72 hours. Quarterly dependency audit (`govulncheck`, `gh dependabot alerts`).
- **Releases**: tag-based via GitHub Actions. CalVer `YYYY.MM.PATCH`. No fixed cadence; release when meaningful change accumulated.
- **Issue triage**: weekly. Issues are the public roadmap (Sam's choice over a separate roadmap doc).

## What is explicitly **out of scope** for the foreseeable future

- Windows or Linux ports.
- Sovereign clouds (US Gov, China, Germany).
- Service principal authentication.
- Editing of OneLake table metadata (Iceberg/Delta REST APIs).
- Permission management (read or modify ACLs).
- Workspace / item creation, rename, or deletion (those go through Fabric portal).
- Browser-based version.
- Mobile apps (iOS, iPadOS).

These may be revisited if there is real user demand expressed in Issues, but they are not on the roadmap.

## Risks and mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Microsoft ships an official OneLake explorer for Mac | Low | High | Continue as a multi-account / open-source alternative; sunset gracefully if redundant |
| Apple changes File Provider API in a way that breaks us | Medium | Medium | Pin tested macOS versions in CI; monitor WWDC announcements |
| OneLake API breaks compatibility | Low | High | Nightly integration tests catch drift; pin Fabric API version explicitly |
| MSAL Go deprecated or replaced | Low | Medium | We use a thin wrapper, can swap to azidentity |
| Sam's time runs out | Always | High | Build for sustained low-effort maintenance; encourage contributors via clear CONTRIBUTING.md |
| Code-signing certificate expires mid-release | Medium | Medium | Renew 60 days before expiry; document renewal in `docs/release-runbook.md` (to be written) |
| App Insights free tier exceeded | Low | Low | Sampling rules; rotate to higher tier with sponsor money if it happens |
