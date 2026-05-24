# OneLake in Finder, on macOS

Browse your Microsoft Fabric **OneLake** data lake from Finder, the same way OneDrive or Google Drive integrate. Multiple accounts in multiple tenants, side by side, with a single Homebrew install.

## Why this exists

Microsoft ships a [OneLake File Explorer](https://learn.microsoft.com/fabric/onelake/onelake-file-explorer) for Windows only. There is no native macOS equivalent. This project fills that gap as an open-source `.app` distributed through Homebrew, with these explicit improvements:

- **Multi-account, multi-tenant** simultaneously visible side by side.
- **macOS-native UX** through a File Provider Extension — Finder sidebar, online-only placeholders, on-demand download, Spotlight integration.
- **No system-level changes** required from the user (no kernel extensions, no Recovery Mode tweaks).
- **Single-command install** via Homebrew.

## Quick links

- [Install](install.md)
- [Sign in](sign-in.md)
- [Use in Finder](use.md)
- [Privacy & telemetry](privacy.md)
- [Architecture overview](design/overview.md) — how it works under the hood
- [Contribute](design/contributing.md)

## Requirements

- macOS 14 Sonoma or later
- Apple Silicon (arm64)
- A Microsoft Entra account with access to a Fabric tenant

## License

MIT — see [LICENSE](https://github.com/sdebruyn/onelake-explorer-macos/blob/main/LICENSE).
