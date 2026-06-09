# File Provider Extension — architecture

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
| `NSFileProviderReplicatedExtension` | Entry point; lifecycle, domain registration, root container metadata. |
| `NSFileProviderItem` (one per file/folder) | Identity, parent, type, size, modification time, capabilities, sync state. |
| `NSFileProviderEnumerator` | Lists items inside a container; supports incremental updates and search. |

We use the **replication model**, which is what Apple recommends for cloud storage providers since macOS 13. Old non-replicated providers are deprecated.

## Two processes, one product

```
   ┌────────────────────────────┐     XPC (NSFileProviderService)
   │   OneLake.app (host)       │◄─────────────────────────────────┐
   │   - SwiftUI account UI     │                                  │
   │   - Menu bar status icon   │                                  │
   │   - Registers domains      │                                  │
   │   - ChangeWatcher polls    │                                  │
   └────────────────────────────┘     ┌────────────────────────────┐
                                      │  OneLakeFileProvider.appex  │
                                      │  (Swift, sandboxed)         │
                                      │  - NSFileProviderReplicated │
                                      │  - OfemFPEEnumerator        │
                                      │  - FPEEngineHost            │
                                      │  - OfemEngine (OfemKit)    │
                                      │  - OfemAuth (MSAL Swift)   │
                                      │  - CacheStore (SQLite)      │
                                      └────────────────────────────┘
```

What each process does:

- The **host app** holds the account-management UI, registers File Provider domains, talks to the system browser for auth, and polls the FPE for change signals. It communicates with the FPE via `NSFileProviderManager.service(name:for:)` + `NSXPCConnection` (protocol `OfemClientControlProtocol`).
- The **File Provider Extension** is sandboxed by Apple. macOS launches it on demand when Finder needs files. It implements the `NSFileProvider*` classes and owns all engine logic: auth (MSAL Swift), OneLake DFS, Fabric REST, cache (SQLite + blobs), sync, and telemetry.

## Shared state via App Group

Both processes share one App Group identifier `6D79CUWZ4J.group.dev.debruyn.ofem` (team-prefixed so the same value works for both Developer ID and Mac App Store distribution). That gives them:
- A shared container at `~/Library/Group Containers/6D79CUWZ4J.group.dev.debruyn.ofem/`.
- A shared Keychain access group `6D79CUWZ4J.group.dev.debruyn.ofem`.

