# File Provider Extension — architecture and Swift ↔ Go bridge

## What is a File Provider Extension

Apple's [File Provider framework](https://developer.apple.com/documentation/fileprovider) lets a third-party app expose remote files in Finder as if they were local. It is the same mechanism used by OneDrive, Google Drive, Dropbox, Box.

The framework provides:
- Native Finder sidebar entry under "Locations".
- Per-file sync-status overlays (cloud, downloading, cached, error).
- Right-click "Always Keep on this Mac" / "Free up space".
- Lazy enumeration (folders are walked on demand).
- Background up/download with progress reporting.
- Spotlight indexing, Quick Look, Share Sheet integration.

In return, we implement a handful of Swift subclasses that describe our remote storage to macOS:

| Class | Responsibility |
|---|---|
| `NSFileProviderExtension` | Entry point; lifecycle, domain registration, root container metadata. |
| `NSFileProviderItem` (one per file/folder) | Identity, parent, type, size, modification time, capabilities, sync state. |
| `NSFileProviderEnumerator` | Lists items inside a container; supports incremental updates and search. |
| `NSFileProviderReplicatedExtension` | (macOS 13+) Replication model — we own the canonical metadata, macOS asks us for changes. |

We use the **replication model**, which is what Apple recommends for cloud storage providers since macOS 13. Old non-replicated providers are deprecated.

## Three processes, one product

```
                      ┌────────────────────────────┐
                      │   OneLake.app (host)       │
                      │   - SwiftUI account UI     │
                      │   - Menu bar status icon   │
                      │   - Registers domain(s)    │
                      └────────────┬───────────────┘
                                   │
                                   │ App Group + XPC
                                   │
       ┌───────────────────────────┴───────────────────────────┐
       │                                                       │
       ▼                                                       ▼
┌────────────────────────────┐               ┌────────────────────────────┐
│  OneLakeFileProvider.appex │               │  ofem daemon (Go)           │
│  (Swift, sandboxed)        │               │  - LaunchAgent             │
│  - NSFileProvider*         │               │  - Periodic remote refresh │
│  - Calls Go core via FFI   │               │  - Telemetry sender        │
└────────────┬───────────────┘               │  - IPC for CLI             │
             │                               └────────────┬───────────────┘
             │ cgo/C-ABI                                  │
             ▼                                            │
┌────────────────────────────┐                            │
│  libofemcore.a (Go)         │ ◄──────────────────────────┘
│  - Auth (MSAL)             │   shared as static archive
│  - OneLake DFS client      │
│  - Cache (SQLite)          │
│  - Sync engine             │
└────────────────────────────┘
```

What each process does:
- The **host app** holds the account-management UI, registers File Provider domains, talks to the system browser for auth, and writes to the App Group container.
- The **File Provider Extension** is sandboxed by Apple. macOS launches it on demand when Finder needs files. It implements the `NSFileProvider*` classes and calls into the Go core via FFI.
- The **daemon** runs as a LaunchAgent, holds the Unix socket the CLI talks to, batches telemetry, and runs adaptive polling against Fabric.

## Shared state via App Group

All three processes share one App Group identifier `group.dev.debruyn.ofem`. That gives them:
- A shared container at `~/Library/Group Containers/group.dev.debruyn.ofem/`.
- A shared Keychain access group `group.dev.debruyn.ofem`.

What lives in the shared container:
- `config.toml` — accounts, settings.
- `cache.sqlite` — file metadata cache (paths, etags, mtimes, sync state).
- `cache/<sha256>` — actual cached file blobs, sharded by hash prefix.
- `log/ofem.log` — daemon log, rotated.

What lives in the shared Keychain:
- One item per account containing the MSAL serialized token cache.

## Domain model

OFEM registers **one File Provider domain per account-alias**:
- `NSFileProviderDomain(identifier: "ofem.work", displayName: "work")`.
- `NSFileProviderDomain(identifier: "ofem.client-a", displayName: "client-a")`.

`pathRelativeToDocumentStorage` is **not** passed — it is an iOS-only
parameter. On macOS, the framework derives the mount path automatically
from `CFBundleDisplayName` (the app's bundle display name, `OneLake` in
our case) and `NSFileProviderDomain.displayName` (the alias). Passing the
parameter on macOS is a compile-time error on newer SDKs.

