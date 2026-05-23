# Privacy & telemetry

OFEM collects a small amount of opt-out telemetry to understand adoption, catch crashes early, and prioritise fixes. This page describes exactly what is and isn't sent, and how to turn it off.

## What is collected

Each event is a small JSON record with these fields:

| Field | Example | Notes |
|---|---|---|
| `installId` | UUIDv4 generated locally on first run | Pseudonymous; removed when you `brew uninstall --zap ofem` |
| `appVersion` | `2026.05.1` | |
| `platform` | `darwin` | |
| `arch` | `arm64` | |
| `osVersion` | `14.5.1` | |
| `tenantId` | Microsoft Entra tenant GUID | Only sent when an event is tied to a specific OneLake operation |
| `accountAliasHash` | first 8 hex chars of `sha256(alias)` | So we can correlate events from the same account-context without storing the alias |
| `event` | `file_download` | One of a fixed catalogue (see below) |
| `durationMs` | `423` | For events that complete an operation |
| `success` | `true` / `false` | |
| `errorCode` | `AADSTS50079` | Short error code; long strings are redacted |
| `bytesTransferred` | `1048576` | Where relevant |

## What is NOT collected

- Your UPN, email address, or display name.
- Workspace names, item names, file names, or folder paths.
- File contents.
- IP addresses (Application Insights logs these by default in some plans — we have it turned off).
- Anything outside the OFEM process boundary.

## Event catalogue

Currently emitted:

| Event | When |
|---|---|
| `app_start` / `app_stop` | Daemon lifecycle |
| `account_added` / `account_removed` | After `ofem login` / `ofem account remove` |
| `workspace_list` / `item_list` / `folder_list` | After a discovery API call |
| `file_download` / `file_upload` / `file_delete` | After file I/O |
| `folder_create` / `folder_delete` | After folder operations |
| `mount_start` / `mount_stop` | File Provider domain lifecycle |
| `sync_pulled` | Background poller detected remote changes |
| `error` / `panic` | Recoverable error / Go panic recovered |

## Where it goes

To an Azure Application Insights resource in the maintainer's Azure subscription, free tier. From there it lives only for the retention period (90 days by default) and is queried via the Application Insights portal.

## How to turn it off

Either of these disables telemetry instantly; the daemon picks up the change on its next start.

```bash
ofem config set telemetry off
```

or set the env var before launching the daemon:

```bash
export OFEM_TELEMETRY=0
```

You can verify with `ofem config get telemetry`.

## Source-built binaries

If you build OFEM yourself (clone the repo and `go build`), the Application Insights connection string is empty by default. That means **telemetry is silently off for source builds** — only the official Homebrew release ships with the embedded connection string. Contributors and forks do not send data to the maintainer's telemetry endpoint.

## How to inspect what's sent

OFEM logs every telemetry event at debug level. Tail the daemon log to see exactly what's being sent:

```bash
tail -f ~/Library/Logs/dev.debruyn.ofem/ofem.log | grep telemetry
```

## Questions or concerns

Open a [Discussion](https://github.com/sdebruyn/onelake-explorer-macos/discussions) or file an issue. The full design rationale lives in [docs/telemetry.md](telemetry.md) (the developer-facing version of this page).