What lives in the shared container:
- `config.toml` — accounts, settings.
- `cache.sqlite` — file metadata cache (paths, etags, mtimes, sync state).
- `cache/<sha256>` — actual cached file blobs, sharded by hash prefix.
- `log/ofem.log` — FPE engine log, rotated.

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
/<workspaceGUID>/<itemGUID>/<path-within-item>
```

Examples:
- `""` — the root container of the domain (one domain = one alias).
- `/8d3b…` — a workspace inside the alias.
- `/8d3b…/2f1a…` — the lakehouse named "MyLH" inside workspace "FinanceWS".
- `/8d3b…/2f1a…/Files/raw/2024/sales.csv` — a file.

Using GUIDs at workspace and item level shields us from rename churn (Microsoft preserves GUIDs on rename).

## Enumeration model

A user double-clicks a folder in Finder. macOS calls `enumerator(for: containerItemIdentifier, request:)`. Our enumerator:

1. Parses the identifier via `OfemKit.ItemIdentifierParser`.
2. If root container → call Fabric REST `GET /workspaces`, return one `NSFileProviderItem` per workspace.
3. If workspace → call Fabric REST `GET /workspaces/{id}/items` + `GET /workspaces/{id}/folders`, return items + folders.
4. If item/path → call OneLake DFS `GET /{workspaceGUID}/{itemGUID}/{path}?resource=filesystem&recursive=false`, return files + folders.

Results are cached in SQLite with a TTL appropriate for the level: 30 seconds for currently-open folders, 5 minutes for the rest.

## Working set updates

For change-detection on folders the user has visited recently, the FPE engine polls Fabric on an adaptive schedule. When it finds changes, it calls `NSFileProviderManager.signalEnumerator(for:)` for each affected container. The **host app** (`OneLake.app`) polls the FPE over XPC via `OfemFPEClient` and listens for push notifications. macOS then asks the File Provider Extension to re-enumerate.

**Trade-off:** proactive Finder refresh requires `OneLake.app` to be running. If the user quits the host app, the File Provider Extension continues to work (files open, upload, download) but may not receive all proactive `signalEnumerator` calls. macOS performs its own periodic re-enumeration as a fallback.

## Fetching content

When the user opens a placeholder, macOS calls `fetchContents(for: itemIdentifier, version:, request:)`. Our extension:

1. Looks up the file's OneLake path from the metadata cache.
2. Calls OneLake DFS `GET /{path}` (with `Range` headers if macOS asked for a partial fetch).
3. Streams to the location macOS gave us.
4. Returns success; macOS marks the file as locally cached, removes the cloud overlay.

## Uploading content

When the user saves a modified file, macOS calls `createItem` or `modifyItem`. The extension:

1. Resolves the destination OneLake path from `template.parentItemIdentifier` and `template.filename` (create) or `item.itemIdentifier` (modify).
2. Calls `SyncEngine.put` directly (no IPC hop).
3. Streams to OneLake DFS using `PUT ?resource=file` + chunked `PATCH ?action=append` + `PATCH ?action=flush`.
4. On success, returns the updated `NSFileProviderItem` with the server-assigned etag/mtime from the post-upload HEAD.
5. On failure (network, throttling, capacity-paused), returns an `NSFileProviderError` macOS understands; macOS surfaces it in the UI and may retry later (we honor `Retry-After`).

`modifyItem` only processes calls where `changedFields` includes `.contents`. Metadata-only changes (rename, reparent) return an `NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError)`.

## Conflict resolution

**Last-write-wins.** If the extension is asked to upload a file whose remote version has a newer mtime than the local base version, it still uploads. No conflict copy.

## macOS metadata filtering

We filter on the **write** path: when macOS asks us to create, modify, or delete a file matching `\.(DS_Store|Spotlight-V100|Trashes|fseventsd)$` or starting with `._`, we accept the call (return success) but do NOT contact OneLake. The local file is still present; the lake never sees it.

Read path: we never read these from OneLake (they would never be there in the first place).

## Sign-out / domain removal

Signing out from the menu bar (account submenu -> **Sign Out…**):
1. Menu bar sends `removeAccount` via XPC to the FPE's `OfemClientControlService`.
2. FPE calls `NSFileProviderManager.remove(domain)` to ask macOS to tear down the mount.
3. macOS asks the user for confirmation if there are local-only changes (we cooperate).
4. FPE clears the SQLite cache rows for that domain, removes the cache blob shards, removes the Keychain item, removes the account from `config.toml`.

## What we do NOT implement

- `documentChanged(forItemAt:)` notifications to the extension — unnecessary in the replication model.
- Custom thumbnails — macOS generates them from the cached content.
- Inline editing UI — Finder and the file's default app handle that.
- Per-file conflict resolution UI — last-write-wins.

## Build flow

The Xcode project is not committed. The source of truth is
`project.yml`, which [XcodeGen](https://github.com/yonaskolb/XcodeGen)
turns into `OneLake.xcodeproj`. Keeping the spec as YAML avoids the
churn and merge conflicts of a hand-maintained `.pbxproj`.

Typical local workflow:

```bash
# Once, per developer: write Local.xcconfig (gitignored) and put
# your Apple Developer team ID in it.
make bootstrap

# After every change to project.yml, or when cloning fresh:
make gen

# Clean Debug build via xcodebuild (also re-runs gen).
make build

# Or open the generated project in Xcode for run / debug.
open OneLake.xcodeproj
```

The bundled targets are:
- `OneLake.app` — SwiftUI host application (bundle id `dev.debruyn.ofem`).
- `OneLakeFileProvider.appex` — embedded File Provider Extension
  (bundle id `dev.debruyn.ofem.fileprovider`).

Both share the App Group `6D79CUWZ4J.group.dev.debruyn.ofem` and the
matching Keychain access group. The engine (OfemKit) is linked into
the FPE. The host app links OfemKit too (for SharedOfemAuth), but does
not run the sync engine.

### Signing for local vs release

The **paid Apple Developer Program** (Developer ID team) is the primary
development path. It provides a real provisioning profile that includes
the `com.apple.developer.file-provider` entitlement family; no
`testing-mode` entitlement is needed or used.

Building the Swift host app and the File Provider Extension requires a paid
Apple Developer Program membership (a free Personal Team cannot sign the
extension). With your team set in `Local.xcconfig`, build both with:

```
make build
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
