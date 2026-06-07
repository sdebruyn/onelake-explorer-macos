# ADR 0001 — Migrate Go Core to Swift (FPE-Only Architecture)

| Field       | Value                                     |
|-------------|-------------------------------------------|
| Status      | Accepted                                  |
| Date        | 2026-06-07                                |
| Deciders    | Sam Debruyn (maintainer)                  |
| Supersedes  | —                                         |

## Context

OFEM's current architecture splits responsibility across two processes:

1. **Go daemon** (`cmd/ofem/` + `internal/`) — runs as a sub-bundle
   (`OneLake.app/Contents/Library/LoginItems/OfemDaemon.bundle`) registered
   through `SMAppService`. Owns auth (MSAL), OneLake/Fabric API calls,
   the metadata cache (SQLite), sync coordination, and IPC serving over a
   Unix socket.
2. **Swift host app** (`apple/OneLake/`) — menu bar UI; thin JSON-RPC
   client over the daemon's Unix socket.
3. **Swift File Provider Extension** (`apple/OneLakeFileProvider/`) — FPE;
   thin JSON-RPC client; delegates all real work to the daemon.

### The Sandbox Cascade (2026-06-07)

On 2026-06-07 ten releases (v2026.06.1 through v2026.06.10) shipped in a
single day, each uncovering yet another layer of Apple's sandbox/security
stack that rejects a Go binary embedded inside a Swift app bundle:

| Release | Issue surfaced |
|---------|----------------|
| v2026.06.1 | `.plist` extension in `SMAppService` identifier |
| v2026.06.2 | Sealing in `CodeResources` |
| v2026.06.3 | `BundleProgram` vs `ProgramArguments` in launchd plist |
| v2026.06.4 | App Sandbox entitlement missing from daemon |
| v2026.06.5 | Restricted `keychain-access-groups` on daemon (removed) |
| v2026.06.6 | Bundle-style signing identifier required |
| v2026.06.7 | Launch Constraints — self constraint |
| v2026.06.8 | Launch Constraints — SpawnConstraint from host |
| v2026.06.9 | Sub-bundle restructuring (Go binary has no `__TEXT,__info_plist` section, no cgo) |
| v2026.06.10 | TCC refuses the sub-bundle: "would require prompt" |

Each fix revealed the next constraint. The cascade has no visible floor:
a Go binary built without cgo cannot embed an `Info.plist` section, cannot
satisfy Launch Constraints natively, and is structurally invisible to TCC.
Workarounds grow exponentially more complex with each Apple OS release.

### Root Cause

Apple's security stack (App Sandbox, TCC, Launch Constraints, Gatekeeper,
code-sealing) was designed for the Objective-C/Swift/XPC ecosystem. A
pure-Go binary inside an `.app` bundle is a second-class citizen that
requires a growing list of workarounds — workarounds that break again with
every macOS update.

The File Provider Extension already runs inside the correct Apple sandbox.
The host app already runs inside the correct Apple sandbox. The daemon is
the only component that does not belong.

## Decision

**Migrate all engine logic from the Go daemon into the File Provider
Extension itself, implemented in Swift.**

The host app communicates with the FPE through
`NSFileProviderService` + XPC, replacing the current Unix socket IPC.
There is no separate daemon process. There is no Go runtime in the
distributed app bundle. This is the architecture used by NextCloud
Desktop (`nextcloud-desktop`, aka NextSync/NCDesktop) and other
first-party iCloud-alike providers.

This is **Option 3 (FPE-only)** from the architecture evaluation that preceded
this decision (see `docs/swift-migration-plan.md`, §3 for the full option
comparison; the alternatives listed below use a different numbering).

### What moves where

| Current component | Destination |
|-------------------|-------------|
| `internal/auth/` (MSAL) | `apple/Packages/OfemKit/Sources/` (MSAL.framework or MSAL Swift SDK) |
| `internal/onelake/` (ADLS Gen2) | `apple/Packages/OfemKit/Sources/` (URLSession) |
| `internal/fabric/` (Fabric REST) | `apple/Packages/OfemKit/Sources/` (URLSession) |
| `internal/cache/` (SQLite) | `apple/Packages/OfemKit/Sources/` (GRDB or CoreData) |
| `internal/sync/` | `apple/Packages/OfemKit/Sources/` |
| `internal/fp/` (FP domain model) | `apple/Packages/OfemKit/Sources/` |
| `internal/ipc/` (Unix socket server) | Removed — replaced by `NSFileProviderService` XPC |
| `internal/daemon/` (daemon runner) | Removed |
| `cmd/ofem/` (daemon binary) | Removed |
| `apple/Shared/` (IPC client) | Replaced by `NSFileProviderService` client |

The FPE (`apple/OneLakeFileProvider/`) grows from a thin IPC relay into
the full engine. `OfemKit` is a Swift Package that houses the reusable
engine modules, shared between the FPE and (where permitted) the host app.

### Migration is phased

The Go daemon (v2026.06.10) and the existing Swift IPC clients remain
fully functional during migration. Phases are described in detail in
`docs/swift-migration-plan.md`.

Summary of the 7 phases:

