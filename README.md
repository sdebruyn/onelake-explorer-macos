<p align="center">
  <img src="assets/branding/ofem-lockup.svg" alt="OFEM — OneLake File Explorer for macOS" width="420" />
</p>

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
- Per-account folders under `~/OneLake/` so workspaces from different tenants never collide.

## What's not here

Things managed by Microsoft Fabric and not exposed through the file system: creating or renaming workspaces, managing permissions, changing the schema of Delta tables. Those still go through the Fabric portal.

## Support

[Issues](https://github.com/sdebruyn/onelake-explorer-macos/issues) · [Discussions](https://github.com/sdebruyn/onelake-explorer-macos/discussions) · [Security (private)](https://github.com/sdebruyn/onelake-explorer-macos/security/advisories/new)

## Contributing

Open source under the [MIT License](LICENSE). See [CONTRIBUTING.md](CONTRIBUTING.md) for setup, and [ofem.debruyn.dev/design/overview/](https://ofem.debruyn.dev/design/overview/) for the architecture overview.

## Funding

[Sponsor OFEM](https://github.com/sponsors/sdebruyn) to help cover the Apple Developer Program membership and Azure costs.