We pass the bare alias as `displayName`. macOS constructs the
on-disk folder as `<CFBundleDisplayName>-<displayName>`, so every
domain materialises at `~/Library/CloudStorage/OneLake-<alias>/` with
an ASCII hyphen (matching the OneDrive `OneDrive-<tenant>` and Google
Drive `GoogleDrive-<email>` conventions — verified by hexdumping real
installs). The Finder sidebar shows the system-composed label
(empirically `OneLake — <alias>` with an em-dash for OneDrive-style
products); we do not pre-join the em-dash into `displayName`, because
that would double the bundle prefix on disk (`OneLake-OneLake — work`)
and put a non-ASCII char into a path that shell completion, `grep`,
and `find` pipelines have to walk. There is no API to group multiple
domains under one custom parent like `~/OneLake/`. See [domain nesting
spike](file-provider-domain-nesting.md) for the API surface that was
investigated, why `replicatedKnownFolders` is the wrong tool, and the
reasoning behind accepting one Finder entry per account.

## Item identifiers

Every item exposed via File Provider has an `NSFileProviderItemIdentifier` (a string). The structure we use:

```
<accountAlias>/<workspaceGUID>/<itemGUID>/<path-within-item>
```

Examples:
- `work/.rootContainer` — the root for the "work" account.
- `work/8d3b…/2f1a…` — the lakehouse named "MyLH" inside workspace "FinanceWS".
- `work/8d3b…/2f1a…/Files/raw/2024/sales.csv` — a file.

Using GUIDs at workspace and item level shields us from rename churn (Microsoft preserves GUIDs on rename). The path-within-item is the human-typed path; if a folder is renamed in Fabric we get a fresh enumeration showing the new name, and our `NSFileProviderItem`s are reissued with new identifiers.

## Enumeration model

A user double-clicks a folder in Finder. macOS calls `enumerator(for: containerItemIdentifier, request:)`. Our enumerator:

1. Parses the identifier.
2. If `<accountAlias>/.rootContainer` → call Fabric REST `GET /workspaces`, return one `NSFileProviderItem` per workspace.
3. If `<accountAlias>/<workspaceGUID>` → call Fabric REST `GET /workspaces/{id}/items` + `GET /workspaces/{id}/folders`, return items + folders.
4. If `<accountAlias>/<workspaceGUID>/<itemGUID>/<path>` → call OneLake DFS `GET /{workspaceGUID}/{itemGUID}/{path}?resource=filesystem&recursive=false`, return files + folders.

Results are cached in SQLite with a TTL appropriate for the level: 30 seconds for currently-open folders, 5 minutes for the rest.

## Working set updates

For change-detection on folders the user has visited recently, the daemon (not the extension) polls Fabric on the adaptive schedule. When it finds changes, it calls `NSFileProviderManager.signalEnumerator(for:)` to tell macOS "the X container has changes, please re-enumerate". The extension's enumerator then re-fetches and produces a delta.

The daemon and extension communicate over **XPC**, wrapped around the
same JSON-RPC 2.0 protocol the CLI uses on its Unix-domain socket (see
[`internal/ipc`](../internal/ipc)). The CLI ↔ daemon socket lives at
`~/Library/Group Containers/group.dev.debruyn.ofem/ofem.sock`, owner-only
(0600), inside the App Group container so the CLI and daemon find it
without an extra path-resolution layer. The extension cannot reach that
socket directly because of its sandbox, so its inbound RPCs come over a
dedicated XPC service the host app registers on the App Group; the
daemon brokers between the two. The daemon exposes `status`, `account.*`,
`config.snapshot`, `sync.refresh`, and `mount.list` methods.

## Fetching content

When the user opens a placeholder, macOS calls `fetchContents(for: itemIdentifier, version:, request:)`. Our extension:

1. Looks up the file's OneLake path from the metadata cache.
2. Calls OneLake DFS `GET /{path}` (with `Range` headers if macOS asked for a partial fetch).
3. Streams to the location macOS gave us.
4. Returns success; macOS marks the file as locally cached, removes the cloud overlay.

## Uploading content

When the user saves a modified file, macOS calls `createItem` or `modifyItem`. The extension:

1. Resolves the destination OneLake path from `template.parentItemIdentifier` and `template.filename` (create) or `item.itemIdentifier` (modify).
2. Delegates to `CoreBridge.shared.createItem` / `modifyItem`, which crosses the cgo boundary into `ofem_core_create_item` / `ofem_core_modify_item`.
3. The Go core streams to OneLake DFS using `PUT ?resource=file` + chunked `PATCH ?action=append` + `PATCH ?action=flush` via `sync.Engine.Put`.
4. On success, returns the updated `NSFileProviderItem` with the server-assigned etag/mtime from the post-upload HEAD.
5. On failure (network, throttling, capacity-paused), returns an `NSFileProviderError` macOS understands; macOS surfaces it in the UI and may retry later (we honor `Retry-After`).

