# Use in Finder

Open Finder. You'll see **OneLake** in the sidebar under Locations. Inside:

```
~/OneLake/
├── work/
│   └── Sales Analytics/
│       └── BronzeLake.lakehouse/
│           ├── Files/
│           │   └── raw/
│           │       └── 2026-Q2.csv
│           └── Tables/
└── client-a/
    └── ...
```

## What just works

- **Drag-and-drop** to upload.
- **Double-click** to open. Files are streamed from OneLake on demand and cached locally, so a second open is instant.
- **Save in any app** to write back to OneLake.
- **Spotlight** indexes file names (not contents — that would download the entire lake).
- **Quick Look** previews CSVs, images, PDFs without downloading.
- **Right-click → "Always Keep on this Mac"** for offline access.
- **Right-click → "Free up space"** to drop the local copy and keep the placeholder.

## What is special

- **Online-only placeholders by default.** Files show a cloud icon until you open them. This keeps your disk usage low even if a lakehouse is huge.
- **Per-account folders.** Different accounts and different tenants live next to each other; you never need to "switch account".
- **Adaptive sync.** Folders you're actively browsing refresh every 30 seconds; folders you visited recently every 5 minutes; the rest on-demand. The daemon does this in the background.

## What you can't do from Finder

A few things are managed entirely by Microsoft Fabric and aren't exposed through the file-system layer:

- **Create or rename a workspace or lakehouse** — go to the Fabric portal.
- **Manage permissions** — go to the Fabric portal.
- **Change the schema of a Delta table inside `Tables/`** — OneLake rejects writes that would corrupt the Delta log; safe but you'll see "operation not permitted" if you try.

## Files OFE doesn't upload

macOS scatters small metadata files everywhere (`.DS_Store`, `._foo`, `.Spotlight-V100`, `.Trashes`, `.fseventsd`). OFE silently filters them on upload so they never reach your lake. You won't see them in OneLake even though they exist locally.

## Multiple Macs

The same OneLake account can be added on multiple Macs. Each Mac has its own local cache and its own LaunchAgent; OneLake is the source of truth, so changes made on one Mac become visible on the others on the next adaptive-poll cycle (typically within 30 seconds for an actively-browsed folder).

## Performance expectations

- **Listing a folder** with up to a few hundred items: instant from cache, well under a second from OneLake.
- **Opening a file**: limited by your network. A 100 MB CSV typically streams in 1–3 seconds on a fibre connection.
- **Uploading**: chunked at 4 MiB. A 1 GiB file uploads in roughly minute-and-some on a 100 Mbit upload.
- **Background poller**: refreshes touched folders every 5 minutes; load is negligible.

## When the network is gone

- Files you've opened recently are in the local cache and remain readable.
- New reads and uploads queue and retry when the network returns.
- The menu-bar status icon switches to "offline".
