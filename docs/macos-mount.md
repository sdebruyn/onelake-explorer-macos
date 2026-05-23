# macOS integration — decision and alternatives considered

OneLake will appear in Finder the way OneDrive and Google Drive do: with online-only placeholders, on-demand download, a sidebar entry, and a custom icon. On modern macOS there is exactly one Apple-blessed way to achieve that: a **File Provider Extension**.

This document explains why we chose File Provider Extension and what alternatives we deliberately rejected.

## Decision: File Provider Extension only

We ship a signed, notarized macOS `.app` containing a File Provider Extension as our mount mechanism, starting from MVP. No intermediate FUSE-T phase.

See [docs/file-provider.md](file-provider.md) for the technical design.

## Why not FUSE-T as a stepping stone

The first draft of this plan included a FUSE-T mount as an intermediate Phase 1, with File Provider Extension as Phase 3. Sam rejected this as wasted work. The reasoning is sound:

- The **mount layer code itself is not reusable** when migrating from FUSE-T to File Provider Extension. They are fundamentally different APIs:
  - FUSE-T = Go callbacks implementing VFS operations.
  - File Provider Extension = Swift `NSFileProviderExtension`, `NSFileProviderItem`, `NSFileProviderEnumerator` subclasses bridged to our Go core.
- The launchd / daemon glue differs too — FUSE-T is a Go process we manage; File Provider Extension is an `.appex` macOS manages for us.
- The estimated **~2-3 weeks of FUSE-T integration work** would go in the bin at handoff.

What IS reusable across both options (and where 80% of the engineering lives):
- The Go core library (auth, OneLake API, cache, sync logic) — 100% reusable as a static library.
- The setup CLI for account management — 100% reusable.
- Telemetry, logging, config — 100% reusable.

Given that the Apple Developer Program ($99/year) is a non-blocker for the project, building the right thing once is cheaper than building a throwaway intermediate.

## Why not macFUSE

macFUSE installs a kernel extension. Since macOS 11 that means the user must enable Reduced Security in Recovery Mode (Apple Silicon) or approve a System Extension in Privacy & Security. A reboot is required. Future macOS updates can break it.

This directly violates our hard constraint "no system-level changes required from the user". Rejected on principle.

> Note: macFUSE 5.1 (October 2025) added an FSKit backend for user-space mode on macOS 26+. Eventually macFUSE may become viable without root-level changes. We do not plan to revisit unless File Provider Extension proves unworkable.

## Why not plain NFS / SMB loopback in user space

We could run our own NFS-v4 or SMB server in user space and let macOS mount the share. This is essentially what FUSE-T does internally. Re-implementing it is wasted effort vs. just using FUSE-T, and the resulting UX is still inferior to File Provider Extension (no sidebar entry, no native placeholders, no Spotlight integration).

Rejected for the same reasons FUSE-T was rejected, plus the additional cost of building the server.

## What File Provider Extension gives us

- Native entry in Finder sidebar under "Locations" with our custom icon and "OneLake" display name.
- Per-file sync-status overlay icons (cloud, downloading, locally cached) — managed by macOS automatically.
- Right-click → "Free up space" / "Always Keep on this Mac" — managed by macOS automatically.
- Spotlight indexing, Quick Look previews, Share Sheet — out of the box.
- Time Machine exclusion of placeholders by default.
- No `/Volumes` mount to disappear on sleep/wake.
- Sandbox isolation: the extension runs gated, limiting blast radius if something goes wrong.

## What File Provider Extension costs us

- Apple Developer Program membership (~$99/year) for code signing and notarization.
- App Group entitlement and File Provider entitlement.
- Swift host app + Swift extension wrapping our Go core via cgo/C-ABI.
- Sandbox restrictions on the extension — we have to be careful what we access.
- macOS 12.5 minimum for File Provider; we go higher to macOS 14 Sonoma per Sam's choice, to use the latest APIs and avoid compat code.

## Min macOS and architecture

- **macOS 14 Sonoma minimum.** Picked over the technically possible 12.5 because Sam wants to stay on modern APIs and accepts the smaller addressable Mac population. Latest File Provider APIs (placeholder icons, fast cache reclamation, advanced enumeration) are stable from 13 onwards but get incremental improvements in 14.
- **arm64-only.** Sam chose this; we do not ship Intel binaries. Apple Silicon adoption among modern data-engineering Macs is high enough to make Universal builds unnecessary overhead.

## Summary

| Option | Verdict |
|---|---|
| File Provider Extension | **Chosen.** Native UX, Apple-blessed, future-proof. |
| FUSE-T as stepping stone | Rejected. Mount-layer code is throwaway. |
| macFUSE | Rejected. Violates "no system changes" constraint. |
| Plain NFS/SMB loopback | Rejected. Strictly inferior to File Provider Extension. |

## Daemon ↔ Extension boundary

The File Provider Extension is sandboxed and short-lived — macOS
launches it on demand for each Finder request and tears it down again.
It cannot hold long-lived network sockets, run scheduled polling, or
perform interactive auth flows. To bridge that gap we run a separate
**daemon** process (`ofe daemon run`, started by the LaunchAgent
installed via `ofe daemon install`) that handles those long-running
concerns and signals the extension when it has news.

The wire protocol the CLI, host app, and (eventually) the extension
use to talk to the daemon is the local-only JSON-RPC 2.0 socket
described in [`internal/ipc`](../internal/ipc). It binds at
`~/Library/Application Support/dev.debruyn.ofe/ofe.sock`, owner-only
0600 permissions, length-prefixed frames capped at 1 MiB.

For Phase 1, the daemon → extension direction will be wrapped over an
XPC service (the extension's only Apple-blessed inbound API) and call
`NSFileProviderManager.signalEnumerator(for:)` to nudge re-enumeration
when Fabric's adaptive polling spots a change. For now the IPC layer
only connects CLI ↔ daemon; the extension and XPC bridge land
alongside the host app in Phase 1.
