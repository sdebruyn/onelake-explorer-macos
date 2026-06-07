# Swift Migration Plan

> **Status**: Adopted — Optie 3 (FPE-only) gekozen door maintainer Sam Debruyn op 2026-06-07.
> See also: `docs/adr/0001-swift-migration.md`.

---

## Executive Summary

OFEM's current architecture embeds a Go daemon inside the macOS app bundle. On
2026-06-07 ten consecutive releases revealed that Apple's security stack
(App Sandbox, TCC, Launch Constraints, code-sealing) structurally rejects a
Go binary packed inside a Swift `.app`. This document is the output of a
full architecture review and presents a phased plan to migrate the Go core
entirely into Swift, co-located with the File Provider Extension.

**Chosen architecture: Option 3 — all engine logic inside the FPE, host app
communicates via `NSFileProviderService` XPC.**

Estimated effort: **6–9 months part-time**. The plan is phased so that each
phase ships a working, releasable OFEM build.

---

## Part 1 — Current Architecture Inventory

### 1.1 Go core packages

| Package | Responsibility |
|---------|----------------|
| `cmd/ofem/` | Daemon entry-point; starts the IPC server |
| `internal/auth/` | MSAL Go: multi-tenant, multi-account token acquisition and cache |
| `internal/onelake/` | ADLS Gen2 DFS HTTP client (read/list/upload/delete) |
| `internal/fabric/` | Fabric REST client (workspace + item discovery) |
| `internal/cache/` | SQLite metadata cache (workspaces, items, etags) |
| `internal/sync/` | Sync coordinator: reconcile FPE domain ↔ OneLake state |
| `internal/fp/` | File Provider domain model (item identifiers, placeholders) |
| `internal/ipc/` | Unix socket JSON-RPC server |
| `internal/daemon/` | Daemon lifecycle (signal handling, PID file) |
| `internal/telemetry/` | App Insights opt-out telemetry |
| `internal/config/` | Config file reader (TOML) |
| `internal/log/` | Structured logger (zerolog) |

### 1.2 Swift targets

| Target | Responsibility |
|--------|----------------|
| `apple/OneLake/` | Menu bar host app; thin JSON-RPC client over Unix socket |
| `apple/OneLakeFileProvider/` | File Provider Extension; thin JSON-RPC relay to daemon |
| `apple/Shared/` | Shared IPC client (`IPCClient.swift`, `CoreBridge.swift`, `IPCTransport.swift`, `StatusTypes.swift`) |

### 1.3 Key data flows (current)

```
Finder ──► FPE (Swift) ──► Unix socket ──► Go daemon
                                              ├── MSAL (auth)
                                              ├── ADLS Gen2 (I/O)
                                              ├── Fabric REST (discovery)
                                              └── SQLite (cache)

Menu bar app (Swift) ──► Unix socket ──► Go daemon
```

### 1.4 Authentication details

- **Library**: `github.com/AzureAD/microsoft-authentication-library-for-go`
- **Pattern**: one `PublicClientApplication` per account alias, persisted in
  the macOS Keychain via MSAL's `KeychainTokenCache`.
- **Audiences**: two distinct — `https://storage.azure.com/` (ADLS Gen2) and
  `https://analysis.windows.net/powerbi/api` (Fabric REST). A single audience
  token returns 401 on the other endpoint.
- **Tenants**: multi-tenant App Registration; per-account tenant ID stored in
  TOML config.

### 1.5 OneLake API details

- **Listing / stat**: ADLS Gen2 DFS endpoint (`dfs.fabric.microsoft.com`),
  `filesystem` + `path` operations.
- **Download**: DFS `path?action=read`, streaming.
- **Upload**: DFS `path?action=write` + `flush`, chunked.
- **Discovery**: Fabric REST (`api.fabric.microsoft.com`), workspace list and
  item list endpoints.

### 1.6 IPC protocol (current)

