# macOS integration — File Provider Extension

OneLake appears in Finder the way OneDrive and Google Drive do: with online-only placeholders, on-demand download, a sidebar entry, and a custom icon. On modern macOS the Apple-blessed way to achieve that is a **File Provider Extension**.

## Mount mechanism

OFEM ships as a signed, notarized macOS `.app` containing a File Provider Extension. The extension is the mount mechanism.

See [docs/file-provider.md](file-provider.md) for the technical design.

## What you get

- Native entry in Finder sidebar under "Locations" with our custom icon and "OneLake" display name.
- Per-file sync-status overlay icons (cloud, downloading, locally cached) managed by macOS.
- Right-click "Free up space" / "Always Keep on this Mac" managed by macOS.
- Spotlight indexing, Quick Look previews, Share Sheet — out of the box.
- Time Machine exclusion of placeholders by default.
- No `/Volumes` mount that disappears on sleep/wake.
- Sandbox isolation: the extension runs gated, limiting blast radius if something goes wrong.

## Minimum macOS and architecture

- **macOS 14 Sonoma minimum.** Latest File Provider APIs (placeholder icons, fast cache reclamation, advanced enumeration) get incremental improvements through macOS 14.
- **arm64 only.** No Intel binaries.

## Daemon ↔ Extension boundary

The File Provider Extension is sandboxed and short-lived — macOS
launches it on demand for each Finder request and tears it down again.
It cannot hold long-lived network sockets, run scheduled polling, or
perform interactive auth flows. To bridge that gap a separate
**daemon** process (`OneLake.app/Contents/Helpers/ofem daemon run`,
started by the LaunchAgent the host app registers via SMAppService on
first launch) handles those long-running concerns and signals the
extension when it has news.

The wire protocol the host app and the extension use to talk to the
daemon is the local-only JSON-RPC 2.0 socket described in
[`internal/ipc`](../internal/ipc). It binds at
`~/Library/Group Containers/6D79CUWZ4J.group.dev.debruyn.ofem/ofem.sock`, owner-only
0600 permissions, length-prefixed frames capped at 1 MiB.

The daemon → extension direction is wrapped over an XPC service (the
extension's Apple-blessed inbound API) and calls
`NSFileProviderManager.signalEnumerator(for:)` to nudge re-enumeration
when Fabric's adaptive polling spots a change.
