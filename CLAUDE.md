# CLAUDE.md

Project context for Claude Code sessions on this repo.

## What this project is

OFEM — OneLake Explorer for macOS. Native Finder integration with Microsoft Fabric OneLake, distributed via Homebrew cask. Menu bar app + File Provider Extension, backed by the OfemKit engine package. MIT licensed, open source.

## Hard constraints (do not violate)

- No system-level changes for the end user (no kext, no Reduced Security, no Recovery Mode).
- Authentication: interactive browser only. No service principals, no client secrets.
- Multi-tenant + multi-account simultaneously, identified by user-chosen short aliases.
- Install via Homebrew cask.
- End users install only the signed `.app` — no extra runtime to provision.
- macOS 14 Sonoma or later, arm64-only.
- Project communication: code/docs/comments/commits in English.

## Key decisions (where to look)

- All product and tech decisions are in `README.md` and `docs/*`.
- Mount mechanism: File Provider Extension, never FUSE-T. See `docs/macos-mount.md` for the rejected alternatives.
- Auth: `docs/auth.md` — MSAL for Apple Platforms, own multi-tenant Entra App Registration, Keychain-backed cache, per-account `MSALPublicClientApplication`.
- OneLake API: `docs/onelake-api.md` — ADLS Gen2 DFS endpoint for I/O (audience `https://storage.azure.com/`), Fabric REST for discovery (Power BI Service audience `https://analysis.windows.net/powerbi/api`). Two distinct audiences — a single one returns 401 on Fabric REST. See `docs/auth.md`.
- Tech stack: `docs/tech-stack.md` — OfemKit is the engine; host app and FPE are thin Swift targets.
- Telemetry: `docs/telemetry.md` — opt-out, App Insights free tier, tenant IDs collected but never UPN / workspace / file names.
- Packaging: `docs/packaging-homebrew.md` — xcodebuild + notarytool, DMG via Homebrew cask.
- Prerequisites: `docs/prerequisites.md` — splits local dev vs publishing/signing.

## Style and conventions

- Conventional Commits enforced by commitlint in CI.
- CalVer versioning: `YYYY.MM.PATCH` (e.g. `2026.05.1`).
- Trunk-based development; `main` protected; PR + passing CI required.
- TOML for config files; SQLite for the metadata cache.
- Bundle ID and config namespace: `dev.debruyn.ofem`. Display name in Finder: `OneLake`.
- Mount path on disk: `~/Library/CloudStorage/OneLake-<alias>/<workspace>/<folder>?/<item>/...` (ASCII hyphen, matching OneDrive / Google Drive). macOS picks the parent — File Provider does not let us anchor under `~/OneLake/`; see `docs/file-provider-domain-nesting.md`.
- Finder sidebar shows each domain by the label macOS composes from `<CFBundleDisplayName>` and `NSFileProviderDomain.displayName` (empirically `OneLake — <alias>` with em-dash, OneDrive-style). The em-dash is **display only**; on disk it stays ASCII.
- Logical identifier hierarchy (inside the domain): `/<workspaceGUID>/<itemGUID>/<path>...`.

## Where things live

- `Packages/OfemKit/` — local Swift Package: auth (MSAL), OneLake DFS + Fabric REST clients, SQLite metadata cache, sync engine, telemetry. Linked into both the host app and the FPE.
- `OneLake/` — host app (Swift). Menu bar UI, account management, domain registration, XPC client to the FPE.
- `OneLakeFileProvider/` — File Provider Extension (Swift). `NSFileProviderReplicatedExtension`, `OfemFPEEnumerator`, `FPEEngineHost`. Owns all engine logic.
- `Shared/` — XPC protocol + types shared by both targets: `OfemClientControlProtocol`, `XPCAccountInfo`, `XPCEngineStatus`.
- `docs/` — all design docs.
- `homebrew/` — cask template (also lives in separate `homebrew-ofem` tap repo for release publishing).
- `.github/` — workflows, issue templates, FUNDING.yml.

## Useful commands

```bash
# Build signed macOS app (THE build to run after pulling)
make app

# Build only the macOS app (Debug, signed, local use)
make build

# Compile unsigned (CI gate — no Developer ID needed)
make build-ci

# Run Swift unit tests (host-less, unsigned)
make test

# Run OfemKit tests
cd Packages/OfemKit && swift test

# Regenerate Xcode project from project.yml
make gen
```

## Things to avoid

- Don't suggest FUSE-T, macFUSE, or any kernel-extension-based approach.
- Don't over-engineer protective UX layers. The project prefers less intrusive defaults — silent retry over notifications, last-write-wins over conflict-copy, no client-side write guards when the server already enforces.
- Don't add features beyond what the current scope calls for. Open a discussion if scope is unclear.
- Don't suggest making it cross-platform (Windows / Linux). It's macOS-only.
- Don't suggest service-principal auth or client-secret flows.

## When in doubt

- Read the doc in `docs/` first. They are intentionally detailed.
- If a decision needs to be made and it's not documented, ask in an issue or discussion before guessing.
- If you create a new design doc, link it from README.md.
