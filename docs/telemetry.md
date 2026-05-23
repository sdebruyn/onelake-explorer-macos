# Telemetry design

## Principles

- **Opt-out**, enabled by default, clearly disclosed on first run and in README.
- **Disable any time** with `OFE_TELEMETRY=0` env var or `ofe config set telemetry off` (the daemon picks up the change on next start; the menu bar shows the current state).
- **No PII**: no UPN, no workspace name, no item name, no file name, no folder path.
- **Tenant IDs are collected** (Sam confirmed this is acceptable). Tenant IDs are aggregate-level enough to be useful for understanding adoption per tenant without identifying individual users.
- **Pseudonymous install ID** is generated locally on first run (a random UUIDv4 stored in config) so we can deduplicate events from the same install without identifying the user.
- **No tracking across re-installs**: removing OFE (`brew uninstall --zap`) removes the install ID; reinstalling generates a new one.

## Backend: Azure Application Insights free tier

Chosen for:
- 5 GB/month ingestion free (a comfortable headroom — even at 1 M events/month we are well under).
- Native Go SDK ([`microsoft/ApplicationInsights-Go`](https://github.com/microsoft/ApplicationInsights-Go)).
- Out-of-the-box dashboards in the Azure portal.
- Workbooks for custom analysis without needing Fabric.

For Fabric-side analysis (optional, when richer notebooks are needed): set up Diagnostic Settings export from the App Insights resource to an ADLS Gen2 storage account, then create an OneLake shortcut into a Fabric Lakehouse. The full architecture trade-off is documented in [docs/telemetry-hosting-research.md](telemetry-hosting-research.md).

## Schema

Every event is sent as an App Insights `customEvent` with a fixed property set:

| Property | Type | Required | Example | Notes |
|---|---|---|---|---|
| `installId` | string (UUIDv4) | Yes | `5b3c…` | Generated locally on first run, persisted in config. |
| `appVersion` | string | Yes | `2026.05.1` | The OFE version. |
| `platform` | string | Yes | `darwin` | Always `darwin` for OFE. |
| `arch` | string | Yes | `arm64` | Always `arm64` for OFE. |
| `osVersion` | string | Yes | `14.5.1` | macOS version reported by `sw_vers`. |
| `event` | string | Yes | `file_download` | The event name. |
| `tenantId` | string (GUID) | Conditional | `8d3b…` | When the event is associated with a specific OneLake operation; null for app lifecycle events. |
| `accountAliasHash` | string | Conditional | `sha256(<alias>):8` | First 8 hex chars of the SHA256 of the user-chosen alias, to correlate events from the same account-context without revealing the alias text. |
| `durationMs` | int64 | When relevant | `423` | For events that complete an operation. |
| `success` | bool | When relevant | `true` | For events that complete an operation. |
| `errorCode` | string | When `success=false` | `AADSTS50079` | Backend or library-defined error code. Free text up to 32 chars; **must not contain PII** (we redact any string longer than 32 chars or containing `@`). |

## Event catalog (initial)

| Event | When | Properties beyond defaults |
|---|---|---|
| `app_start` | Daemon process starts | — |
| `app_stop` | Daemon process exits cleanly | — |
| `account_added` | After successful `ofe login` | `tenantId`, `accountAliasHash` |
| `account_removed` | After successful `ofe account remove` | `tenantId`, `accountAliasHash` |
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
| `error` | Recoverable error logged | `errorCode`, `event` (the operation that errored as a string) |
| `panic` | Go panic recovered or process unwound | `errorCode` (hashed stack trace prefix), `appVersion` |

## Connection string distribution

The Application Insights connection string is embedded into the official binary at build time via GoReleaser:

```yaml
ldflags:
  - -X main.appInsightsConnString={{.Env.OFE_APPINSIGHTS_CONNSTRING}}
```

`OFE_APPINSIGHTS_CONNSTRING` is a GitHub Actions secret only available to the official release workflow.

Source builds (someone clones the repo and runs `go build`) get an empty string → the telemetry client silently no-ops. This means contributors and forks **do not send data to our telemetry endpoint** unless they configure their own.

### Threat model of an embedded ingest key

An attacker can extract the connection string from the official binary (e.g. via `strings OFE.app/Contents/Resources/bin/ofe`). They could then send spam events. Mitigations:

- App Insights has built-in sampling and DAILY_CAP we can lower in the portal if we see abuse.
- Connection strings can be rotated by re-issuing one for the App Insights resource. A new OFE release picks up the new key; old binaries silently stop reporting.
- Event volume is in the noise level (millions/month worst case) — App Insights tier costs become an issue only at much higher volumes.
- The data collected is by design non-sensitive — even if an attacker spams events with bogus tenant IDs, our analysis just gets noisier.

This trade-off is documented in the README disclosure.

## First-run disclosure (in CLI and host app)

```
OFE collects anonymous usage events plus tenant IDs to help understand adoption
and improve the tool. We never collect workspace names, file names, or your UPN.

Disable any time:  ofe config set telemetry off
                or set OFE_TELEMETRY=0 in your environment

Learn more:        https://github.com/sdebruyn/onelake-explorer-macos/blob/main/docs/telemetry.md
```

Shown:
- On first `ofe login` in the CLI.
- On first launch of `OneLake.app` (Phase 2+) as a small banner in the host app.

## Local buffering and offline

App Insights Go SDK buffers events in memory and flushes every 10 seconds or when the buffer exceeds a size threshold. If the daemon process exits cleanly, buffered events are flushed first. If it crashes, pending events are lost (acceptable).

If the user has no network, events accumulate in memory up to a hard cap of 1000 events (~250 KB), after which oldest events are dropped. Once connectivity returns, the flush succeeds.

No persistent on-disk telemetry queue — keeps complexity down.

## What about Crash Reporting?

Sam chose integrated, not Sentry-on-the-side. Panics and unhandled errors go through the same telemetry pipeline:

- A `defer recover()` in main captures Go panics. We send a `panic` event with a SHA256 of the stack trace as `errorCode`, plus `appVersion`. We do NOT send the stack trace itself (which can contain file paths or memory addresses).
- Unhandled errors in the OneLake / Fabric clients emit `error` events with the API error code.

This is enough to detect "version X has a new panic class" without leaking user data.

## Querying

KQL examples for the App Insights resource:

```kql
// Daily active installs
customEvents
| where name == "app_start"
| where timestamp > ago(30d)
| summarize dcount(tostring(customDimensions.installId)) by bin(timestamp, 1d)
| render timechart

// Tenants using OFE
customEvents
| where isnotempty(tostring(customDimensions.tenantId))
| summarize events = count(), installs = dcount(tostring(customDimensions.installId))
       by tenantId = tostring(customDimensions.tenantId)
| order by installs desc

// Top errors per version
customEvents
| where name in ("error", "panic")
| summarize count() by tostring(customDimensions.appVersion),
                       tostring(customDimensions.errorCode)
| order by count_ desc
```
