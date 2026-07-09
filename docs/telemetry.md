# Telemetry design

This document covers the App Insights telemetry pipeline (network events).
It is a separate channel from the local system log (`os_log`, viewable in
Console.app or a sysdiagnose): the "no file name / no folder path" principle
below applies there too — FPE log statements redact `.path`-derived
identifiers and filenames via `ItemIdentifier.opaqueLogPrefix` /
`privacy: .private` rather than emitting them as `privacy: .public` — but
enforcement lives in the FPE source (see `OneLakeFileProvider/FileProviderExtension.swift`
header comment), not in this pipeline.

## Principles

- **Opt-out**, enabled by default, clearly disclosed on first run and in README.
- **Disable any time** by unchecking **Send Anonymous Telemetry** in the OneLake menu bar. The change takes effect immediately; the menu bar always shows the current state.
- **No PII**: no UPN, no workspace name, no item name, no file name, no folder path.
- **Tenant IDs are collected.** Tenant IDs are aggregate-level enough to be useful for understanding adoption per tenant without identifying individual users.
- **Pseudonymous install ID** is generated locally on first run (a random UUIDv4 stored in config) so we can deduplicate events from the same install without identifying the user.
- **No tracking across re-installs**: removing OFEM (`brew uninstall --zap`) removes the install ID; reinstalling generates a new one.

## Backend: Azure Application Insights free tier

Chosen for:
- 5 GB/month ingestion free (a comfortable headroom — even at 1 M events/month we are well under).
- Swift client via the REST ingestion API (no runtime dependency on an SDK binary).
- Out-of-the-box dashboards in the Azure portal.
- Workbooks for custom analysis without needing Fabric.

For Fabric-side analysis (optional, when richer notebooks are needed): set up Diagnostic Settings export from the App Insights resource to an ADLS Gen2 storage account, then create an OneLake shortcut into a Fabric Lakehouse.

## Schema

Every event is sent as an App Insights `customEvent` with a fixed property set:

| Property | Type | Required | Example | Notes |
|---|---|---|---|---|
| `installId` | string (UUIDv4) | Yes | `5b3c…` | Generated locally on first run, persisted in config. |
| `appVersion` | string | Yes | `2026.05.1` | The OFEM version. |
| `platform` | string | Yes | `darwin` | Always `darwin` for OFEM. |
| `arch` | string | Yes | `arm64` | Always `arm64` for OFEM. |
| `osVersion` | string | Yes | `14.5.1` | macOS version reported by `sw_vers`. |
| `event` | string | Yes | `file_download` | The event name. |
| `tenantId` | string (GUID) | Conditional | `8d3b…` | When the event is associated with a specific OneLake operation; null for app lifecycle events. |
| `accountAliasHash` | string | Conditional | `sha256(<alias>):8` | First 8 hex chars of the SHA256 of the user-chosen alias, to correlate events from the same account-context without revealing the alias text. |
| `durationMs` | int64 | When relevant | `423` | For events that complete an operation. |
| `success` | bool | When relevant | `true` | For events that complete an operation. |
| `errorCode` | string | When `success=false` | `AADSTS50079` | Backend or library-defined error code. Free text up to 32 chars; **must not contain PII** (we redact any string longer than 32 chars or containing `@`). |
| `failedOp` | string | On `error` events | `file_download` | The name of the operation that produced the error. Present only on `error` events (emitted by `trackError`). |

## Event catalog (initial)

| Event | When | Properties beyond defaults |
|---|---|---|
| `app_start` | Host app process starts | — |
| `app_stop` | Host app process exits cleanly | — |
| `account_added` | After successful sign-in (menu bar -> **Add Account…**) | `tenantId`, `accountAliasHash` |
| `account_removed` | After successful sign-out (menu bar account submenu -> **Sign Out…**) | `tenantId`, `accountAliasHash` |
| `workspace_list` | Fabric REST list-workspaces call completes | `tenantId`, `accountAliasHash`, `durationMs`, `success` |
| `item_list` | Fabric REST list-items call completes | `tenantId`, `accountAliasHash`, `durationMs`, `success` |
| `folder_list` | OneLake DFS folder list completes | `tenantId`, `accountAliasHash`, `durationMs`, `success` |
| `file_download` | OneLake DFS file read completes | `tenantId`, `accountAliasHash`, `durationMs`, `success`, `bytesTransferred` |
| `file_upload` | OneLake DFS file write completes | `tenantId`, `accountAliasHash`, `durationMs`, `success`, `bytesTransferred` |
| `file_delete` | OneLake DFS file delete completes | `tenantId`, `accountAliasHash`, `durationMs`, `success` |
| `folder_create` | OneLake DFS directory create completes | `tenantId`, `accountAliasHash`, `durationMs`, `success` |
| `folder_delete` | OneLake DFS directory delete completes | `tenantId`, `accountAliasHash`, `durationMs`, `success` |
| `mount_start` | File Provider domain registered | `accountAliasHash` |
| `mount_stop` | File Provider domain removed | `accountAliasHash` |
| `sync_pulled` | Adaptive-poll refresh detected and pulled changes | `tenantId`, `accountAliasHash`, `itemsChanged` |
| `error` | Recoverable error logged | `errorCode`, `failedOp` (the operation that errored, e.g. `file_download`) |
| `crash` | Unhandled error or unexpected termination | `errorCode` (hashed stack trace prefix), `appVersion` |

