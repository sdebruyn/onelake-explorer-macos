# OneLake File Explorer for Windows — reference implementation

This document describes how Microsoft's **OneLake File Explorer for Windows** works, so we can make informed decisions about which behavior to copy on macOS and which behavior to deliberately improve or change.

Sources: official Microsoft Learn documentation.

## Overview

OneLake File Explorer integrates OneLake (the logical data lake inside Microsoft Fabric) with Windows File Explorer. The app exposes every OneLake item the user has access to as a unified node in File Explorer.

- Files (CSV, Excel, Parquet, any binary) can be dragged and dropped into OneLake.
- The app creates **placeholders**, not local copies. The actual file content is downloaded only when the user double-clicks a file.
- Local storage location: `%USERPROFILE%\OneLake - Microsoft\`.
- File modifications made through Windows File Explorer are automatically synced to OneLake.
- Updates to items made **outside** the File Explorer (e.g. in the Fabric web UI or via Spark) are **not** automatically synced. The user must right-click and pick **Sync from OneLake** to refresh.

## Sync model

| What | When |
|---|---|
| Workspace and item names (placeholders) | At initial sync |
| Files inside a folder | When the user opens the folder |
| File content | When the user opens the file (double-click) |
| Local change → OneLake | Automatically on save |
| Remote change → local | **Manual only**, via Sync from OneLake |

The lazy-sync model avoids downloading enormous lakehouses locally, but it also means the view is potentially "stale" relative to the actual remote state.

## Authentication

- Uses the currently logged-in Microsoft Entra ID by default.
- Since **v1.0.9.0** the user can explicitly pick which account to sign in with.
- Account switching: right-click the tray icon → Account → Sign Out → restart the app → choose another account.
- **Limitation**: one active account at a time. Workspaces from other accounts become inaccessible while you are signed in with a different account.
- **This is one of the weaknesses we want to fix on macOS**: keep multiple accounts in multiple tenants visible at the same time.

## Storage and URI model

The Windows File Explorer integration sits on top of the same ADLS Gen2–compatible endpoint we are going to use:

```
https://onelake.dfs.fabric.microsoft.com/<workspace>/<item>.<itemtype>/<path>/<fileName>
```

Items carry a type extension (`.lakehouse`, `.warehouse`, `.kqldatabase`, …) because item names do not have to be unique across types inside a single workspace.

Alternative form using GUIDs (immutable, not affected by rename):

```
https://onelake.dfs.fabric.microsoft.com/<workspaceGUID>/<itemGUID>/<path>/<fileName>
```

ABFS-style URI:

```
abfs[s]://<workspace>@onelake.dfs.fabric.microsoft.com/<item>.<itemtype>/<path>/<fileName>
```

## Known limitations of the Windows app (areas we want to improve)

1. **One account at a time** — we support multi-account / multi-tenant.
2. **Workspace names containing `/`, escaped characters such as `%23`, or GUID-shaped names** fail to sync — we plan to use GUIDs as the internal identifier so that name quirks become irrelevant.
3. **Files with Windows-reserved characters** fail to sync — macOS reserves fewer characters (only `:` and `/`), which is a natural win.
4. **Case insensitivity** of Windows File Explorer clashes with case-sensitive OneLake; only the oldest file with conflicting casing is visible. APFS on macOS defaults to case-insensitive but case-preserving — we have to solve the same problem, or explicitly offer a case-sensitive mount (FUSE-T supports that).
5. **No proxy support** — we must honor `HTTPS_PROXY` env vars.
6. **Read-only files don't sync** — by design on Windows; we need to define our behavior clearly.
7. **Disabled when Windows Search is off** — we have no such coupling.
8. **No Mac version** — that is precisely why this project exists.

## Admin / tenant policy

A Fabric tenant admin can disable OneLake File Explorer for the entire tenant. Our macOS app uses **the same** ADLS Gen2 + Fabric REST APIs, so that specific policy may not apply to us — but we should be aware that admin restrictions exist and surface clear error messages.

## Functional scope for MVP parity

What we need at minimum to be "OneLake File Explorer equivalent":

- [ ] List workspaces
- [ ] List items per workspace with item-type icon
- [ ] Browse folders inside an item (Files/, Tables/, shortcuts)
- [ ] Lazy listing (only list a folder when it is opened)
- [ ] Download a file
- [ ] Upload a file (overwrite and new)
- [ ] Delete a file
- [ ] Create a folder
- [ ] Delete a folder
- [ ] Honor shortcuts (transparent, like a regular folder)
- [ ] Sync from OneLake (force a metadata refresh)
- [ ] Account management (multiple accounts/tenants concurrently)

Out of scope for MVP, possibly later:

- Tables preview (requires Delta / Iceberg parser)
- Server-side rename (OneLake supports rename via the ADLS API, but Fabric-managed folders are protected)
- Viewing or editing permissions (must go through the Fabric portal)
