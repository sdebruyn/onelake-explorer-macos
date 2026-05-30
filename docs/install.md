# Install

```bash
brew install --cask sdebruyn/ofem/ofem
```

That single command installs `OneLake.app`. The first time you launch it, the app registers its background helper to start at every login. No extra dependencies, no system-level changes, no admin password.

## Requirements

- macOS 14 Sonoma or later
- Apple Silicon (arm64)
- An internet connection

## Verify

Open `OneLake.app` from Launchpad or `/Applications`. A OneLake icon appears in the menu bar.

The next step is [Sign in](sign-in.md).

## Updates

```bash
brew upgrade --cask ofem
```

Your sign-in state and your local cache survive an upgrade.