| Phase | Deliverable |
|-------|-------------|
| 0 | ADR + `OfemKit` Swift Package skeleton (this PR) |
| 1 | Auth module in Swift (`OfemKit/Auth`) + Keychain backend |
| 2 | OneLake + Fabric HTTP clients in Swift |
| 3 | SQLite / GRDB cache layer in Swift |
| 4 | Sync coordinator in Swift; FPE drives engine directly |
| 5 | `NSFileProviderService` XPC replaces Unix socket IPC |
| 6 | Remove Go daemon; update packaging, CI, Makefile |
| 7 | Host app ported to `NSFileProviderService` client; Shared/ removed |

## Consequences

### Positive

- The FPE runs entirely inside Apple's approved sandbox model. No more
  sandbox-cascade releases.
- `NSFileProviderService` XPC is the Apple-approved IPC pattern between a
  host app and its FPE — it has none of the TCC / Launch Constraint issues
  of a launchd-registered Go sub-bundle.
- No Go runtime in the distributed bundle → smaller download, simpler
  notarization, no cross-language debugging.
- Swift native Keychain / URLSession / CryptoKit APIs align with what
  Apple's security reviews expect.
- Single language across the entire codebase.

### Negative / Risks

- **Effort**: estimated 6–9 months part-time across 7 phases.
- **MSAL token cache**: the Microsoft Authentication Library for Swift
  stores tokens in the Keychain. Apple Generic Password items have a
  ~16 KB per-item limit. With many accounts across many tenants the
  accumulated token cache may approach this limit. Mitigation: evaluate
  MSAL's `MSALSerializedADALCacheDeserializer` sharding strategy in
  Phase 1.
- **FPE memory budget**: Apple can terminate a FPE if it consumes too
  much memory. Embedding a full HTTP stack + cache in the extension
  requires profiling (Phase 4).
- **Parallel go/swift runtime period**: during Phases 1–5 both the Go
  daemon and the Swift engine coexist. Careful feature-flag or
  compile-time switching needed to avoid double-auth or cache conflicts.

## Alternatives Considered

### Option 1 — Status Quo (rejected)

Keep the Go daemon, continue patching sandbox issues one by one.

*Rejected*: the cascade has no floor. Each macOS major release can
introduce new constraints. The cost of maintenance grows super-linearly
and every regression blocks users immediately.

### Option 2 — XPC Service (Swift) alongside the FPE (rejected)

Replace the Go daemon with a Swift XPC service registered as a Login Item,
keeping the FPE as a thin relay.

*Rejected*: adds a second out-of-process component with its own entitlement
surface and its own Sandbox/TCC exposure. The FPE is already the correct
locus — routing through an extra XPC service adds complexity without benefit.

### Option 3 — Go daemon replaced by a separate Go XPC helper (rejected)

Port the Go daemon to speak XPC via `cgo` + `Foundation`.

*Rejected*: `cgo` reintroduces the embedded C runtime which triggers its
own Gatekeeper / App Sandbox edge cases, and XPC bridging via cgo is poorly
documented and fragile across macOS versions.

### Option 4 — Sub-bundle Go binary with increased entitlements (rejected)

Continue the sub-bundle approach but request broader entitlements
(`com.apple.security.temporary-exception.*`) to bypass TCC for the Go binary.

*Rejected*: Apple rejects apps in App Review that use temporary exceptions
without a compelling justification. OFEM targets the Mac App Store in a
future milestone.

## References

- Ten sandbox-cascade releases:
  [v2026.06.1](https://github.com/sdebruyn/onelake-explorer-macos/releases/tag/v2026.06.1) ·
  [v2026.06.2](https://github.com/sdebruyn/onelake-explorer-macos/releases/tag/v2026.06.2) ·
  [v2026.06.3](https://github.com/sdebruyn/onelake-explorer-macos/releases/tag/v2026.06.3) ·
  [v2026.06.4](https://github.com/sdebruyn/onelake-explorer-macos/releases/tag/v2026.06.4) ·
  [v2026.06.5](https://github.com/sdebruyn/onelake-explorer-macos/releases/tag/v2026.06.5) ·
  [v2026.06.6](https://github.com/sdebruyn/onelake-explorer-macos/releases/tag/v2026.06.6) ·
  [v2026.06.7](https://github.com/sdebruyn/onelake-explorer-macos/releases/tag/v2026.06.7) ·
  [v2026.06.8](https://github.com/sdebruyn/onelake-explorer-macos/releases/tag/v2026.06.8) ·
  [v2026.06.9](https://github.com/sdebruyn/onelake-explorer-macos/releases/tag/v2026.06.9) ·
  [v2026.06.10](https://github.com/sdebruyn/onelake-explorer-macos/releases/tag/v2026.06.10)
- Full seven-phase migration plan: `docs/swift-migration-plan.md`
- NextCloud Desktop (FPE-only architecture reference):
  <https://github.com/nextcloud/desktop>
- Apple File Provider documentation:
  <https://developer.apple.com/documentation/fileprovider>
- `NSFileProviderService` XPC API:
  <https://developer.apple.com/documentation/fileprovider/nsfileproviderservice>
- Microsoft Authentication Library (MSAL) for Apple:
  <https://github.com/AzureAD/microsoft-authentication-library-for-objc>
