# Install

```bash
brew install --cask sdebruyn/ofem/ofem
```

That single command installs `OneLake.app`, sets it to start at login, and puts the `ofem` CLI on your `$PATH`. No extra dependencies, no system-level changes, no admin password.

## Requirements

- macOS 14 Sonoma or later
- Apple Silicon (arm64)
- An internet connection

## Verify

```bash
ofem --version
```

The next step is [Sign in](sign-in.md).

## Updates

```bash
brew upgrade --cask ofem
```

Your sign-in state and your local cache survive an upgrade.
