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
   ┌────────────────────────────┐     ┌────────────────────────────┐
   │   OneLake.app (host)       │     │  OneLakeFileProvider.appex  │
   │   - SwiftUI account UI     │     │  (Swift, sandboxed)         │
   │   - Menu bar status icon   │     │  - NSFileProvider*          │
   │   - Registers domain(s)    │     │  - IPCClient → fp.* methods │
   │   - ChangeWatcher polls    │     └─────────────┬───────────────┘
   └────────────┬───────────────┘                   │
                │  JSON-RPC over the Unix socket     │
                │  (ofem.sock in the App Group):     │
                │  account.*, sync.pollChanges,      │
                │  fp.enumerate/item/fetch/…         │
                └──────────────────┬─────────────────┘
                                   ▼
              ┌────────────────────────────────────┐
              │  ofem daemon (Go) — LaunchAgent    │
              │  - IPC server (internal/ipc)       │
              │  - owns the engine in-process:     │
              │    auth (MSAL) · OneLake DFS ·     │
              │    Fabric REST · cache (SQLite +   │
              │    blobs) · sync · fp              │
              │  - adaptive change feed, telemetry │
              └────────────────────────────────────┘
   The daemon signals the host app's ChangeWatcher (via pollChanges),
   which calls NSFileProviderManager.signalEnumerator to refresh Finder.
