# File Provider domain nesting under `~/OneLake/` — spike outcome

**Answer: no.** A File Provider Extension on macOS 14+ cannot anchor its
domains under an arbitrary parent folder like `~/OneLake/`. Each
`NSFileProviderDomain` is rendered by macOS at a system-chosen path
under `~/Library/CloudStorage/<BundleDisplayName>[-<DomainDisplayName>]/`
and is surfaced in Finder as its own top-level "Locations" entry. The
`replicatedKnownFolder` API was a red herring: it exists, but it is
**macOS 15 Sequoia or later** and is the iCloud-Drive-style mechanism
for syncing the Apple-defined `desktop` and `documents` folders only.
It does not let a third-party provider mount its own folder hierarchy
under `~/OneLake/`.

## Why

The relevant Apple symbols, with their actual purpose:

| Symbol | What it does | Available |
|---|---|---|
| [`NSFileProviderDomain.pathRelativeToDocumentStorage`](https://developer.apple.com/documentation/fileprovider/nsfileproviderdomain/pathrelativetodocumentstorage) | Internal subdirectory of the extension's container. Not user-visible. Does not control the Finder mount path. | macOS 11+ |
| [`NSFileProviderManager.getUserVisibleURL(for:)`](https://developer.apple.com/documentation/fileprovider/nsfileprovidermanager) | Returns the URL macOS chose under `~/Library/CloudStorage/`. Read-only — the provider does not get to pick it. | macOS 11+ |
| [`NSFileProviderDomain.supportedKnownFolders`](https://developer.apple.com/documentation/fileprovider/nsfileproviderdomain) / `replicatedKnownFolders` | Declares which Apple known folders (`desktop`, `documents`) this domain *could* replicate. | macOS 15+ |
| [`NSFileProviderKnownFolders`](https://developer.apple.com/documentation/fileprovider/nsfileproviderknownfolders) | OptionSet with exactly two cases: `.desktop`, `.documents`. Not extensible. | macOS 15+ |
| [`NSFileProviderKnownFolderLocations`](https://developer.apple.com/documentation/fileprovider/nsfileproviderknownfolderlocations) | Specifies `desktopLocation` / `documentsLocation` *within the domain's replicated tree*. Used to advertise where, inside the provider's own storage, the user's Desktop and Documents end up after a takeover. | macOS 15+ |
| [`NSFileProviderManager.claimKnownFolders(_:localizedReason:completionHandler:)`](https://developer.apple.com/documentation/fileprovider/nsfileprovidermanager) | Asks the system to redirect `~/Desktop` and `~/Documents` into the domain — the iCloud Drive "Desktop & Documents" feature, generalised to third parties. | macOS 15+ |

In other words: `replicatedKnownFolders` is about *taking over* the
user's existing Desktop / Documents directories (like iCloud Drive
does), not about *grouping multiple provider domains under a custom
parent folder*.

Independent confirmation of the constraint from third-party providers:
- Google Drive lands at `~/Library/CloudStorage/GoogleDrive-<email>/`,
  one folder per account.
- OneDrive lands at `~/Library/CloudStorage/OneDrive-<tenant>/`, one
  folder per account.
- Dropbox lands at `~/Library/CloudStorage/Dropbox/`.

None of them group multiple accounts under a single
`~/CloudProvider/` parent. The TidBITS write-up
([Apple's File Provider Forces Mac Cloud Storage Changes](https://tidbits.com/2023/03/10/apples-file-provider-forces-mac-cloud-storage-changes/))
states it plainly: with the File Provider approach, users cannot
specify a different location for their cloud-storage files, and each
provider gets its own subdirectory.

The OneLake mount-path target documented in `CLAUDE.md`,
`~/OneLake/<alias>/<workspace>/<folder>?/<item>/...`, is therefore
**not implementable as a single visible parent**. It is implementable
*per domain*: the path *inside* a domain still uses that shape, just
with the system-chosen parent in front of it.

## Recommended path forward: workaround A — separate top-level folders

Accept one Finder "Locations" entry per account. macOS will create:

```
~/Library/CloudStorage/OneLake-work/<workspace>/...
~/Library/CloudStorage/OneLake-client-a/<workspace>/...
```

with each appearing as its own sidebar entry named
`OneLake — work` / `OneLake — client-a` (via the domain's
`displayName`).

The naming convention `OneLake — <alias>` (em-dash, mirroring the
Google Drive / OneDrive style) keeps grouping intuitive: every entry
sorts together in Finder and reads as part of the same product. The
user gives up a single collapsible parent folder, but gains exactly
the layout that every other cloud-storage app on macOS uses — which is
what Sam asked for in the hard constraints ("the way OneDrive and
Google Drive integrate").

### Why the other workarounds are worse

- **B — one domain, virtual "accounts" top-level enumerator.** Loses
  per-account auth isolation. Every Fabric call from inside any
  account folder runs inside the same extension instance; we would
  have to multiplex MSAL tokens, sandbox isolation, and
  `NSFileProviderManager.signal*` paths ourselves. Also loses the
  per-account Finder sidebar entry users expect for switching
  context. Hard pass.
- **C — real `~/OneLake/` directory with symlinks to each
  `~/Library/CloudStorage/OneLake-<alias>/`.** Symlinks into
  `~/Library/CloudStorage` are fragile: Finder follows them
  inconsistently, drag-and-drop into a symlinked File Provider folder
  has been reported to break placeholders, and the parent directory
  becomes a synthetic thing we have to maintain on install / uninstall
  / account add / account remove. Backup tools (Time Machine, CCC)
  also handle the symlink target differently than the link. Not worth
  the maintenance burden for cosmetic grouping.
- **D (new option found during the spike) — `replicatedKnownFolders`
  takeover of `~/Documents/OneLake/` or similar.** Even setting aside
  that this is macOS 15+ (we target 14), `claimKnownFolders` only
  accepts `.desktop` and `.documents`; there is no way to claim a
  user-chosen subdirectory. Wrong tool.

## Consequences for the rest of the architecture

- The item-identifier shape `<accountAlias>/<workspaceGUID>/<itemGUID>/<path>`
  is unaffected — the alias is still the first path component
  *within* the domain.
- `~/OneLake/<alias>/...` in CLAUDE.md should be read as a logical
  path, not a filesystem path. The filesystem-visible path is
  `~/Library/CloudStorage/OneLake-<alias>/...`. The CLI's
  `ofem mount list` should report both forms.
- For users who really want a single entry point in their home
  directory, we can document a one-line `ln -s` they can run
  themselves. We will not create or manage that symlink for them.

## Sources

- [NSFileProviderDomain — Apple Developer Documentation](https://developer.apple.com/documentation/fileprovider/nsfileproviderdomain)
- [NSFileProviderManager — Apple Developer Documentation](https://developer.apple.com/documentation/fileprovider/nsfileprovidermanager)
- [NSFileProviderKnownFolderSupporting — Apple Developer Documentation](https://developer.apple.com/documentation/fileprovider/nsfileproviderknownfoldersupporting)
- [NSFileProviderKnownFolders — Apple Developer Documentation](https://developer.apple.com/documentation/fileprovider/nsfileproviderknownfolders)
- [NSFileProviderKnownFolderLocations — Apple Developer Documentation](https://developer.apple.com/documentation/fileprovider/nsfileproviderknownfolderlocations)
- [`claimKnownFolders(_:localizedReason:completionHandler:)`](https://developer.apple.com/documentation/fileprovider/nsfileprovidermanager)
- [Sync files to the cloud with FileProvider on macOS — WWDC21 session 10182](https://developer.apple.com/videos/play/wwdc2021/10182/)
- [Apple's File Provider Forces Mac Cloud Storage Changes — TidBITS, 2023](https://tidbits.com/2023/03/10/apples-file-provider-forces-mac-cloud-storage-changes/)
- [Build your own cloud sync on iOS and macOS using Apple FileProvider APIs — Claudio Cambra](https://claudiocambra.com/posts/build-file-provider-sync/)
- [FruitBasket / FileProviderTrial sample — `seanses/FileProviderTrial`](https://github.com/seanses/FileProviderTrial)

## No prototype was needed

The question is answered by Apple's own API surface and is consistent
across every shipping third-party File Provider client on macOS. A
Swift test bed would have demonstrated `getUserVisibleURL` returning
`~/Library/CloudStorage/...`, which is exactly what the docs already
state. The `experiments/file-provider-nesting/` directory was not
created.
