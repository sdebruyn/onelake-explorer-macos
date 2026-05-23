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

Why three processes:
- The **host app** is what the user opens to manage accounts. It runs unsandboxed enough to talk to the system browser for auth, write to the App Group container, register File Provider domains.
- The **File Provider Extension** is sandboxed by Apple. It is launched on demand when Finder needs files. It cannot hold long-lived network sockets, cannot do auth flows, and cannot run scheduled background work.
- The **daemon** is needed for everything the sandbox blocks: long-lived telemetry batching, scheduled cache eviction, the Unix socket the CLI talks to, refresh polling not tied to a specific Finder request.

The host app and daemon are different processes because:
- The host app may be closed by the user (the menu bar icon doesn't keep it alive).
- The daemon must keep running regardless, started by LaunchAgent at login.

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
- `NSFileProviderDomain(identifier: "ofem.work", displayName: "OneLake — work", pathRelativeToDocumentStorage: "work")`.
- `NSFileProviderDomain(identifier: "ofem.client-a", displayName: "OneLake — client-a", pathRelativeToDocumentStorage: "client-a")`.

Each domain shows up as a separate Finder sidebar entry. macOS handles the per-domain mount paths automatically; we don't control where in `~/Library/CloudStorage` they materialize. But we can also call `replicatedKnownFolder` API to surface them grouped under a single `~/OneLake/` parent if Apple's API allows — TODO during MVP design spike.

Alternative considered: one global `ofem.main` domain with all accounts as top-level items inside. Rejected: per-domain sync state, per-domain sign-out, per-domain icon ("OneLake — work" tells you what you're looking at) are all easier with per-account domains.

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

Results are cached in SQLite with a TTL appropriate for the level (30 seconds for currently-open folders, 5 minutes for the rest, per Sam's adaptive polling decision).

## Working set updates

For change-detection on folders the user has visited recently, the daemon (not the extension) polls Fabric on the adaptive schedule. When it finds changes, it calls `NSFileProviderManager.signalEnumerator(for:)` to tell macOS "the X container has changes, please re-enumerate". The extension's enumerator then re-fetches and produces a delta.

The daemon and extension communicate over **XPC**, wrapped around the
same JSON-RPC 2.0 protocol the CLI uses on its Unix-domain socket (see
[`internal/ipc`](../internal/ipc)). The CLI ↔ daemon socket lives at
`~/Library/Application Support/dev.debruyn.ofem/ofem.sock`, owner-only
(0600). The extension cannot reach that socket directly because of its
sandbox, so its inbound RPCs come over a dedicated XPC service the
host app registers on the App Group; the daemon brokers between the
two. The XPC bridge is a Phase 1 deliverable. As of this writing the
IPC layer wires only the CLI side; the daemon already serves the
`status`, `account.*`, `config.snapshot` methods that the CLI uses
today, plus stubs (`sync.refresh`, `mount.list`) for the sync engine
and File Provider domain enumeration that the next two PRs will fill
in.

## Fetching content

When the user opens a placeholder, macOS calls `fetchContents(for: itemIdentifier, version:, request:)`. Our extension:

1. Looks up the file's OneLake path from the metadata cache.
2. Calls OneLake DFS `GET /{path}` (with `Range` headers if macOS asked for a partial fetch).
3. Streams to the location macOS gave us.
4. Returns success; macOS marks the file as locally cached, removes the cloud overlay.

## Uploading content

When the user saves a modified file, macOS calls `createItem` or `modifyItem`. Our extension:

1. Resolves the destination OneLake path.
2. Streams to OneLake DFS using `PUT ?resource=file` + chunked `PATCH ?action=append` + `PATCH ?action=flush`.
3. On success, returns the updated `NSFileProviderItem` with the new etag/mtime.
4. On failure (network, throttling, conflict), returns an `NSFileProviderError` macOS understands; macOS surfaces it in the UI and may retry later (we honor `Retry-After`).

## Conflict resolution

Per Sam's choice: **last-write-wins on mtime**. If our extension is asked to upload a file whose remote version has a newer mtime than the local base version, we still upload. No conflict copy.

This is implemented entirely in the upload path — we don't read remote-then-merge; we just `PUT`.

## macOS metadata filtering

We filter on **write** path: when macOS asks us to create or modify a file matching `\.(DS_Store|Spotlight-V100|Trashes|fseventsd)$` or starting with `._`, we accept the call (return success) but do NOT upload. The local file is still present; OneLake just doesn't see it.

Read path: we never read these from OneLake (they would never be there in the first place).

## Sign-out / domain removal

`ofem account remove <alias>`:
1. CLI sends RPC to daemon.
2. Daemon calls `NSFileProviderManager.remove(domain)` to ask macOS to tear down the mount.
3. macOS asks the user for confirmation if there are local-only changes (we cooperate).
4. Daemon clears the SQLite cache rows for that domain, removes the cache blob shards, removes the Keychain item, removes the account from `config.toml`.

## What we do NOT implement

- `documentChanged(forItemAt:)` notifications to the extension — unnecessary in the replication model.
- Custom thumbnails — let macOS generate them from the cached content.
- Inline editing UI — Finder + the file's default app handle that.
- Per-file conflict resolution UI — we chose last-write-wins.

## Open design questions for MVP design spike

- Whether `replicatedKnownFolder` API lets us nest all per-account domains under one `~/OneLake/` parent in Finder, or whether they land separately in `~/Library/CloudStorage/OneLake-<alias>/`.
- How to handle very large files (>5 GB) — macOS will request range reads; our streaming code must not buffer the entire file.
- How to communicate "capacity paused" workspace state to the user when File Provider's grayed-out / italic options are limited.