```

What each process does:
- The **host app** holds the account-management UI, registers File Provider domains, talks to the system browser for auth, and polls the daemon for change signals. It is an IPC client of the daemon.
- The **File Provider Extension** is sandboxed by Apple. macOS launches it on demand when Finder needs files. It implements the `NSFileProvider*` classes and calls the daemon's `fp.*` methods over IPC.
- The **daemon** runs as a LaunchAgent (`OneLake.app/Contents/Helpers/ofem`, registered via SMAppService) and is the single owner of the Go engine, cache, and blob store. It holds the Unix socket the host app and the File Provider Extension share, batches telemetry, and runs adaptive polling against Fabric.

## Shared state via App Group

All three processes share one App Group identifier `6D79CUWZ4J.group.dev.debruyn.ofem` (team-prefixed so the same value works for both Developer ID and Mac App Store distribution). That gives them:
- A shared container at `~/Library/Group Containers/6D79CUWZ4J.group.dev.debruyn.ofem/`.
- A shared Keychain access group `6D79CUWZ4J.group.dev.debruyn.ofem`.

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

For change-detection on folders the user has visited recently, the daemon (not the extension) polls Fabric on the adaptive schedule. When it finds changes, it publishes them to an in-memory change feed. The **host app** (`OneLake.app`) polls the daemon every 5 seconds via the `sync.pollChanges` JSON-RPC method and calls `NSFileProviderManager.signalEnumerator(for:)` for each affected container. macOS then asks the File Provider Extension to re-enumerate and the extension fetches the delta.

The daemon socket lives at
`~/Library/Group Containers/6D79CUWZ4J.group.dev.debruyn.ofem/ofem.sock`, owner-only
(0600), inside the App Group container so the host app and the File
Provider Extension both find it without an extra path-resolution layer.
Both sides share the same JSON-RPC 2.0 framing
([`internal/ipc`](../internal/ipc)). The daemon exposes `status`,
`account.*`, `config.snapshot`, `sync.refresh`, `sync.pollChanges`, and
`mount.list` methods.

**Phase 1 trade-off:** automatic Finder refresh requires `OneLake.app` to
be running. If the user quits the host app, the File Provider Extension
continues to work (files open, upload, download) but it will not receive
proactive `signalEnumerator` calls. macOS performs its own periodic
re-enumeration as a fallback; the cadence is at macOS's discretion and is
typically slower than OFEM's 5-second polling interval. This limitation is
accepted for Phase 1 and will be addressed in Phase 2 when the daemon gains
a dedicated signaling channel directly into the extension.

**Why not XPC between daemon and extension?** A sandboxed File Provider
Extension can communicate with the host app via App Group XPC, but wiring a
new XPC service correctly (entitlements, Mach service name, bi-directional
framing) adds significant complexity with no functional benefit in Phase 1:
the host app is already the domain-registration owner and is expected to
stay running while the user works. Using the existing Unix socket keeps the
change-detection path simple and uniform.

## Fetching content

When the user opens a placeholder, macOS calls `fetchContents(for: itemIdentifier, version:, request:)`. Our extension:

1. Looks up the file's OneLake path from the metadata cache.
2. Calls OneLake DFS `GET /{path}` (with `Range` headers if macOS asked for a partial fetch).
3. Streams to the location macOS gave us.
4. Returns success; macOS marks the file as locally cached, removes the cloud overlay.

## Uploading content

When the user saves a modified file, macOS calls `createItem` or `modifyItem`. The extension:

1. Resolves the destination OneLake path from `template.parentItemIdentifier` and `template.filename` (create) or `item.itemIdentifier` (modify).
2. Delegates to `CoreBridge.shared.createItem` / `modifyItem`, which call the daemon's `fp.createItem` / `fp.modifyItem` over IPC (the staged source file is copied into the App Group container so the daemon can read it).
3. The Go core streams to OneLake DFS using `PUT ?resource=file` + chunked `PATCH ?action=append` + `PATCH ?action=flush` via `sync.Engine.Put`.
4. On success, returns the updated `NSFileProviderItem` with the server-assigned etag/mtime from the post-upload HEAD.
5. On failure (network, throttling, capacity-paused), returns an `NSFileProviderError` macOS understands; macOS surfaces it in the UI and may retry later (we honor `Retry-After`).

`modifyItem` only processes calls where `changedFields` includes `.contents`. Metadata-only changes (rename, reparent) return an `NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError)` in Phase 1 — not the `NSFileProviderError.notAuthenticated` alias that `NSFileProviderError.featureUnsupported` resolves to on this macOS version.

## Conflict resolution

**Last-write-wins.** If the extension is asked to upload a file whose remote version has a newer mtime than the local base version, it still uploads. No conflict copy.

This is implemented entirely in `sync.Engine.Put` — we don't read remote-then-merge; we just issue the PUT/PATCH chain.

## macOS metadata filtering

We filter on the **write** path: when macOS asks us to create, modify, or delete a file matching `\.(DS_Store|Spotlight-V100|Trashes|fseventsd)$` or starting with `._`, we accept the call (return success) but do NOT contact OneLake. The local file is still present; the lake never sees it.

This is implemented at two layers:
1. `sync.IsMacOSMetadata(path)` is called in `sync.Engine.Put` and `sync.Engine.Delete` so any caller going through the engine is covered automatically.
2. The same `IsMacOSMetadata` guard covers the create and delete engine entry points the daemon's `fp.createItem` / `fp.deleteItem` call, so folder-create paths (which do not go through `Put`) are also filtered.

Read path: we never read these from OneLake (they would never be there in the first place).

## Sign-out / domain removal

Signing out from the menu bar (account submenu -> **Sign Out…**):
1. Menu bar sends `account.remove` RPC to the daemon.
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

Both share the App Group `6D79CUWZ4J.group.dev.debruyn.ofem` and the
matching Keychain access group.

Neither target embeds the Go engine. They share
`apple/Shared/IPCClient.swift` (a JSON-RPC client over the daemon's Unix
socket) and `apple/Shared/CoreBridge.swift` (typed wrappers around the
daemon's `fp.*` methods). The daemon is the single owner of the engine,
cache, and blob store; file bytes cross the process boundary through the
shared App Group container. There is no cgo archive and no bridging header.

### Signing for local vs release

The **paid Apple Developer Program** (Developer ID team) is the primary
development path. It provides a real provisioning profile that includes
the `com.apple.developer.file-provider` entitlement family; no
`testing-mode` entitlement is needed or used.

Building the Swift host app and the File Provider Extension requires a paid
Apple Developer Program membership (a free Personal Team cannot sign the
extension). With your team set in `apple/Local.xcconfig`, build both with:

```
make apple-build
```

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
