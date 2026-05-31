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

> **On-disk path vs Finder display name.** Throughout this doc, the
> on-disk paths under `~/Library/CloudStorage/OneLake-<alias>/` use an
> ASCII hyphen (`0x2d`), matching the OneDrive / Google Drive
> convention; only the Finder sidebar **display name** (set via
> `NSFileProviderDomain.displayName`) is rendered with an em-dash for
> visual separation, e.g. `OneLake — work`. macOS constructs the
> on-disk folder name from `<CFBundleDisplayName>-<displayName>`, so the
> `displayName` we pass is just the alias (`work`, `client-a`), never
> the pre-joined `"OneLake — work"` form.

## Why

The relevant Apple symbols, with their actual purpose:

| Symbol | What it does | Available |
|---|---|---|
| [`NSFileProviderDomain.pathRelativeToDocumentStorage`](https://developer.apple.com/documentation/fileprovider/nsfileproviderdomain/pathrelativetodocumentstorage) | Internal subdirectory of the extension's container. Not user-visible. Does not control the Finder mount path. | macOS 11+ |
| [`NSFileProviderManager.getUserVisibleURL(for:)`](https://developer.apple.com/documentation/fileprovider/nsfileprovidermanager) | Returns the URL macOS chose under `~/Library/CloudStorage/`. Read-only — the provider does not get to pick it. | macOS 11+ |
| [`NSFileProviderDomain.supportedKnownFolders`](https://developer.apple.com/documentation/fileprovider/nsfileproviderdomain) / `replicatedKnownFolders` | Declares which Apple known folders (`desktop`, `documents`) this domain *could* replicate. | macOS 15+ |
| [`NSFileProviderKnownFolders`](https://developer.apple.com/documentation/fileprovider/nsfileproviderknownfolders) | OptionSet with exactly two cases: `.desktop`, `.documents`. Not extensible. The `NSFileProviderKnownFolders.h` header (line 104) states verbatim: *"Currently, only claiming both ~/Desktop and ~/Documents together is allowed."* | macOS 15+ |
| [`NSFileProviderKnownFolderLocations`](https://developer.apple.com/documentation/fileprovider/nsfileproviderknownfolderlocations) | Specifies `desktopLocation` / `documentsLocation` *within the domain's replicated tree*. Used to advertise where, inside the provider's own storage, the user's Desktop and Documents end up after a takeover. `shouldCreateBinaryCompatibilitySymlink` defaults to `YES` (header line 56), so on takeover macOS creates a symlink from the logical in-domain Desktop/Documents location back to `~/Desktop` / `~/Documents` for binary compatibility. | macOS 15+ |
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

Accept one Finder "Locations" entry per account. On disk macOS will
create (ASCII hyphen, matching OneDrive / Google Drive):

```
~/Library/CloudStorage/OneLake-work/<workspace>/...
~/Library/CloudStorage/OneLake-client-a/<workspace>/...
```

In the Finder sidebar each domain shows up as its own entry. Whatever
separator macOS inserts between `CFBundleDisplayName` (`OneLake`) and
`NSFileProviderDomain.displayName` (`work`, `client-a`) is what users
will read — empirically OneDrive's sidebar reads `OneDrive — Tenant`
with an em-dash, even though the on-disk folder is
`OneDrive-Tenant` with an ASCII hyphen. We pass the bare alias as
`displayName` and let macOS compose the sidebar string; the on-disk
path stays ASCII-clean for shell completion, `grep`, and `find`. The
exact display separator needs an empirical check on a registered
Personal-Team-signed domain before we lock it in.

The user gives up a single collapsible parent folder, but gains
exactly the layout that every other cloud-storage app on macOS uses —
which matches the hard constraint of integrating "the way OneDrive
and Google Drive integrate".

### Why the other workarounds are worse

- **B — one domain, virtual "accounts" top-level enumerator.** Auth
  isolation is not the issue here — MSAL token storage, Keychain
  scoping, and per-account demultiplexing all live in the Go core
  (`internal/auth/`), so a single super-domain that passes
  `<account_alias>` as the first path component on every FFI call
  would still get the right token. The real costs are framework
  features that File Provider only exposes per domain:
  1. **Sidebar UX.** Users expect one Finder "Locations" entry per
     account (matching OneDrive / Google Drive). A single "OneLake"
     entry with virtual subfolders breaks that context-switch
     metaphor.
  2. **`NSFileProviderManager.signal*` is domain-scoped.** A single
     domain means signalling a working-set change for one account
     forces every account to re-enumerate.
  3. **Per-domain state.** `isDisconnected`, `userEnabled`, and the
     hidden-domain flag are all per-domain. A single domain loses the
     ability for a user to pause / disable one account independently.
  4. **Per-domain icon.** The planned italic-icon UX for
     capacity-paused workspaces (see the open question in
     `docs/file-provider.md`) is per-domain; a super-domain can only
     show one icon for the whole product.
- **C — real `~/OneLake/` directory with symlinks to each
  `~/Library/CloudStorage/OneLake-<alias>/`.** The Finder sidebar is
  driven by File Provider and shows the canonical
  `~/Library/CloudStorage/OneLake-<alias>/` entries regardless of any
  symlink we add, so a `~/OneLake/` parent only helps users who
  navigate by typing paths or `ls`. On top of that low cosmetic ROI,
  the concrete failure modes are:
  1. **Time Machine.** Symlinks are backed up as symlinks, but the
     target is also backed up via the CloudStorage path, so we get no
     dedup benefit; users who include `~/OneLake/` in their backup
     scope double the work the backup engine does walking the tree.
  2. **Quick Look target leakage.** A Quick Look invocation on the
     symlink's directory entry resolves to the target before
     rendering, so previews and the .DS_Store / metadata they pull in
     are the *target's*, not the link's — which is confusing if the
     user thinks `~/OneLake/` is a real folder they control.
  3. **Rename / move fragility.** Any user move or rename of
     `~/OneLake/` or one of its children breaks every account at once
     and we have to detect and repair it on every daemon start, plus
     on every account add / remove.
  Documenting a one-line `ln -s` that users can run themselves keeps
  the cosmetic option open without us owning the maintenance.
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
  `~/Library/CloudStorage/OneLake-<alias>/...`. The menu bar app's
  per-account **Open in Finder** action navigates to that real path.
- **TODO (follow-up, out of scope for this PR):** the `MountDomain`
  type in `internal/ipc` (currently just `Identifier` + `DisplayName`)
  needs a third `MountPath` field carrying the absolute user-visible
  path, so the host app can display the on-disk location without
  reconstructing it. The Swift extension will populate it from
  `NSFileProviderManager.getUserVisibleURL(for:)` once the extension is
  wired up. Tracking this here so the IPC type doesn't drift further
  from the spike's recommendation.
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