## Sync-engine error-code vocabulary

The sync engine narrows the free-text `errorCode` field on `file_upload`
and `file_download` to a fixed vocabulary so dashboards have stable
legends. New codes are added here before the engine starts emitting
them.

| `errorCode` | Emitted on | Meaning |
|---|---|---|
| `read_failed` | `file_download` | Remote GET failed for a reason that is neither paused capacity nor offline. |
| `write_failed` | `file_upload` | Remote PUT/PATCH chain failed for a reason that is neither paused capacity, offline, nor LWW exhaustion. |
| `blob_store_failed` | `file_download` | Local blob store rejected the downloaded bytes (out of disk, etc.). |
| `capacity_paused` | `file_upload`, `file_download` | Workspace's backing Fabric capacity is paused or suspended. |
| `lww_exhausted` | `file_upload` | Last-write-wins replay loop hit its cap (default 3 cycles) on 412 PreconditionFailed. The local change is dropped — no conflict copy. |
| `queued_offline` | `file_upload` | Host was offline at the time of the write; bytes were spooled to the persistent offline queue under `<cacheRoot>/offline-queue/` and the caller saw a nil-success. Spool file is fsync'd and the filename encodes the cache key so the FPE can rebuild the queue on restart. |
| `served_stale_offline` | `file_download` | Host was offline AND the cache held a fully stored blob; the cached bytes were served (with `success=true`) instead of refusing the read. Matches OneDrive / Dropbox offline behaviour. |

## Connection string distribution

The Application Insights connection string is a committed source constant in `Packages/OfemKit/Sources/OfemKit/Telemetry/BuildInfo.swift`. Every OFEM build — official release, source build, or fork — reports to the same endpoint. The string is rotated by issuing a new one for the resource and bumping that file; old binaries then stop reporting on the next release.

## First-run disclosure

```
OFEM collects anonymous usage events plus tenant IDs to help understand adoption
and improve the tool. We never collect workspace names, file names, or your UPN.

Disable any time:  uncheck "Send Anonymous Telemetry" in the OneLake menu bar

Learn more:        https://github.com/sdebruyn/onelake-explorer-macos/blob/main/docs/telemetry.md
```

Shown on first launch of `OneLake.app` as a small banner in the host app.

## Local buffering and offline

The telemetry module in OfemKit buffers events in memory and flushes every 10 seconds or when the buffer exceeds a size threshold. If the host app or FPE exits cleanly, buffered events are flushed first. If it crashes, pending events are lost (acceptable).

If the user has no network, events accumulate in memory up to a hard cap of 1000 events (~250 KB), after which oldest events are dropped. Once connectivity returns, the flush succeeds.

Events that are re-queued after a failed or partially-rejected flush carry an internal retry counter. After 3 re-queue attempts the event is silently dropped. This prevents a permanently-rejected item (e.g. a 503 per-item error inside a 206) from circulating indefinitely and consuming network or CPU.

No persistent on-disk telemetry queue — keeps complexity down.

## Crash reporting

Unhandled errors go through the same telemetry pipeline:

- Swift fatal errors and unhandled exceptions send a `crash` event with a SHA256 of the call stack prefix as `errorCode`, plus `appVersion`. We do NOT send the stack trace itself (which can contain file paths or memory addresses).
- Unhandled errors in the OneLake / Fabric clients emit `error` events with the API error code.

This is enough to detect "version X has a new crash class" without leaking user data.

## Querying

KQL examples for the App Insights resource:

```kql
// Daily active installs
customEvents
| where name == "app_start"
| where timestamp > ago(30d)
| summarize dcount(tostring(customDimensions.installId)) by bin(timestamp, 1d)
| render timechart

// Tenants using OFEM
customEvents
| where isnotempty(tostring(customDimensions.tenantId))
| summarize events = count(), installs = dcount(tostring(customDimensions.installId))
       by tenantId = tostring(customDimensions.tenantId)
| order by installs desc

// Top errors per version
customEvents
| where name in ("error", "crash")
| summarize count() by tostring(customDimensions.appVersion),
                       tostring(customDimensions.errorCode)
| order by count_ desc
```
