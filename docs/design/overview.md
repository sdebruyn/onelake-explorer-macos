# Architecture overview

Developer-facing summary. End-user docs live under [Home](../index.md); this section is for contributors and anyone curious about how it all fits together.

## Hard constraints

Settled during product discovery and unchanged since:

- **No system-level changes** required from the user (no kernel extensions, no Recovery Mode, no `csrutil` tweaks).
- **Authentication only via interactive browser or device code**. Users only, never service principals or client secrets.
- **Multi-tenant and multi-account simultaneously**, identified by user-chosen short aliases (`work`, `client-a`).
- **Install via Homebrew cask**.
- **No external runtime dependency** for end users (no Python, no .NET, no Node). Statically distributable binary.
- **macOS 14 Sonoma or later on Apple Silicon (arm64) only**.
- **Project communication, code, comments, commit messages, PR descriptions all in English** so anyone can contribute.

## Tech stack at a glance

- **Go** for the core library, CLI, and daemon. Chosen over Rust for time-to-market — see [Tech stack](../tech-stack.md).
- **Swift** for the macOS host app and File Provider Extension. The Go core ships as a static library and is called over a cgo / C-ABI bridge.
- **SQLite** (pure-Go `modernc.org/sqlite`, no cgo) for the metadata cache.
- **MSAL Go** for Microsoft Entra authentication.
- **macOS Keychain** for token storage (via `zalando/go-keyring`).
- **Azure Application Insights** for opt-out telemetry.
- **Homebrew cask** for distribution. **GoReleaser** for the CLI binary; **xcodebuild + codesign + notarytool + create-dmg** for the signed `.app`.

## Process model

```
┌────────────────────────────────┐
│  OneLake.app (host, Swift)     │  ← user opens for account management
│  - Auth flow (browser)         │
│  - Account add/remove UI       │
│  - Menu bar status icon        │
└──────────┬─────────────────────┘
           │ XPC / App Group
┌──────────┴─────────────────────┐
│  OneLake FileProvider .appex   │  ← macOS-managed sandboxed extension
│  - Swift NSFileProvider*       │
│  - Bridge to core lib          │
└──────────┬─────────────────────┘
           │ cgo / C-ABI
┌──────────┴─────────────────────┐
│  libofemcore (Go)               │  ← auth + OneLake API + cache + sync
└──────────┬─────────────────────┘
           │ JSON-RPC over Unix socket
┌──────────┴─────────────────────┐
│  ofem daemon (Go)               │  ← long-running: telemetry, polling, IPC
│  +                             │
│  ofem CLI (Go)                  │  ← setup, account mgmt, debug
└────────────────────────────────┘
```

Why three processes:

- The **host app** holds the auth UI, registers the File Provider domain, and shows the menu-bar status icon. It may be quit by the user.
- The **File Provider Extension** is sandboxed and short-lived — macOS launches it on demand for each Finder request. It cannot hold network sockets or run scheduled work.
- The **daemon** handles everything the sandbox blocks: telemetry batching, adaptive polling, the Unix socket the CLI talks to, scheduled cache eviction.

All three share state through a macOS App Group (`group.dev.debruyn.ofem`): config TOML, the SQLite metadata cache, the cached blob shards, and the per-account Keychain entries.

## Source layout

```
onelake-explorer-macos/
├── cmd/ofem/                    # CLI entrypoint and subcommand wiring
├── internal/
│   ├── auth/                   # MSAL, Keychain cache, Account registry
│   ├── api/                    # shared HTTP plumbing (retry, errors, token interface)
│   ├── fabric/                 # Fabric REST client (discovery)
│   ├── onelake/                # OneLake DFS / ADLS Gen2 client (I/O)
│   ├── cache/                  # SQLite metadata + sharded LRU blob cache
│   ├── sync/                   # reconciliation engine glueing the above
│   ├── telemetry/              # Application Insights client + redaction
│   ├── ipc/                    # JSON-RPC 2.0 over Unix socket
│   ├── daemon/                 # background process + LaunchAgent management
│   ├── config/                 # TOML on-disk config under ~/Library/Application Support/dev.debruyn.ofem/
│   ├── logging/                # slog setup (CLI text vs daemon JSON-to-file)
│   └── buildinfo/              # link-time version/commit/date/conn-string
├── apple/                      # Xcode project, host app, File Provider Extension (Phase 1+)
├── docs/                       # this site's source
├── scripts/                    # check-prereqs, seed-labels
├── homebrew/                   # cask template (also lives in homebrew-ofem tap)
└── .github/                    # workflows, issue templates, FUNDING.yml
```

## Status today

Phase 0 is implemented and in flight: scaffolding, CI/lint/release tooling, telemetry, auth (foundation + MSAL), Fabric REST + OneLake DFS clients, SQLite metadata + LRU blob cache, sync engine, daemon + LaunchAgent + Unix socket IPC. See [Roadmap](roadmap.md) for the live milestone status and Phase 1+ plans.

## Where to read more

| Topic | Page |
|---|---|
| Reference: Microsoft's Windows OneLake File Explorer | [Windows File Explorer](../onelake-file-explorer-windows.md) |
| Why File Provider Extension, alternatives rejected | [macOS integration](../macos-mount.md) |
| File Provider Extension internals + Swift ↔ Go bridge | [File Provider](../file-provider.md) |
| Microsoft Entra auth design | [Authentication](../auth.md) |
| OneLake DFS + Fabric REST APIs | [OneLake APIs](../onelake-api.md) |
| Language and library choices | [Tech stack](../tech-stack.md) |
| Telemetry schema + redaction | [Telemetry](../telemetry.md) |
| Research that led to the App Insights decision | [Telemetry hosting research](../telemetry-hosting-research.md) |
| Build, sign, notarize, ship | [Packaging](../packaging-homebrew.md) |
| Prior art search | [Prior art](../prior-art.md) |
| Local-dev vs publishing prerequisites | [Prerequisites](../prerequisites.md) |