JSON-RPC 2.0 over a Unix domain socket at
`~/Library/Application Support/dev.debruyn.ofem/daemon.sock`. Methods include
`auth.addAccount`, `auth.listAccounts`, `auth.removeAccount`, `sync.status`,
`onelake.stat`, `onelake.download`, `onelake.upload`, `onelake.list`, etc.

---

## Part 2 — Swift Equivalents

| Go component | Swift equivalent | Notes |
|---|---|---|
| MSAL Go | MSAL for Apple (Swift/ObjC) | Same Microsoft library, same Entra App Registration |
| ADLS Gen2 HTTP client | `URLSession` + async/await | Native; no third-party HTTP lib needed |
| Fabric REST client | `URLSession` + async/await | Same |
| SQLite (go-sqlite3) | GRDB (pure Swift SQLite wrapper) or CoreData | GRDB recommended: familiar SQL, no ORM overhead |
| zerolog | `os.Logger` (unified logging) | Native macOS structured logging |
| TOML config | Custom `Codable` decoder or TOMLKit | TOMLKit is lightweight; or switch to plist |
| Unix socket IPC server | `NSFileProviderService` + XPC | Apple-approved; no separate process |
| Unix socket IPC client | `NSFileProviderManager` service lookup | Replaces `apple/Shared/` |
| SQLite WAL | GRDB pool with WAL mode | Direct translation |
| Keychain token cache | `MSALKeychainTokenCache` | MSAL Swift handles this natively |

---

## Part 3 — Architecture Options Evaluated

Three architectures were evaluated before the decision.

### Option 1 — XPC Service (Login Item, Swift)

A separate Swift XPC service replaces the Go daemon. The FPE and host app
both connect to this XPC service. Like the current daemon but in Swift.

**Pros**: clean separation, XPC is Apple-native.
**Cons**: adds a third process with its own entitlement surface; the FPE is
already the correct locus per Apple's File Provider guidelines; two out-of-
process components add latency and lifecycle complexity.

**Status: Rejected.**

### Option 2 — Thin XPC Service (Swift) + Fat FPE (Swift)

The FPE owns auth and all I/O. A thin XPC service (no engine logic) bridges
the host app to the FPE via `NSFileProviderService`.

**Pros**: clean process separation; FPE memory budget can be managed.
**Cons**: still two processes; `NSFileProviderService` already provides the
bridge — the extra XPC service is redundant.

**Status: Rejected in favour of Option 3.**

### Option 3 — FPE-Only (all engine in FPE) ✅ CHOSEN

All engine logic (auth, HTTP clients, cache, sync) lives inside the File
Provider Extension. The host app (menu bar) communicates with the FPE
exclusively through `NSFileProviderService` XPC — the Apple-approved channel.

**Pros**:
- Fewest processes (2: host app + FPE).
- `NSFileProviderService` is exactly what Apple designed for this pattern.
- FPE already runs inside the approved sandbox — no new entitlement surface.
- NextCloud Desktop uses this exact pattern successfully.
- Simplest packaging and notarization (no daemon bundle, no LaunchAgent).

**Cons**:
- FPE memory budget requires monitoring (Apple can terminate memory-heavy
  extensions). Mitigated by lazy loading and streaming.
- All engine code must be available inside the extension sandbox.

**Status: Accepted — chosen by Sam Debruyn on 2026-06-07.**

#### Target architecture (Option 3)

```
Finder ──► FPE (Swift)
             ├── OfemKit/Auth  (MSAL Swift)
             ├── OfemKit/OneLake (URLSession)
             ├── OfemKit/Fabric  (URLSession)
             ├── OfemKit/Cache   (GRDB / SQLite)
             └── OfemKit/Sync

Menu bar app (Swift) ──► NSFileProviderService XPC ──► FPE
```

The `OfemKit` Swift Package is the shared engine library. It is linked into
the FPE target and — where the sandbox allows — also into the host app target
for configuration and status queries that do not require file I/O.

