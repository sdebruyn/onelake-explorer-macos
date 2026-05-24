# Roadmap

The scope of the product, grouped by component. The Go core library is shared across every component; only the presentation layer (CLI, `.app`, File Provider Extension, GUI, polish) changes.

## Core library

The Go core under `internal/` and `core/` is the shared engine for every surface — CLI, daemon, host app, and File Provider Extension.

- **Auth (`internal/auth`)**: MSAL Go integration, interactive browser flow, device-code fallback, Keychain-backed token cache, multi-account registry.
- **Fabric REST (`internal/fabric`)**: typed client for `GET /workspaces`, `GET /workspaces/{id}/items`, `GET /workspaces/{id}/folders`, with pagination.
- **OneLake DFS (`internal/onelake`)**: typed client for ADLS Gen2 path operations on the OneLake DFS endpoint, with retries and `Retry-After`-aware throttling.
- **Cache (`internal/cache`)**: SQLite (`modernc.org/sqlite`) schema for file metadata, plus an LRU blob cache with a size cap.
- **Sync (`internal/sync`)**: reconciliation engine, write queue, last-write-wins conflict resolution.
- **Telemetry (`internal/telemetry`)**: App Insights client, opt-out behavior, schema, event emission helpers.
- **IPC (`internal/ipc`)**: JSON-RPC 2.0 over a Unix-domain socket for CLI ↔ daemon and daemon ↔ extension traffic.
- **cgo façade (`core/`)**: C-ABI exports and generated header so Swift can link `libofemcore.a`.

Unit tests cover every internal package; integration tests gated by `OFEM_INTEGRATION=1` run against a real Fabric workspace. Coverage target on `internal/*` is >80%. CI runs `golangci-lint`, `go test`, commitlint, and a build verify.

## CLI

`ofem` is the developer- and power-user-facing entry point.

- `ofem version`, `ofem help`.
- `ofem login` (per alias) using interactive browser by default, device code on `--device-code`.
- `ofem account add | remove | list`.
- `ofem config get | set | snapshot` for TOML config, including the telemetry toggle.
- `ofem daemon install | uninstall | start | stop | status` to manage the LaunchAgent.
- `ofem debug ls`, `ofem debug cat`, `ofem debug stat` against `<alias:/workspace/item/path>` URIs for direct inspection.

## Native macOS app

Distributed as `OneLake.app`, signed with a Developer ID Application certificate and notarized via `xcrun notarytool`.

- Swift host app skeleton under `apple/OneLake.xcodeproj`, generated from `apple/project.yml` by XcodeGen.
- Entitlements: App Sandbox, App Group `group.dev.debruyn.ofem`, network client, Keychain access group.
- `apple/OneLakeFileProvider.appex` extension bundle with manifest, entitlements, and an `NSFileProviderReplicatedExtension` implementation.
- Built via `xcodebuild` against the Go static archive, signed with `codesign --options runtime`, notarized and stapled, packaged as a DMG via `create-dmg`.

## File Provider integration

The mount surface in Finder, implemented as a sandboxed extension that bridges to the Go core via cgo.

- One File Provider domain per account-alias; multi-account end-to-end.
- Account-list and root container enumeration via the Go core.
- Workspace and item enumeration; folder enumeration; file metadata.
- File content fetching (`fetchContents`) with streaming and `Range` header support.
- File upload / modify / delete; folder create / delete.
- macOS-metadata filtering (`.DS_Store`, `._*`, `Spotlight-V100`, `Trashes`, `fseventsd`) in the upload path.
- Adaptive-polling refresh driven by the daemon → `NSFileProviderManager.signalEnumerator`.

## Host app GUI and menu bar

The graphical front end for users who don't live in a terminal.

- SwiftUI account-management screen in the host app: list, add, remove, switch default.
- Menu bar status icon (`NSStatusItem`): sync state, recent activity, pause/resume, open Finder, open settings, quit.
- First-run guided flow in the host app as an alternative to the CLI.
- Settings screen: telemetry toggle, cache max size, parallelism, log level.
- macOS notifications on a curated set of error classes (configurable; default off, in line with the non-intrusive-UX preference).

## Polish

Refinements that improve daily use without changing the core proposition.

- Spotlight metadata for OneLake items (file type, modification time, size, source workspace).
- Quick Look extension for OneLake-specific files (e.g. preview Parquet schemas inline).
- Smart prefetch heuristics (recently-opened folders, opened-with-app patterns).
- Bandwidth throttling controls (max up/down KBps, schedule).
- Performance audit; reduce memory footprint of the daemon to <50 MB at idle.
- Accessibility audit: VoiceOver, keyboard navigation in host app and menu bar.

## Distribution

- `homebrew-ofem` tap with a cask formula; GoReleaser updates the cask on tag.
- Signing + notarization in GitHub Actions; DMG via `create-dmg`.
- First-run telemetry disclosure; `ofem config set telemetry off` honored at the daemon and extension level.

## Documentation and telemetry

Cross-cutting concerns that span every component.

- **Documentation**: `docs/` markdown is authoritative; the docs site at `https://ofem.debruyn.dev` is rendered from it. Significant behavior changes update README.
- **Telemetry analysis**: App Insights reviewed weekly for top errors, adoption by tenant, version uptake. Informs roadmap prioritization.
- **Security**: GitHub Private Security Advisories triaged within 72 hours. Quarterly dependency audit via `govulncheck` and `gh dependabot alerts`.
- **Releases**: tag-based via GitHub Actions, CalVer `YYYY.MM.PATCH`, no fixed cadence — released when meaningful change has accumulated.
- **Issue triage**: weekly. Issues are the public roadmap (chosen over a separate roadmap doc).
- **Localization**: English-only for code, comments, docs, commits, and PR descriptions, so anyone can contribute.

## What is explicitly **out of scope**

- Windows or Linux ports.
- Sovereign clouds (US Gov, China, Germany).
- Service principal authentication.
- Editing of OneLake table metadata (Iceberg/Delta REST APIs).
- Permission management (read or modify ACLs).
- Workspace / item creation, rename, or deletion (those go through the Fabric portal).
- Browser-based version.
- Mobile apps (iOS, iPadOS).

These may be revisited if there is real user demand expressed in Issues, but they are not on the roadmap.

## Risks and mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Microsoft ships an official OneLake explorer for Mac | Low | High | Continue as a multi-account / open-source alternative; sunset gracefully if redundant |
| Apple changes File Provider API in a way that breaks us | Medium | Medium | Pin tested macOS versions in CI; monitor WWDC announcements |
| OneLake API breaks compatibility | Low | High | Nightly integration tests catch drift; pin Fabric API version explicitly |
| MSAL Go deprecated or replaced | Low | Medium | Thin wrapper around MSAL; swap to azidentity if needed |
| Maintainer time runs out | Always | High | Build for sustained low-effort maintenance; encourage contributors via clear CONTRIBUTING.md |
| Code-signing certificate expires mid-release | Medium | Medium | Renew 60 days before expiry; document renewal in the release runbook |
| App Insights free tier exceeded | Low | Low | Sampling rules; rotate to a higher tier with sponsor money if it happens |
