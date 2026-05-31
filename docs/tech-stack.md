# Tech stack

## Language: Go for the core + daemon, Swift for host app and File Provider Extension

The core library and the bundled daemon binary are written in **Go**. The macOS `.app` host and the File Provider Extension are written in **Swift**. The Go engine runs inside the long-running daemon (`OneLake.app/Contents/Helpers/ofem`); the Swift targets are thin clients that reach it over JSON-RPC on a Unix-domain socket (see "Swift ↔ Go boundary" below). There is no cgo: the Swift targets link no Go archive.

## Go libraries

### Authentication

- [`github.com/AzureAD/microsoft-authentication-library-for-go`](https://github.com/AzureAD/microsoft-authentication-library-for-go) — MSAL Go. Public client app, interactive browser flow, device code flow, silent refresh, cache extensibility.
- [`github.com/zalando/go-keyring`](https://github.com/zalando/go-keyring) — macOS Keychain access without cgo dependencies. Implements MSAL's `cache.ExportReplace`.

### HTTP & OneLake

- `net/http` from stdlib for the OneLake DFS calls. Custom client wrapper for:
  - Token injection (`Authorization: Bearer …`).
  - Retry-After honoring on 429 / 503.
  - Per-account concurrency limiter (default 4, configurable).
- [`github.com/hashicorp/go-retryablehttp`](https://github.com/hashicorp/go-retryablehttp) — battle-tested retry wrapper that respects `Retry-After`.
- Native JSON via stdlib `encoding/json` (no need for a faster JSON lib at our volume).

### Daemon entry point

- [`github.com/spf13/cobra`](https://github.com/spf13/cobra) — used only for the daemon binary's `daemon run` subcommand wiring and `--version` flag. Not a user-facing CLI surface.

### Config & data

- TOML via [`github.com/BurntSushi/toml`](https://github.com/BurntSushi/toml) — the Go standard. Viper supports it natively.
- SQLite via [`modernc.org/sqlite`](https://pkg.go.dev/modernc.org/sqlite) (pure-Go, no cgo) — for the local file metadata cache (paths, etags, mtimes, sync state).

### Logging

- `log/slog` from stdlib (Go 1.21+). Structured logging with JSON or text handler. No external dependency.
- Log files in `~/Library/Group Containers/group.dev.debruyn.ofem/log/ofem.log`, rotated with [`gopkg.in/natefinch/lumberjack.v2`](https://github.com/natefinch/lumberjack).

### Telemetry

- [`github.com/microsoft/ApplicationInsights-Go`](https://github.com/microsoft/ApplicationInsights-Go) — official App Insights SDK for Go. Telemetry client with batching and offline buffer.
- Custom panic-handler that flushes telemetry before re-panicking.

### IPC (host app / extension ↔ daemon)

- `net.Listen("unix", …)` from stdlib for the Unix domain socket.
- JSON-RPC 2.0 over the socket using `net/rpc/jsonrpc` from stdlib, or a lightweight custom protocol if jsonrpc proves limiting.

### LaunchAgent

- `dev.debruyn.ofem.daemon.plist` ships inside `OneLake.app/Contents/Library/LaunchAgents/`. The host app registers it via `SMAppService.agent(plistName:)` on first launch and unregisters it on quit. No `launchctl` calls from our own code.

### Testing

- `testing` from stdlib.
- [`github.com/stretchr/testify`](https://github.com/stretchr/testify) for assertions and table-driven test ergonomics.
- [`github.com/jarcoal/httpmock`](https://github.com/jarcoal/httpmock) for HTTP-level mocking of OneLake responses in unit tests.
- Integration tests use a real Fabric workspace dedicated to OFEM testing, gated behind an env var `OFEM_INTEGRATION=1` so they only run when explicitly requested.

### Code quality

- `gofmt` + `goimports` on save / pre-commit.
- [`github.com/golangci/golangci-lint`](https://github.com/golangci/golangci-lint) in CI with a curated config (errcheck, govet, staticcheck, revive, gosec, etc.).
- [`commitlint`](https://commitlint.js.org/) in CI for Conventional Commits enforcement.

## Swift libraries

### Host app

- SwiftUI (macOS 14+ baseline) for the account-management UI.
- [`Sparkle`](https://sparkle-project.org/) is **not** used — updates are Homebrew-only.

### File Provider Extension

- Apple's `FileProvider` framework (built-in).
- Apple's `os.log` for unified logging that integrates with Console.app.

### Swift ↔ Go boundary

- The daemon owns the Go engine, cache, and blob store and exposes them as
  JSON-RPC 2.0 methods (`fp.enumerate`, `fp.fetchContents`, `fp.createItem`,
  …) over a Unix-domain socket in the App Group container.
- Both Swift targets share `apple/Shared/IPCClient.swift` (the JSON-RPC
  client) and `apple/Shared/CoreBridge.swift` (typed wrappers + error
  mapping). No cgo, no static Go archive linked into Swift.
- File contents cross the boundary through the shared App Group container:
  a fetch is staged there by the daemon and moved to the macOS-supplied
  URL; an upload's source is copied in for the daemon to read.

## Build & release

- `xcodebuild` builds the Swift `.app` and `.appex`. The Xcode postBuildScript compiles the Go daemon binary into `Contents/Helpers/ofem` and signs it with the daemon entitlements.
- `codesign --force --options runtime --sign "Developer ID Application: …"` re-seals the outer bundle.
- `xcrun notarytool submit … --wait` and `xcrun stapler staple`.
- DMG via `create-dmg` (Homebrew formula `create-dmg`).
- The release workflow uploads the DMG to GitHub Releases and pushes the rendered cask to the `homebrew-ofem` tap repo.

See [docs/packaging-homebrew.md](packaging-homebrew.md) for the full pipeline.

## Repository layout

```
onelake-explorer-macos/
├── cmd/
│   └── ofem/                 # daemon entry-point binary (bundled in OneLake.app/Contents/Helpers/)
├── internal/
│   ├── auth/                # MSAL wrapper, Keychain cache, account registry
│   ├── onelake/             # DFS API client, retries, pagination
│   ├── fabric/              # Fabric REST API client (discovery)
│   ├── cache/               # SQLite metadata cache, LRU eviction
│   ├── sync/                # Sync engine, write queue, conflict resolution
│   ├── fp/                  # File Provider model served to the extension over IPC
│   ├── daemon/             # Long-running service: owns the engine + IPC server
│   ├── ipc/                 # Unix socket server + client
│   ├── telemetry/           # App Insights client
│   ├── config/              # TOML config loading
│   └── log/                 # slog setup, lumberjack rotation
├── apple/
│   ├── OneLake.xcodeproj
│   ├── OneLake/             # host app (Swift)
│   └── OneLakeFileProvider/ # extension (.appex, Swift)
├── docs/
├── homebrew/
│   └── Casks/ofem.rb.tmpl    # cask template, rendered and pushed by the release workflow
├── .github/
├── go.mod
├── go.sum
├── LICENSE
├── README.md
├── CONTRIBUTING.md
├── SECURITY.md
├── CODE_OF_CONDUCT.md
└── CLAUDE.md
```
