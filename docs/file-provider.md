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
- The XPC contract itself lives in `Shared/`, not just the `OfemClientControlProtocol` declaration: `OfemControlInterface` is the single factory both sides call to build the `NSXPCInterface` (so its secure-coding class registrations can never drift between host and FPE), `OfemConfigKey` is the canonical `setConfig` key vocabulary, and `OfemDomainIdentifier` composes/decomposes the `ofem.<alias>` domain identifier string. See [Tech stack](tech-stack.md) for the full `Shared/` inventory.

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

Listings are **stale-while-revalidate**. When a folder is opened, the SQLite cache is served immediately if it already holds that folder's children (presence, not age, decides), and a background refresh against OneLake is kicked off at the same time. Only a folder that has never been listed blocks on a refresh before returning, so the first open still shows live entries. When a background refresh finds the listing drifted, the engine notifies the FPE, which signals the affected container so Finder re-enumerates. The cache therefore serves two roles only: instant first paint and an offline fallback. A short revalidate debounce coalesces a burst of opens of the same folder into a single OneLake call.

A few refinements to the discovery/refresh path worth knowing:

- **Discovery upserts are conditional.** `SyncEngine.classifyUpserts` compares each candidate row against the cached row and writes only new-or-changed rows; an unchanged row's `syncedAtNs` is no longer bumped on every poll, so a quiet workspace/item listing does not manufacture phantom deltas.
- **Workspace item listings refresh via Fabric REST, not DFS.** A materialized poll refreshes a workspace's item list through `SyncEngine.refreshItemListing`, which calls Fabric REST `listItems` (replacing an earlier attempt to `listPath(itemGUID: "__items__")` against DFS, which always failed silently). Calls are throttled to once per `(alias, workspaceID)` per 60 s and in-flight calls are coalesced, so a burst of opens across a workspace's items shares one Fabric round trip.
- **Item resolution is cache-first.** `OfemKit.ItemResolution.resolveItem`/`.createItem` (used by the FPE's `item(for:)` and `createItem`/`modifyItem` entry points) try a cached row via the private `cacheFirstRecord` helper before going to the network. `resolveItem`'s cache-miss path enumerates the parent container and retries the cache fetch (`cachedRecordOrEnumerate`), then falls back to a Fabric listing for workspace/item identifiers. `SyncEngine.resolveItemType(for:)` is unrelated to that miss path — it is `createItem`'s own last-resort synthetic-item fallback, used only when a just-created item still has no cache row after the enumerate-and-retry above, so the returned placeholder at least carries the right item type for `computeCapabilities`.

## Working set updates

For change-detection on folders the user has visited recently, the FPE engine polls Fabric on an adaptive schedule. When it finds changes, it calls `NSFileProviderManager.signalEnumerator(for:)` for each affected container. The **host app** (`OneLake.app`) polls the FPE over XPC via `OfemFPEClient` and listens for push notifications. macOS then asks the File Provider Extension to re-enumerate.

**Trade-off:** proactive Finder refresh requires `OneLake.app` to be running. If the user quits the host app, the File Provider Extension continues to work (files open, upload, download) but may not receive all proactive `signalEnumerator` calls. macOS performs its own periodic re-enumeration as a fallback.

## Materialized refresh: subtree-etag skip-gate and self-heal

`pollMaterialized(alias:reply:)` refreshes every container the FPE has materialized (folders opened/kept-on-Mac) for an alias by calling `SyncEngine.refreshMaterialized(alias:keys:concurrencyCap:selfHealIntervalMinutes:)`. A naive implementation would re-list every materialized container on every poll; that's O(materialized containers) DFS calls even when nothing changed. Instead:

- Containers are processed in **depth-ordered waves**, parents before children. Listing a parent folder harvests the ADLS Gen2 directory etag of each child container onto that child's cache row (`SyncEngine.harvestSubtreeEtags`) — under the `2023-11-03` DFS API's deep-advance invariant, that etag changes if *anything* changed anywhere below it.
- A child whose harvested `subtree_etag` is unchanged since the wave started, **and** whose parent actually vouched for it this pass (listed successfully, or was itself skipped), is skipped entirely — no `listPath` call. This is the `#380` skip-gate; the decision logic lives in the private `SyncEngine.shouldSkip`/`.healDue` helpers, and `CacheReader.subtreeEtags(for:)` bulk-reads the etags for a whole wave in one read transaction rather than one `cache.fetch` per key.
- The directory etag (and `contentLength`/`lastModified`) is otherwise **ignored** as a change signal in `entryChanged` — it is only ever consulted as this subtree-change token, never diffed directly into the folder listing.
- **Self-heal floor:** as insurance against the (empirically observed, not contractually guaranteed) deep-advance invariant, each container is forced through a non-gated re-list at least every `selfHealIntervalMinutes`. Each wave's actual listing runs through the private `SyncEngine.runWave` helper; the per-key self-heal clock only advances after a real successful list, never after a swallowed error. Configurable as `sync.self_heal_interval_m` — default 30, `0` disables the floor, otherwise clamped to 10–60 — via Settings → Advanced or `OfemConfigKey.syncSelfHealIntervalM`.
- Depth-0 containers (item roots) and orphan children (parent not in the polled key set) have no parent to vouch for them, so they always list — matching pre-skip-gate behaviour for those cases.
- Per-key errors (offline, cancellation, a paused workspace) are swallowed; they never abort the rest of the pass, and a container that failed never advances its self-heal clock so it stays heal-due.

## Fetching content

When the user opens a placeholder, macOS calls `fetchContents(for: itemIdentifier, version:, request:)`. Our extension:

1. Looks up the file's OneLake path from the metadata cache.
2. Calls OneLake DFS `GET /{path}` (with `Range` headers if macOS asked for a partial fetch).
3. Streams to the location macOS gave us.
4. Returns success; macOS marks the file as locally cached, removes the cloud overlay.

`fetchContents` calls `SyncEngine.openReturningRecord(key:)` rather than a plain `open(key:)`, so the `NSFileProviderItem` it hands back is built from the record `openReturningRecord` already read post-download — not from a cache read taken before the download ran, which could return a `contentVersion` stale relative to the bytes just served and trigger a redundant re-download next cycle.

`open`/`openReturningRecord` gate their freshness check with a TTL (`SyncEngine.defaultBlobFreshnessTTL`, default 60 s, constructor-injectable): a cached row synced within the TTL is served straight from the blob cache with no network call at all; a row outside the TTL falls back to the pre-existing revalidating `HEAD`, except when the engine is known offline, in which case the stale blob is served without attempting the `HEAD`. This keeps a burst of re-opens of the same file (e.g. Quick Look) from paying a round trip each time.

## Uploading content

When the user saves a modified file, macOS calls `createItem` or `modifyItem`. The extension:

1. Resolves the destination OneLake path from `template.parentItemIdentifier` and `template.filename` (create) or `item.itemIdentifier` (modify).
2. Calls `SyncEngine.put` directly (no IPC hop).
3. Stages the upload at a temp sibling path within the same item — `OneLakeClient.write` (both the `sourceURL` and `Data` overloads) runs `PUT ?resource=file` + chunked `PATCH ?action=append` + `PATCH ?action=flush` against a path prefixed `.ofem-upload-<uuid>-`, then commits with a same-item DFS rename onto the real destination path. `isMacOSMetadata` treats the `.ofem-upload-` prefix as hidden junk, so a staging file caught mid-flight by a concurrent listing never surfaces in Finder. On failure the staging file is best-effort deleted; if that cleanup itself fails, the orphaned staging blob is harmless — nothing references it. This avoids truncating the original file if an overwrite is interrupted partway through the append/flush sequence: the old content stays intact under its real path until the rename commits atomically.
4. On success, returns the updated `NSFileProviderItem` with the server-assigned etag/mtime from the post-upload HEAD.
5. On failure (network, throttling, capacity-paused), returns an `NSFileProviderError` macOS understands; macOS surfaces it in the UI and may retry later (we honor `Retry-After`).

`modifyItem` handles three classes of change:

- **`.contents`** — file bytes are streamed to OneLake DFS as above.
- **`.filename` (same-directory rename)** — implemented via the ADLS Gen2 DFS rename: a `PUT` on the destination path carrying the `x-ms-rename-source` header (with the `continuation` query parameter looped until exhausted for large directories). The cache row and all cached descendants are re-keyed in one transaction, and the success path returns the **original** item identifier with the new filename/dates so the framework records a metadata change rather than a delete-and-re-add. Only items advertising `.allowsRenaming` (writable files/dirs under a Lakehouse `Files`/`Tables` subtree) reach this path.
- **`.parentItemIdentifier` (reparent / cross-directory move)** — not yet supported; the field is left pending so the framework does not treat the move as applied.

Other metadata-only changes (e.g. `lastUsedDate`, tags) are acknowledged: the extension applies what it can (nothing persisted remotely for these) and returns the existing item, so macOS treats the call as a no-op rather than surfacing an error to the user.

## Deletion delivery model

A remote deletion has to reach Finder as `enumerateChanges` → `didDeleteItems`, which means the cache needs to remember that a row is gone even after the row itself is hard-deleted. `CacheStore.batchDelete(_:recordTombstones:)` does this: when `recordTombstones` is `true` (the `refreshFolder` reconcile and the discovery-row expiry path both pass `true`; maintenance-only deletes pass `false`), a deletion tombstone is written for every removed row — via `CacheStore.tombstoneIdentifierString(workspaceID:itemID:path:)` — in the **same transaction** as the hard-delete, before it runs. Workspace rows are never tombstoned; a removed workspace is remount-driven (`ChangeWatcher`), not delta-driven.

`CacheReader.syncAnchorNs` (renamed from `maxSyncedAtNs`) folds in the newest `deleted_at_ns` alongside `synced_at_ns`, so a poll that only removes rows still advances the anchor instead of stranding the deletion behind it. `CacheReader.itemsChangedAfter` reads both `path_metadata` and `deletion_tombstones` and reconciles any overlap by timestamp (ties favour the live row). A tombstone is cleared as soon as its identifier is re-created — `upsert`/`batchUpsert`/`renamePathPrefix`'s destination subtree all clear a shadowing tombstone inline — so a rename or re-create is never mistakenly reported as a delete-then-add. Migration `v7` does a one-time purge of legacy tombstones already shadowed by a fresher live row from before this model existed.

Known follow-up: `expireDiscoveryRows` does not yet purge orphaned `path_metadata` rows keyed by a removed item's real GUID, and blob cleanup for tombstoned deletes is deferred to the background orphan sweep rather than done inline.

## Conflict resolution

**Last-write-wins.** If the extension is asked to upload a file whose remote version has a newer mtime than the local base version, it still uploads. No conflict copy.

## macOS metadata filtering

We filter on the **write** path: when macOS asks us to create, modify, or delete a file matching `\.(DS_Store|Spotlight-V100|Trashes|fseventsd)$` or starting with `._`, we accept the call (return success) but do NOT contact OneLake. The local file is still present; the lake never sees it.

Read path: we never read these from OneLake (they would never be there in the first place).

## Sign-out / domain removal

Signing out from the menu bar (account submenu -> **Sign Out…**) runs entirely in the **host app**, not over XPC:
1. `MenuStatusModel.removeAccount(alias:)` calls `SharedOfemAuth.shared.auth.removeAccount(alias:)` — `OfemAuth`, running in-process in the host — which purges the account's refresh token from the shared MSAL Keychain and removes the account entry from `config.toml`.
2. On success, `DomainSyncManager.shared.removeDomain(alias:)` calls `NSFileProviderManager.remove(domain, mode: .preserveDownloadedUserData)` directly, asking macOS to tear down the mount for that alias while keeping any locally downloaded files on disk.
3. macOS asks the user for confirmation if there are local-only changes (we cooperate).

There is no `removeAccount` XPC method on `OfemClientControlProtocol` — the protocol surface is `getProtocolVersion`, `getEngineStatus`, `setConfig`, `clearCache`, `pollMaterialized`, and `reloadEngine`. The FPE does not participate in account removal directly; it picks up the account's absence the next time it reads `config.toml`. Cache rows and blob shards for the removed alias are not swept synchronously by this flow (see "Deletion delivery model" above for the general row-removal machinery, which does not currently run a whole-account purge).

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

Building a *runnable* copy of the Swift host app and the File Provider
Extension requires a paid Apple Developer Program membership (a free
Personal Team cannot sign the extension). With your team set in
`Local.xcconfig`, build both with:

```
make build
```

Contributors without a paid account can still verify their change compiles
with the CI-equivalent unsigned build:

```
make build-ci
```

This produces an unsigned, non-runnable binary — enough to catch Swift
compile regressions, but not enough to install the extension on your Mac.
See [Prerequisites](prerequisites.md) for the full compiling-vs-running
split.

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
