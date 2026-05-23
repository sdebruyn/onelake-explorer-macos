# Uninstall

## Keep your cache and config

```bash
brew uninstall --cask ofem
```

This removes the app and the LaunchAgent. Your local cache, sign-in state, and config stay on disk so a future re-install picks up where you left off.

## Remove everything

```bash
brew uninstall --cask --zap ofem
```

The `--zap` flag also deletes:

- `~/Library/Application Support/dev.debruyn.ofem/` — config, install ID, daemon socket
- `~/Library/Caches/dev.debruyn.ofem/` — cached blobs and SQLite metadata
- `~/Library/Logs/dev.debruyn.ofem/` — daemon logs
- The shared App Group container under `~/Library/Group Containers/`
- Per-account mount folders under `~/Library/CloudStorage/OneLake-*/`

The cached Keychain items (one per account) are removed by the daemon's normal `account remove` flow; if you skipped that and want them gone too, search the Keychain Access app for "dev.debruyn.ofem" and delete the matches.

## Revoke OFEM's access in your tenant

Removing the app does not revoke OFEM's OAuth grant in your Microsoft Entra tenant. To do that:

1. Open [https://myapplications.microsoft.com](https://myapplications.microsoft.com).
2. Find "OneLake File Explorer for macOS".
3. Click "Manage", then "Revoke".

Until you revoke, the app remains visible in your account's "My Apps" list even if it isn't installed anywhere.
