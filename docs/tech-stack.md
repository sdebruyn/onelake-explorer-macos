# Tech stack

## Language: Go for core + CLI, Swift for host app and File Provider Extension

The core library, CLI, and daemon are written in **Go**. The macOS `.app` host and the File Provider Extension are written in **Swift**. The Go core ships as a static library (`libofemcore.a`) plus a generated C header (via cgo's `//export` directives) that Swift imports.

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

### CLI

- [`github.com/spf13/cobra`](https://github.com/spf13/cobra) — standard Go CLI framework. Subcommands, flags, completions, man-page generation.
- [`github.com/spf13/viper`](https://github.com/spf13/viper) — config-file loading, env-var binding (`OFEM_*`).

### Config & data

- TOML via [`github.com/BurntSushi/toml`](https://github.com/BurntSushi/toml) — the Go standard. Viper supports it natively.
- SQLite via [`modernc.org/sqlite`](https://pkg.go.dev/modernc.org/sqlite) (pure-Go, no cgo) — for the local file metadata cache (paths, etags, mtimes, sync state).

### Logging

- `log/slog` from stdlib (Go 1.21+). Structured logging with JSON or text handler. No external dependency.
- Log files in `~/Library/Logs/dev.debruyn.ofem/ofem.log`, rotated with [`gopkg.in/natefinch/lumberjack.v2`](https://github.com/natefinch/lumberjack).

### Telemetry

- [`github.com/microsoft/ApplicationInsights-Go`](https://github.com/microsoft/ApplicationInsights-Go) — official App Insights SDK for Go. Telemetry client with batching and offline buffer.
- Custom panic-handler that flushes telemetry before re-panicking.

### IPC (CLI ↔ daemon)

- `net.Listen("unix", …)` from stdlib for the Unix domain socket.
- JSON-RPC 2.0 over the socket using `net/rpc/jsonrpc` from stdlib, or a lightweight custom protocol if jsonrpc proves limiting.

### LaunchAgent

- We ship a `dev.debruyn.ofem.plist` template. The CLI writes the resolved plist to `~/Library/LaunchAgents/` and runs `launchctl bootstrap gui/$UID …` to register it. No external dependency needed.

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

### Bridge to Go

- cgo's `//export Foo` produces `Foo` symbols callable from C. We generate a header `libofemcore.h` during `go build -buildmode=c-archive`.
- Swift imports `libofemcore.h` via a bridging header.
- All callbacks across the boundary use C primitives (`char*`, `int64_t`, opaque pointers) — no Go strings or Swift `String` directly.

## Build & release

- [`GoReleaser`](https://goreleaser.com/) builds the Go binaries.
- A separate `xcodebuild` step builds the Swift `.app` and `.appex`, linking against the Go static library.
- `codesign --force --options runtime --sign "Developer ID Application: …"`.
- `xcrun notarytool submit … --wait` and `xcrun stapler staple`.
- DMG via `create-dmg` (Homebrew formula `create-dmg`).
- GoReleaser uploads the DMG to GitHub Releases and bumps the cask in the `homebrew-ofem` tap repo.

See [docs/packaging-homebrew.md](packaging-homebrew.md) for the full pipeline.

## Repository layout

```
onelake-explorer-macos/
├── cmd/
│   └── ofem/                 # CLI entrypoint (main package)
├── internal/
│   ├── auth/                # MSAL wrapper, Keychain cache, account registry
│   ├── onelake/             # DFS API client, retries, pagination
│   ├── fabric/              # Fabric REST API client (discovery)
│   ├── cache/               # SQLite metadata cache, LRU eviction
│   ├── sync/                # Sync engine, write queue, conflict resolution
│   ├── ipc/                 # Unix socket server + client
│   ├── telemetry/           # App Insights client
│   ├── config/              # TOML config loading
│   └── log/                 # slog setup, lumberjack rotation
├── core/                    # cgo-exported façade for Swift
│   ├── core.go              # //export symbols
│   └── core.h               # generated
├── apple/
│   ├── OneLake.xcodeproj
│   ├── OneLake/             # host app (Swift)
│   └── OneLakeFileProvider/ # extension (.appex, Swift)
├── docs/
├── homebrew/
│   └── ofem.rb               # cask template, updated by GoReleaser
├── .github/
├── .goreleaser.yaml
├── go.mod
├── go.sum
├── LICENSE
├── README.md
├── CONTRIBUTING.md
├── SECURITY.md
├── CODE_OF_CONDUCT.md
├── CLAUDE.md
└── PLAN.md
```