---

## Part 4 — Seven-Phase Migration Plan

Each phase ends with a shippable OFEM build. The Go daemon remains running and
functional until Phase 6.

### Phase 0 — Foundation (this PR)

**Goal**: lock in the direction; lay the skeleton.

Deliverables:
- `docs/adr/0001-swift-migration.md` — ADR recorded and accepted.
- `docs/swift-migration-plan.md` — this document.
- `apple/Packages/OfemKit/` — Swift Package skeleton (`OfemKit` library +
  placeholder source + test target).

No existing Go or Swift code changes. The package is not yet linked into
Xcode targets.

### Phase 1 — Auth Module (`OfemKit/Auth`)

**Goal**: replace `internal/auth/` with a Swift MSAL implementation.

Deliverables:
- `OfemKit/Sources/Auth/` — `MSALPublicClientApplication` wrapper, multi-
  tenant, multi-account, Keychain-backed.
- Token acquisition for both audiences (`storage.azure.com` and
  `analysis.windows.net/powerbi/api`).
- `OfemKitTests/AuthTests` — unit tests with MSAL mock.
- Integration test against a real tenant (guarded by `OFEM_INTEGRATION=1`).

Key risk to resolve: measure Keychain item size for N accounts across M tenants.
If approaching 16 KB limit, implement per-account Keychain items rather than a
single serialised cache.

The Go daemon continues to serve auth; the new Swift module is tested in
isolation.

### Phase 2 — HTTP Clients (`OfemKit/OneLake`, `OfemKit/Fabric`)

**Goal**: replace `internal/onelake/` and `internal/fabric/` with
URLSession-based Swift clients.

Deliverables:
- `OfemKit/Sources/OneLake/` — ADLS Gen2 DFS client: list, stat, download
  (streaming), upload (chunked), delete.
- `OfemKit/Sources/Fabric/` — Fabric REST client: workspace list, item list.
- Shared `OfemKit/Sources/HTTPCore/` — URLSession configuration, retry,
  throttling, error mapping.
- Tests against the ADLS Gen2 mock + `OFEM_INTEGRATION=1` live tenant tests.

### Phase 3 — Cache Layer (`OfemKit/Cache`)

**Goal**: replace `internal/cache/` with a GRDB-backed Swift cache.

Deliverables:
- `OfemKit/Sources/Cache/` — SQLite schema (workspaces, items, etags, sync
  state), GRDB migrations, WAL mode.
- Cache lives in the FPE's container
  (`~/Library/Application Support/<FPE bundle ID>/ofem.db`).
- Schema is compatible with the existing Go-daemon schema so that no cache
  cold-start is needed when switching from the daemon to the FPE engine.
- Tests: in-memory GRDB for unit tests, file-backed for integration.

### Phase 4 — Sync Coordinator + FPE Engine Switch

**Goal**: replace `internal/sync/` and `internal/fp/` with Swift
equivalents embedded in the FPE. The FPE drives the engine directly;
the Go daemon is no longer used by the FPE.

Deliverables:
- `OfemKit/Sources/Sync/` — reconciliation loop, placeholder materialisation,
  upload queue, conflict resolution (last-write-wins, matching current Go
  behaviour).
- `apple/OneLakeFileProvider/FileProviderExtension.swift` rewritten to call
  `OfemKit` directly instead of forwarding to the daemon.
- `apple/OneLakeFileProvider/` test suite expanded.
- **Feature flag**: a compile-time flag (`OFEM_SWIFT_ENGINE`) allows switching
  between the Go daemon relay and the new Swift engine. Disabled by default
  in the first merge; enabled in a follow-up after soak testing.
- Performance profiling: measure FPE memory under realistic workloads; tune
  GRDB pool size and URLSession configuration.

This is the highest-risk phase. It is recommended to split it into two PRs:
4a (engine wiring without the flag enabled) and 4b (enable the flag, ship).

