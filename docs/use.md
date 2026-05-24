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
- **Double-click** to open. Files stream from OneLake on demand and are cached locally, so a second open is instant.
- **Save in any app** to write back.
- **Spotlight** indexes file names.
- **Quick Look** previews CSVs, images, PDFs without downloading.
- Right-click → **Always Keep on this Mac** for offline access, or **Free up space** to drop the local copy.

## Multiple accounts

Each account has its own top-level folder under `~/OneLake/`. Different tenants live next to each other — you never need to "switch account".

## What you can't do from Finder

Some things are managed through the Microsoft Fabric portal and aren't exposed as files:

- Create or rename a workspace or lakehouse.
- Manage permissions.
- Change the schema of a Delta table inside `Tables/`.

## When the network is gone

Files you've recently opened stay readable from cache. New reads and uploads queue and retry when the network returns. The menu-bar icon shows "offline".
