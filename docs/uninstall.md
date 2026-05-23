# Uninstall

## Keep your cache and config

```bash
brew uninstall --cask ofe
```

This removes the app and the LaunchAgent. Your local cache, sign-in state, and config stay on disk so a future re-install picks up where you left off.

## Remove everything

```bash
brew uninstall --cask --zap ofe
```

The `--zap` flag also deletes:

- `~/Library/Application Support/dev.debruyn.ofe/` — config, install ID, daemon socket
- `~/Library/Caches/dev.debruyn.ofe/` — cached blobs and SQLite metadata
- `~/Library/Logs/dev.debruyn.ofe/` — daemon logs
- The shared App Group container under `~/Library/Group Containers/`
- Per-account mount folders under `~/Library/CloudStorage/OneLake-*/`

The cached Keychain items (one per account) are removed by the daemon's normal `account remove` flow; if you skipped that and want them gone too, search the Keychain Access app for "dev.debruyn.ofe" and delete the matches.

## Revoke OFE's access in your tenant

Removing the app does not revoke OFE's OAuth grant in your Microsoft Entra tenant. To do that:

1. Open [https://myapplications.microsoft.com](https://myapplications.microsoft.com).
2. Find "OneLake File Explorer for macOS".
3. Click "Manage", then "Revoke".

Until you revoke, the app remains visible in your account's "My Apps" list even if it isn't installed anywhere.
