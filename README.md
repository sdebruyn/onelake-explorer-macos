# OneLake File Explorer for macOS (OFEM)

Open-source, native macOS integration for Microsoft Fabric **OneLake**. Browse your workspaces, items, and files directly from Finder — the same way OneDrive and Google Drive integrate — without a Windows VM or Azure Storage Explorer workarounds.

> **Status**: research & planning complete. Implementation starts on `main` once initial scaffolding is in place. See [PLAN.md](PLAN.md) for the phased roadmap and [docs/prerequisites.md](docs/prerequisites.md) for what is needed to build and ship.

## What this is

Microsoft ships a [OneLake File Explorer](https://learn.microsoft.com/fabric/onelake/onelake-file-explorer) for Windows only. There is currently no native macOS option. OFEM fills that gap as an open-source project, with these explicit improvements over the Windows version:

- **Multi-account, multi-tenant** simultaneously visible side by side (Windows app supports one account at a time).
- **macOS-native UX** through a File Provider Extension — Finder sidebar, online-only placeholders, on-demand download, Spotlight integration.
- **No system-level changes required** from the user (no kernel extensions, no Recovery Mode tweaks, no Reduced Security toggles).
- **Single-command install** via Homebrew cask.

## Project name

- Product / display name in Finder and the macOS app: **OneLake**.
- Project / binary / config / bundle ID: **OFEM** / `ofem` / `dev.debruyn.ofem`.

## Hard constraints

- No system-level changes for the user.
- Authentication only via interactive browser or device code. Users only, never service principals.
- Multi-tenant + multi-account simultaneously, with user-chosen short aliases (`work`, `client-a`).
- Install via Homebrew cask.
- No external runtime dependency for end users (no Python, no .NET, no Node).
- macOS 14 Sonoma or later, Apple Silicon (arm64) only.

## Roadmap (high-level)

| Phase | Deliverable | Audience |
|---|---|---|
| **0** | Core Go library + debug CLI (`ofem debug ls`, `ofem debug cat`) | Internal validation only, not released |
| **1 — MVP** | Signed/notarized `OneLake.app` with File Provider Extension + setup CLI + Homebrew cask | First public release |
| **2** | SwiftUI account-management GUI inside the host app + menu bar status icon | Non-CLI users |
| **3** | Polish: Spotlight metadata, Quick Look extensions, sync UX refinements, performance tuning | Mass-market readiness |

The Go core library is shared across all phases. The Swift host app + File Provider Extension calls the Go core via cgo / C-ABI FFI.

Full plan with milestones in [PLAN.md](PLAN.md).

## Architecture overview

```
┌────────────────────────────────┐
│  OneLake.app (host, Swift)     │  ← user opens for account management
│  - Auth flow (browser)         │
│  - Account add/remove UI       │
│  - Menu bar status icon        │
└──────────┬─────────────────────┘
           │ XPC / App Group
┌──────────┴─────────────────────┐
│  OneLake FileProvider .appex   │  ← macOS-managed sandboxed extension
│  - Swift NSFileProviderItem    │
│  - Bridge to core lib          │
└──────────┬─────────────────────┘
           │ cgo / C-ABI
┌──────────┴─────────────────────┐
│  libofemcore (Go)               │  ← Auth + OneLake API + cache + sync
└──────────┬─────────────────────┘
           │ Unix domain socket
┌──────────┴─────────────────────┐
│  ofem CLI (Go)                  │  ← setup, account mgmt, debug
└────────────────────────────────┘
```

## Documentation

| Document | Topic |
|---|---|
| [docs/onelake-file-explorer-windows.md](docs/onelake-file-explorer-windows.md) | Reference: how Microsoft's Windows OneLake File Explorer works |
| [docs/onelake-api.md](docs/onelake-api.md) | OneLake DFS / ADLS Gen2 API + Fabric REST API: URIs, scopes, endpoints, parity differences |
| [docs/auth.md](docs/auth.md) | Microsoft Entra ID authentication design |
| [docs/macos-mount.md](docs/macos-mount.md) | Why File Provider Extension; alternatives considered and rejected |
| [docs/file-provider.md](docs/file-provider.md) | File Provider Extension architecture and Swift ↔ Go bridge |
| [docs/tech-stack.md](docs/tech-stack.md) | Language choice (Go) and library selections |
| [docs/packaging-homebrew.md](docs/packaging-homebrew.md) | Build, sign, notarize, distribute via Homebrew cask |
| [docs/telemetry.md](docs/telemetry.md) | Opt-out telemetry design, schema, App Insights backend |
| [docs/telemetry-hosting-research.md](docs/telemetry-hosting-research.md) | Research that led to the App Insights decision |
| [docs/prior-art.md](docs/prior-art.md) | What already exists, what doesn't |
| [PLAN.md](PLAN.md) | Phased implementation plan with milestones |

## Telemetry

OFEM collects opt-out anonymous usage events plus tenant IDs (never workspace, item, file names, or UPNs) via Azure Application Insights. Disable any time with `OFEM_TELEMETRY=0` or `ofem config set telemetry off`. See [docs/telemetry.md](docs/telemetry.md) for the full schema and disclosure.

## License

MIT — see [LICENSE](LICENSE).

## Contributing

This is an open-source project. All code, documentation, comments, commit messages, and PR descriptions are in English so anyone can contribute. See [CONTRIBUTING.md](CONTRIBUTING.md) for setup, workflow, and code conventions.

## Security

Report security issues via GitHub Private Security Advisories — see [SECURITY.md](SECURITY.md).

## Funding

If OFEM helps you, consider [sponsoring the project](https://github.com/sponsors/sdebruyn). Sponsorships help cover the Apple Developer Program membership and Azure costs.
