# Architecture overview

Developer-facing summary. End-user docs live under [Home](../index.md); this section is for contributors and anyone curious about how it all fits together.

## Hard constraints

Settled during product discovery and unchanged since:

- **No system-level changes** required from the user (no kernel extensions, no Recovery Mode, no `csrutil` tweaks).
- **Authentication only via interactive browser**. Users only, never service principals or client secrets.
- **Multi-tenant and multi-account simultaneously**, identified by user-chosen short aliases (`work`, `client-a`).
- **Install via Homebrew cask**.
- **No external runtime dependency** for end users (no Python, no .NET, no Node). Statically distributable binary.
- **macOS 14 Sonoma or later on Apple Silicon (arm64) only**.
- **Project communication, code, comments, commit messages, PR descriptions all in English** so anyone can contribute.

## Tech stack at a glance

- **Go** for the core library and the bundled daemon binary. See [Tech stack](../tech-stack.md).
- **Swift** for the macOS host app and File Provider Extension. The Go engine runs in the daemon; the Swift targets call it over JSON-RPC on a Unix-domain socket (no cgo).
- **SQLite** (pure-Go `modernc.org/sqlite`, no cgo) for the metadata cache.
- **MSAL Go** for Microsoft Entra authentication.
- **macOS Keychain** for token storage (file-backed secret store under the OFEM config dir).
- **Azure Application Insights** for opt-out telemetry.
- **Homebrew cask** for distribution. **xcodebuild + codesign + notarytool + create-dmg** for the signed `.app`.

## Process model

```
┌────────────────────────────────┐   ┌────────────────────────────────┐
│  OneLake.app (host, Swift)     │   │  OneLake FileProvider .appex   │
│  - account add/remove UI       │   │  - Swift NSFileProvider*       │
│  - menu bar status icon        │   │  - IPCClient → fp.* methods    │
└──────────────┬─────────────────┘   └───────────────┬────────────────┘
               │   JSON-RPC over the Unix socket      │
               │   (ofem.sock in the App Group)       │
               └──────────────────┬───────────────────┘
                                  ▼
              ┌────────────────────────────────────┐
              │  ofem daemon (Go)                  │  ← long-running; owns the
              │  - engine: auth/onelake/fabric/    │    engine, cache + blob
              │    cache/sync/fp                   │    store; telemetry; polling
              │  - IPC server (internal/ipc)       │
              └────────────────────────────────────┘
```

What each process does:

- The **host app** holds the auth UI, registers the File Provider domain, and shows the menu bar status icon. It also registers the bundled daemon as a LaunchAgent via SMAppService.
- The **File Provider Extension** is sandboxed and short-lived — macOS launches it on demand for each Finder request. It implements the `NSFileProvider*` classes and reaches the daemon over IPC.
- The **daemon** runs as a LaunchAgent (`OneLake.app/Contents/Library/LaunchAgents/dev.debruyn.ofem.daemon.app/Contents/MacOS/ofem`), batches telemetry, polls Fabric on an adaptive schedule, runs scheduled cache eviction, and serves the Unix socket the host app and File Provider Extension share.

All three share state through a macOS App Group (`6D79CUWZ4J.group.dev.debruyn.ofem`, team-prefixed for both Developer ID and Mac App Store): config TOML, the SQLite metadata cache, the cached blob shards, and the per-account Keychain entries.

## Source layout

```
onelake-explorer-macos/
├── cmd/ofem/                    # daemon entry-point binary (bundled in OneLake.app/Contents/Library/LaunchAgents/dev.debruyn.ofem.daemon.app/Contents/MacOS/)
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
│   ├── config/                 # TOML on-disk config under ~/Library/Group Containers/6D79CUWZ4J.group.dev.debruyn.ofem/
│   ├── logging/                # slog setup (text to stdout for foreground daemon, JSON-to-file otherwise)
│   └── buildinfo/              # link-time version/commit/date/conn-string
├── apple/                      # Xcode project, host app, File Provider Extension
├── docs/                       # this site's source
├── scripts/                    # check-prereqs, seed-labels
├── homebrew/                   # cask template (also lives in homebrew-ofem tap)
└── .github/                    # workflows, issue templates, FUNDING.yml
```

## Where to read more

| Topic | Page |
|---|---|
| File Provider Extension as the mount mechanism | [macOS integration](../macos-mount.md) |
| File Provider Extension internals + Swift ↔ Go bridge | [File Provider](../file-provider.md) |
| Microsoft Entra auth design | [Authentication](../auth.md) |
| OneLake DFS + Fabric REST APIs | [OneLake APIs](../onelake-api.md) |
| Language and library choices | [Tech stack](../tech-stack.md) |
| Telemetry schema + redaction | [Telemetry](../telemetry.md) |
| Build, sign, notarize, ship | [Packaging](../packaging-homebrew.md) |
| Local-dev vs publishing prerequisites | [Prerequisites](../prerequisites.md) |
