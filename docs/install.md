# Install

## Homebrew (recommended)

```bash
brew install --cask sdebruyn/ofe/ofe
```

That single command:

- Downloads the signed, notarized `OneLake.app`.
- Registers a per-user LaunchAgent so the background daemon starts at login.
- Puts the `ofe` CLI on your `$PATH`.

No extra dependencies, no system-level changes, no admin password.

## Requirements

- **macOS 14 Sonoma or later** — earlier versions are not supported because the modern File Provider APIs we rely on (replicated extension, per-domain enumeration) only stabilised in 14.
- **Apple Silicon (arm64)** — we do not ship Intel binaries.
- **Internet connection** for sign-in and for streaming files from OneLake on demand.

## Verify

```bash
ofe --version
ofe status
```

`ofe status` should print the daemon as not running yet (we haven't signed in). The next step is [Sign in](sign-in.md).

## Updates

```bash
brew upgrade --cask ofe
```

Your sign-in state and your local cache survive an upgrade.

## Where things live

After install, OFE writes to three locations under your home directory:

| Path | Purpose |
|---|---|
| `~/Applications/OneLake.app` (or `/Applications/`) | The host app |
| `~/Library/Application Support/dev.debruyn.ofe/` | Config (`config.toml`), daemon socket |
| `~/Library/Caches/dev.debruyn.ofe/` | Local blob cache + SQLite metadata |
| `~/Library/Logs/dev.debruyn.ofe/` | Daemon logs (rotated) |
| `~/Library/LaunchAgents/dev.debruyn.ofe.daemon.plist` | Autostart for the daemon |
| `~/OneLake/` | The mount the File Provider Extension exposes in Finder |

See [Uninstall](uninstall.md) for how to remove everything.