### Phase 5 — `NSFileProviderService` XPC Client in Host App

**Goal**: replace the Unix socket IPC in the host app
(`apple/Shared/`, `apple/OneLake/`) with `NSFileProviderService` XPC calls
to the FPE.

Deliverables:
- `OfemKit/Sources/XPCService/` — `NSFileProviderServiceProtocol`
  definition; both sides implement it (FPE exports the service, host app
  consumes it).
- `apple/OneLake/` rewritten to use `NSFileProviderManager` service lookup
  instead of `IPCClient.swift`.
- `apple/Shared/` removed (or kept as empty stub until Phase 7 cleanup).
- The Go daemon IPC server (`internal/ipc/`) is still running but no longer
  consumed by any Swift target.

### Phase 6 — Remove Go Daemon

**Goal**: remove the Go daemon entirely; update packaging and CI.

Deliverables:
- `cmd/ofem/`, `internal/` — removed.
- `go.mod`, `go.sum` — removed (or kept as empty module if needed for
  tooling; to be decided).
- `apple/project.yml` — `OfemDaemon` sub-bundle and LaunchAgent references
  removed.
- `apple/LaunchAgents/` — removed.
- `Makefile` — daemon build steps removed; `make app` builds Swift-only.
- `.github/workflows/` — Go lint, Go test steps removed; Swift test added.
- Homebrew cask — daemon binary no longer in the bundle; cask SHA updated.
- `docs/tech-stack.md` updated to reflect Swift-only stack.

### Phase 7 — Cleanup and Hardening

**Goal**: remove residual IPC scaffolding; production hardening.

Deliverables:
- `apple/Shared/` removed if not done in Phase 5.
- Telemetry ported from Go App Insights SDK to Swift App Insights SDK
  (or Azure Monitor Ingestion endpoint via URLSession).
- FPE memory profiling under Instruments; optimise hot paths.
- `OfemKit` API review: public surface locked to `@_spi` or `public` as
  appropriate.
- End-to-end test suite: Phase 0–7 regression coverage.
- Update all `docs/` to reflect the new architecture.

---

## Part 5 — Comparison: Current vs Target

| Dimension | Current (Go daemon) | Target (Swift FPE-only) |
|-----------|--------------------|-----------------------|
| Processes | 3 (host, FPE, daemon) | 2 (host, FPE) |
| Languages | Go + Swift | Swift only |
| IPC | Unix socket JSON-RPC | `NSFileProviderService` XPC |
| Auth | MSAL Go + Keychain | MSAL Swift + Keychain |
| HTTP | `net/http` (Go) | URLSession (native) |
| DB | go-sqlite3 + WAL | GRDB + WAL |
| Sandbox compatibility | Structurally broken | Native |
| App Sandbox entitlements | Two entitlement sets | One entitlement set (FPE) |
| TCC | Blocked on Go sub-bundle | Native FPE container |
| Launch Constraints | Unsatisfiable for Go binary | N/A — FPE is host-spawned |
| App Review eligibility | Blocked | Unblocked |
| Binary size | Go static + Swift | Swift only (smaller) |
| Build toolchain | Go + Xcode | Xcode only |
| CI | Go lint + Swift build | Swift build + test only |

---

## Part 6 — Risks and Mitigations

### R1 — MSAL Keychain size limit

**Risk**: Apple Generic Password Keychain items are limited to ~16 KB. With
many accounts across many tenants, MSAL's token cache may exceed this.

**Mitigation**: in Phase 1, implement and measure per-account Keychain items
(`MSALKeychainTokenCache` with per-account identifiers). If the limit is
still approached, implement a token refresh-on-demand strategy and avoid
caching large ID tokens.

**Owner**: Phase 1.

### R2 — FPE memory budget

