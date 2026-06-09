<p align="center">
  <img src="assets/branding/ofem-logo.svg" alt="OneLake Explorer for macOS" width="120" />
</p>

<h3 align="center">OneLake Explorer for macOS</h3>

**Browse Microsoft Fabric OneLake from Finder.** Like OneDrive or Google Drive — but for your data lake. Multiple accounts in multiple tenants, side by side, with a single Homebrew install.

> Pre-release, under active development.

📖 **Documentation, screenshots and walkthroughs: [ofem.debruyn.dev](https://ofem.debruyn.dev)**

## Install

```bash
brew install --cask sdebruyn/ofem/ofem
```

Requires macOS 14 Sonoma or later on Apple Silicon. No system-level changes, no extra dependencies, no admin password.

[Full install guide →](https://ofem.debruyn.dev/install/)

## What you get

- Multiple OneLake accounts across multiple Microsoft Entra tenants visible side by side in Finder.
- Online-only placeholders by default — files stream on demand, cached locally for instant reopen.
- Drag, drop, double-click, save in any app. Spotlight indexing and Quick Look work out of the box.
- One Finder sidebar entry per account (`OneLake — work`, `OneLake — client-a`, …) so workspaces from different tenants never collide. macOS places each one under `~/Library/CloudStorage/OneLake-<alias>/`, the same way OneDrive and Google Drive do.

## What's not here

Things managed by Microsoft Fabric and not exposed through the file system: creating or renaming workspaces, managing permissions, changing the schema of Delta tables. Those still go through the Fabric portal.

## Strict tenant? Bring your own App Registration

OFEM ships with a multi-tenant Entra App Registration that works for most users. Tenants that block third-party multi-tenant apps can supply their own client ID in *Add Account → Advanced* — see [Custom App Registration](https://ofem.debruyn.dev/custom-app-registration/) for the exact registration settings.

## Support

[Issues](https://github.com/sdebruyn/onelake-explorer-macos/issues) · [Discussions](https://github.com/sdebruyn/onelake-explorer-macos/discussions) · [Security (private)](https://github.com/sdebruyn/onelake-explorer-macos/security/advisories/new)

## Architecture

The engine, auth, cache, and sync logic live in the **OfemKit** Swift Package, which runs
inside the File Provider Extension process. The host app communicates with the extension
via standard Apple XPC (`NSFileProviderService`).

- [Architecture overview](docs/design/overview.md) — process model, source layout, and design decisions

## Contributing

Open source under the [MIT License](LICENSE). See [CONTRIBUTING.md](CONTRIBUTING.md) for setup, and [ofem.debruyn.dev/design/overview/](https://ofem.debruyn.dev/design/overview/) for the architecture overview.

## Funding

[Sponsor OFEM](https://github.com/sponsors/sdebruyn) to help cover the Apple Developer Program membership and Azure costs.
