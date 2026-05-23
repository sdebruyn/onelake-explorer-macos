# Architecture

Developer overview of how OFE is built. End-user documentation is in the [README](README.md); detailed design rationale per topic lives in [docs/](docs/).

## Hard constraints

These were settled during product discovery and shape every technical decision below.

- **No system-level changes** required from the user (no kernel extensions, no Recovery Mode, no `csrutil` tweaks).
- **Authentication only via interactive browser or device code**. Users only, never service principals or client secrets.
- **Multi-tenant and multi-account simultaneously**, identified by user-chosen short aliases (`work`, `client-a`).
- **Install via Homebrew cask**. Single command, no extra dependencies.
- **No external runtime dependency** for end users (no Python, no .NET, no Node). Statically distributable binary.
- **macOS 14 Sonoma or later on Apple Silicon (arm64) only**.
- **Project communication, code, comments, commit messages, PR descriptions all in English** so anyone can contribute.

## Tech stack at a glance

- **Go** for the core library, CLI, and daemon. Chosen over Rust for time-to-market; see [docs/tech-stack.md](docs/tech-stack.md) for the explicit evaluation.
- **Swift** for the macOS host app and the File Provider Extension. The Go core ships as a static library and is called over a cgo / C-ABI bridge.
- **SQLite** (pure-Go `modernc.org/sqlite`, no cgo) for the metadata cache.
- **MSAL Go** for Microsoft Entra authentication.
- **macOS Keychain** for token storage (via `zalando/go-keyring`).
- **Azure Application Insights** for opt-out telemetry.
- **Homebrew cask** for distribution. **GoReleaser** for the CLI binary; **xcodebuild + codesign + notarytool + create-dmg** for the signed `.app`.

## Roadmap

| Phase | Deliverable | Audience |
|---|---|---|
| **0** *(in progress)* | Core Go library + CLI + daemon + sync engine | Internal validation, not released publicly |
| **1 — MVP** | Signed/notarized `OneLake.app` with File Provider Extension + Homebrew cask | First public release |
| **2** | SwiftUI account-management GUI in the host app + menu bar status icon | Non-CLI users |
| **3** | Polish: Spotlight metadata, Quick Look extensions, sync UX, performance | Mass-market readiness |

Full milestones with exit criteria: [PLAN.md](PLAN.md).

## Process model

OFE runs as three coordinating processes once installed:

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
│  libofecore (Go)               │  ← auth + OneLake API + cache + sync
└──────────┬─────────────────────┘
           │ JSON-RPC over Unix socket
┌──────────┴─────────────────────┐
│  ofe daemon (Go)               │  ← long-running: telemetry, polling, IPC
│  +                             │
│  ofe CLI (Go)                  │  ← setup, account mgmt, debug
└────────────────────────────────┘
```

Why three processes:
- The **host app** holds the auth UI, registers the File Provider domain, and shows the menu-bar status icon. May be quit by the user.
- The **File Provider Extension** is sandboxed and short-lived — macOS launches it on demand for each Finder request. It cannot hold network sockets or run scheduled work.
- The **daemon** handles everything the sandbox blocks: telemetry batching, adaptive polling, the Unix socket the CLI talks to, scheduled cache eviction.

All three share state through a macOS App Group (`group.dev.debruyn.ofe`): config TOML, the SQLite metadata cache, the cached blob shards, and the per-account Keychain entries.

## Source layout

```
onelake-explorer-macos/
├── cmd/ofe/                    # CLI entrypoint and subcommand wiring
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
│   ├── config/                 # TOML on-disk config under ~/Library/Application Support/dev.debruyn.ofe/
│   ├── logging/                # slog setup (CLI text vs daemon JSON-to-file)
│   └── buildinfo/              # link-time version/commit/date/conn-string
├── apple/                      # Xcode project, host app, File Provider Extension (Phase 1+)
├── docs/                       # design rationale per topic
├── scripts/                    # check-prereqs, seed-labels
├── homebrew/                   # cask template (also lives in homebrew-ofe tap)
└── .github/                    # workflows, issue templates, FUNDING.yml
```

## Design topics

| Topic | Doc |
|---|---|
| Reference: Microsoft's Windows OneLake File Explorer | [docs/onelake-file-explorer-windows.md](docs/onelake-file-explorer-windows.md) |
| OneLake DFS + Fabric REST APIs | [docs/onelake-api.md](docs/onelake-api.md) |
| Microsoft Entra authentication | [docs/auth.md](docs/auth.md) |
| Why File Provider Extension; alternatives rejected | [docs/macos-mount.md](docs/macos-mount.md) |
| File Provider Extension architecture and Swift ↔ Go bridge | [docs/file-provider.md](docs/file-provider.md) |
| Language and library choices | [docs/tech-stack.md](docs/tech-stack.md) |
| Build, sign, notarize, distribute via Homebrew cask | [docs/packaging-homebrew.md](docs/packaging-homebrew.md) |
| Telemetry design, schema, App Insights backend | [docs/telemetry.md](docs/telemetry.md) |
| Research that led to the App Insights decision | [docs/telemetry-hosting-research.md](docs/telemetry-hosting-research.md) |
| Prior art — what already exists, what doesn't | [docs/prior-art.md](docs/prior-art.md) |
| Local-dev vs publishing prerequisites | [docs/prerequisites.md](docs/prerequisites.md) |

## Status today

Phase 0 is implemented and in flight: scaffolding, CI/lint/release tooling, telemetry, auth (foundation + MSAL), Fabric REST + OneLake DFS clients, SQLite metadata + LRU blob cache, sync engine, daemon + LaunchAgent + Unix socket IPC. Active work is the wire-up of the sync engine and telemetry into the daemon, plus the TokenProvider unification.

Phase 1 (Xcode project + signed `.app` with File Provider Extension) starts once Phase 0 wire-up is complete and the Apple Developer Program enrolment is in place.
