# Logging

OFEM writes structured diagnostic logs to a rotating JSON-lines file alongside
the Unified Logging System (Console.app / `log stream`).

## On-disk log file

| Property | Value |
|---|---|
| Location | `~/Library/Group Containers/6D79CUWZ4J.group.dev.debruyn.ofem/log/ofem.log` |
| Format | One JSON object per line (newline-delimited) |
| Rotation | Rotated when the active file exceeds 10 MB; up to 5 backups kept |
| Filename pattern | `ofem.log`, `ofem.log.1`, … `ofem.log.5` |

Each line contains at minimum the reserved keys `time` (ISO 8601), `level`,
and `msg`, plus any call-site metadata keys.

Example:

```json
{"errorCode":"NSCocoaErrorDomain.4","level":"WARN","msg":"delete: cache delete failed","time":"2026-07-14T09:12:03.000Z"}
```

## Default log level

The default level is **info**. Override via the advanced config key
`log.level` (`"debug"`, `"info"`, `"warn"`, `"error"`).

## Severity policy

| Level | When to use |
|---|---|
| `DEBUG` | Per-call traces, pagination counters, request/response details. Off in production by default. |
| `INFO` | Lifecycle events and non-browsing user-initiated actions (engine built, engine reloaded, domain added/removed). |
| `WARN` | Transient or retryable failures where the operation continues or degrades gracefully (cache write failure, stale row skip, incomplete listing). |
| `ERROR` | Terminal failures that abort the current operation and surface an error to the framework or caller (engine build failure, unrecoverable sync error). |

## Using OfemLogger

Obtain a logger via `OfemEngine.sync.logger` (SyncEngine) or construct one
with `OfemLogger(configuration:)`.

### Basic overloads

```swift
logger.debug("cache fetch", metadata: ["key": key.stableKeyString])
logger.info("engine built", metadata: ["alias": alias])
logger.warn("mkdir: upsert failed", metadata: ["path": key.path])
logger.error("engine build failed", metadata: ["alias": alias])
```

### Error-taking overloads

When a Swift `Error` is in scope, prefer the error-taking overloads. They
automatically inject `errorCode` (`<domain>.<code>`) and `errorDescription`
(the localized description) as metadata keys, avoiding boilerplate at each
call site:

```swift
} catch {
    logger.warn("delete: cache delete failed", error: error)
}

} catch {
    logger.error("engine build failed", error: error, metadata: ["alias": alias])
}
```

Both overloads accept an optional `metadata` dictionary for additional context.
Caller-supplied keys are preserved; `errorCode` and `errorDescription` are
always added (and will overwrite any same-named caller key).

## Privacy and redaction

OFEM follows a two-tier privacy model.

**DEBUG builds** — metadata values are written verbatim to both `os.Logger`
and the on-disk JSON file so developers can inspect real paths, UPNs, and
workspace names locally.

**Release builds** — metadata values are routed through
`Privacy.scrubLogValue(_:)` before being written to the JSON file. Values
composed entirely of `[A-Za-z0-9_.:-]` and within 256 bytes are written
verbatim; all others collapse to `"redacted"`.

Implications for the error-taking overloads:

- `errorCode` is formatted as `"<domain>.<code>"` (e.g.
  `"NSCocoaErrorDomain.4"`). Standard Apple domains use only safe characters
  and survive redaction unchanged.
- `errorDescription` contains free-form localized text and will typically be
  redacted in release builds. It is still included because it aids local
  development and is harmless as `"redacted"` in production.

The `msg` field is always written verbatim — log messages must be static
string constants that never carry dynamic or PII-bearing data.

## Inspecting logs

Stream live (macOS system log):

```bash
log stream --predicate 'subsystem == "dev.debruyn.ofem"' --level debug
```

Tail the on-disk file:

```bash
tail -f ~/Library/Group\ Containers/6D79CUWZ4J.group.dev.debruyn.ofem/log/ofem.log \
  | python3 -m json.tool
```