`modifyItem` only processes calls where `changedFields` includes `.contents`. Metadata-only changes (rename, reparent) return `NSFeatureUnsupportedError` in Phase 1.

## Conflict resolution

**Last-write-wins.** If the extension is asked to upload a file whose remote version has a newer mtime than the local base version, it still uploads. No conflict copy.

This is implemented entirely in `sync.Engine.Put` — we don't read remote-then-merge; we just issue the PUT/PATCH chain.

## macOS metadata filtering

We filter on the **write** path: when macOS asks us to create, modify, or delete a file matching `\.(DS_Store|Spotlight-V100|Trashes|fseventsd)$` or starting with `._`, we accept the call (return success) but do NOT contact OneLake. The local file is still present; the lake never sees it.

This is implemented at two layers:
1. `sync.IsMacOSMetadata(path)` is called in `sync.Engine.Put` and `sync.Engine.Delete` so any caller going through the engine is covered automatically.
2. The cgo bridge additionally short-circuits `ofem_core_create_item` and `ofem_core_delete_item` before reaching the engine, so folder-create paths (which do not go through `Put`) are also filtered.

Read path: we never read these from OneLake (they would never be there in the first place).

## Sign-out / domain removal

`ofem account remove <alias>`:
1. CLI sends RPC to daemon.
2. Daemon calls `NSFileProviderManager.remove(domain)` to ask macOS to tear down the mount.
3. macOS asks the user for confirmation if there are local-only changes (we cooperate).
4. Daemon clears the SQLite cache rows for that domain, removes the cache blob shards, removes the Keychain item, removes the account from `config.toml`.

## What we do NOT implement

- `documentChanged(forItemAt:)` notifications to the extension — unnecessary in the replication model.
- Custom thumbnails — macOS generates them from the cached content.
- Inline editing UI — Finder and the file's default app handle that.
- Per-file conflict resolution UI — last-write-wins.

## Build flow

The Xcode project is not committed. The source of truth is
`apple/project.yml`, which [XcodeGen](https://github.com/yonaskolb/XcodeGen)
turns into `apple/OneLake.xcodeproj`. Keeping the spec as YAML avoids the
churn and merge conflicts of a hand-maintained `.pbxproj`.

Typical local workflow:

```bash
# Once, per developer: write apple/Local.xcconfig (gitignored) and put
# your Apple Developer team ID in it.
make apple-bootstrap

# After every change to apple/project.yml, or when cloning fresh:
make apple-gen

# Clean Debug build via xcodebuild (also re-runs apple-gen).
make apple-build

# Or open the generated project in Xcode for run / debug.
open apple/OneLake.xcodeproj
```

The bundled targets are:
- `OneLake.app` — SwiftUI host application (bundle id `dev.debruyn.ofem`).
- `OneLakeFileProvider.appex` — embedded File Provider Extension
  (bundle id `dev.debruyn.ofem.fileprovider`).

Both share the App Group `group.dev.debruyn.ofem` and the matching
Keychain access group.

Both targets statically link the Go core as `libofemcore.a` and
import its symbols through a Swift bridging header that re-exports
the generated `libofemcore.h`. `make cgo-build` produces the archive
+ header pair under `apple/build/cgo/` (gitignored); `make
apple-build` runs it as a prerequisite, so the Swift binaries always
link a fresh archive. The cgo exports are deliberately minimal in
this PR — a version probe and a string logger that prove the FFI
round-trip — and grow alongside the File Provider implementation in
subsequent PRs.

### Signing for local vs release

A free Apple ID Personal Team is enough for local development. The
extension's `com.apple.developer.file-provider.testing-mode = true`
entitlement lets a Personal-Team-signed bundle register a File Provider
domain on the developer's own Mac without going through a full
provisioning-profile dance.

Homebrew cask distribution requires:
- Apple Developer Program enrollment ($99/yr),
- a `Developer ID Application` certificate,
- notarization via `xcrun notarytool`.

See [docs/packaging-homebrew.md](packaging-homebrew.md) for the full
release pipeline.

## Open design questions

- How to handle very large files (>5 GB) — macOS will request range reads; our streaming code must not buffer the entire file.
- How to communicate "capacity paused" workspace state to the user when File Provider's grayed-out / italic options are limited.

## Resolved design questions

- **Can multiple per-account domains nest under one `~/OneLake/` parent in Finder?** No. See [docs/file-provider-domain-nesting.md](file-provider-domain-nesting.md). Each account lands at `~/Library/CloudStorage/OneLake-<alias>/` and gets its own Finder sidebar entry, matching the OneDrive / Google Drive pattern.