**Risk**: Apple can terminate a File Provider Extension that consumes too much
memory. Embedding a full HTTP stack + SQLite + sync coordinator in the FPE
increases the memory footprint significantly over the current thin relay.

**Mitigation**: profile in Phase 4 using Instruments. Implement lazy loading
for GRDB pool, cap URLSession URL caches, use `NSPurgeable` data where
appropriate.

**Owner**: Phase 4.

### R3 — Double-engine period (Phases 1–5)

**Risk**: both the Go daemon and the Swift engine are active simultaneously.
Risk of double-auth, cache conflicts, or duplicate sync events.

**Mitigation**: the FPE continues to relay to the Go daemon through Phase 3.
The Swift engine is activated only in Phase 4 via a compile-time flag that is
disabled in the initial merge. The Go daemon's IPC server remains running but
the FPE stops connecting to it. Cache schema is kept compatible.

**Owner**: Phase 4.

### R4 — MSAL Swift vs MSAL Go behavioural differences

**Risk**: MSAL Swift and MSAL Go may differ in token cache key formats,
refresh token handling, or conditional access responses. Switching auth
libraries mid-flight could force users to re-authenticate.

**Mitigation**: in Phase 1, validate that MSAL Swift's Keychain format is
compatible with MSAL Go's format, or implement a one-time migration that
reads the old format and re-serialises. Worst case: users are prompted to
re-authenticate once during the Phase 1 rollout.

**Owner**: Phase 1.

### R5 — `NSFileProviderService` XPC latency

**Risk**: `NSFileProviderService` XPC adds IPC latency for menu bar
interactions (status, account management). Currently the host app talks
directly to the daemon over a Unix socket which is very fast.

**Mitigation**: measure XPC round-trip latency in Phase 5. For status
queries, cache the last-known state in the host app and update asynchronously.
For account management operations, the latency is acceptable (user-initiated,
infrequent).

**Owner**: Phase 5.

### R6 — FPE sandbox restricts writable paths

**Risk**: the FPE sandbox may not allow writes to paths currently used by
the Go daemon (e.g. `~/Library/Application Support/dev.debruyn.ofem/`).

**Mitigation**: the FPE gets its own container directory
(`~/Library/Application Support/<FPE bundle ID>/`) which is writable. The
cache and config are moved there in Phase 3. The Go daemon's directory
remains untouched until Phase 6 cleanup.

**Owner**: Phase 3.

---

## Part 7 — Recommendation and Decision

**Chosen: Option 3 (FPE-only, `NSFileProviderService` XPC).**

This was chosen over the alternatives for the following reasons:

1. **Fewest processes.** Two processes (host app + FPE) is the minimal viable
   architecture for a File Provider app. Any additional process adds
   entitlement surface and lifecycle complexity.

2. **Apple-native IPC.** `NSFileProviderService` is the channel Apple designed
   for exactly this use case: a host app communicating with its own FPE. It has
   no TCC or Launch Constraint issues.

3. **Proven pattern.** NextCloud Desktop (`nextcloud-desktop`) uses this exact
   architecture for its macOS sync client. The pattern is well-documented and
   battle-tested.

4. **Simplest packaging.** No daemon bundle, no LaunchAgent, no sub-bundle
   signing ceremony. The Homebrew cask becomes a straightforward `.app`
   install.

5. **App Review eligibility.** A pure-Swift `.app` with no embedded foreign
   binaries has a clear path to Mac App Store distribution, which is a future
   milestone for OFEM.

The trade-offs (FPE memory budget, MSAL Keychain limit) are manageable and are
explicitly tracked as risks R1 and R2 above.

**Start date**: 2026-06-07 (Phase 0, this PR).
**Target completion**: end of 2026 Q4 (assuming part-time, solo maintainer).

---

*Document prepared 2026-06-07 by a research agent during the OFEM architecture
review session. Adopted and committed as part of PR #167
(`feat(architecture): kick off Swift migration with ADR and OfemKit skeleton`).*
