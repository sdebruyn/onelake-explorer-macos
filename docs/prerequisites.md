# Prerequisites

This document distinguishes between:

- **Local development** — what you need to clone the repo, build, run tests, and dogfood OFEM on your own machine (no signing, no notarization, no release).
- **Publishing & signing** — what additionally is needed to produce the official signed/notarized `.app` and ship it via Homebrew cask.

If you only want to contribute code, you only need the **Local development** section. The publishing requirements are only relevant to the maintainer and to release CI.

---

## Local development

| Tool | Minimum version | Recommended | How to install |
|---|---|---|---|
| macOS | 14 Sonoma (arm64) | latest stable | – |
| Go | 1.22 | 1.26.x | `brew install go` |
| Xcode | 15 | 26.x | App Store |
| git | 2.40 | latest | comes with Xcode CLT |
| Homebrew | any recent | latest | https://brew.sh |
| `gh` CLI | 2.40 | latest | `brew install gh` |
| `golangci-lint` | 1.55 | latest | `brew install golangci-lint` |
| `commitlint` | 18 | latest | `brew install commitlint` (or `npm i -g @commitlint/cli @commitlint/config-conventional`) |
| `make` (optional) | any | any | comes with Xcode CLT |

Plus a configured **Microsoft Entra tenant** with at least one workspace you can read, so you can sign in with `ofem login` during development and have something to browse.

### Optional but useful

- `direnv` — for project-local env vars (`brew install direnv`).
- `delta` — nicer diffs in git (`brew install git-delta`).
- `entr` — auto-run tests on file save (`brew install entr`).
- `dlv` — Go debugger (`brew install delve`).

### CLI-only work does NOT require

- Xcode (technically — but you have it anyway for the standard Mac dev environment).
- Apple Developer Program membership.
- Any signing certificates.

`go build ./cmd/ofem` produces an unsigned binary you can run locally.

### Working on the `.app` and File Provider Extension also requires

- Xcode 15+ (you already need it).
- A free Apple ID and **ad-hoc signing** are enough to install the `.app` on your own Mac. Other people cannot install your build without disabling Gatekeeper.

#### Phase 1 tooling

The Xcode project is generated from `apple/project.yml` by XcodeGen, so the
spec stays human-readable and merge-friendly. The generated `.xcodeproj`
is gitignored.

| Tool | Minimum version | Recommended | How to install |
|---|---|---|---|
| `xcodegen` | 2.40 | latest | `brew install xcodegen` |

Then:

```bash
make apple-bootstrap   # writes apple/Local.xcconfig (gitignored); edit it
make apple-gen         # regenerates apple/OneLake.xcodeproj
make apple-build       # Debug build via xcodebuild
```

---

## Publishing & signing (maintainer / release CI only)

| Resource | Cost | How to get |
|---|---|---|
| Apple Developer Program enrollment | $99/year | https://developer.apple.com/programs/ |
| Developer ID Application certificate | included in Developer Program | Xcode → Settings → Accounts → Manage Certificates → "+" → Developer ID Application |
| App Store Connect API key (for notarytool) | included in Developer Program | https://appstoreconnect.apple.com/access/integrations/api → "+" → "Developer" or "Admin" role |
| App Group identifier `group.dev.debruyn.ofem` | included | https://developer.apple.com/account/resources/identifiers → "+" → App Groups |
| File Provider entitlement | included | configured per-extension in the `.entitlements` file |
| Microsoft Entra App Registration | free | ✅ done — client ID `939b4a06-cc18-49eb-9674-a1fc041489f6` ("OneLake File Explorer for macOS", multi-tenant, public client). See [docs/auth.md](auth.md) for the underlying settings. |
| Azure Application Insights resource (Free tier) | free up to 5 GB/month | https://portal.azure.com → "Application Insights" → "+" → choose Pay-As-You-Go subscription, Free pricing tier |
| GitHub repository | free | already exists once initial scaffolding is pushed |
| GitHub Actions secrets (set on the repo) | free | see below |

### Tools

| Tool | How to install |
|---|---|
| `goreleaser` | `brew install goreleaser` |
| `create-dmg` | `brew install create-dmg` |
| `xcrun notarytool` | comes with Xcode |
| `xcrun stapler` | comes with Xcode |

### GitHub Actions secrets to configure

| Secret | Source | Purpose |
|---|---|---|
| `DEVELOPER_ID_APPLICATION_P12_BASE64` | `base64 -i your-cert.p12` | Code-signing certificate |
| `DEVELOPER_ID_APPLICATION_P12_PASSWORD` | the password you set when exporting | Decrypts the .p12 in CI |
| `KEYCHAIN_PASSWORD` | random string | Temporary CI keychain password |
| `NOTARY_KEY_ID` | App Store Connect API key id (10 chars) | notarytool auth |
| `NOTARY_ISSUER_ID` | App Store Connect issuer id (UUID) | notarytool auth |
| `NOTARY_API_KEY_P8` | contents of the `.p8` file from App Store Connect | notarytool auth |
| `OFEM_APPINSIGHTS_CONNSTRING` | App Insights resource → Properties → Connection String | Embedded in release binary |
| `HOMEBREW_TAP_GH_TOKEN` | a fine-grained PAT with `contents: write` on `homebrew-ofem` | GoReleaser updates the cask |

### Domain ownership

The bundle identifier `dev.debruyn.ofem` implies ownership of `debruyn.dev`, which the maintainer owns. Not strictly required for code signing but expected by Apple's reverse-DNS convention.

### Initial bootstrap order

The first time the release pipeline runs end-to-end, this is the order:

1. Enroll in Apple Developer Program.
2. Create Developer ID Application certificate in Xcode.
3. Create App Store Connect API key.
4. Create App Group `group.dev.debruyn.ofem` in Apple Developer portal.
5. Create Entra App Registration; copy client ID into source.
6. Create Application Insights resource in Azure; copy connection string into GH secret.
7. Create `homebrew-ofem` empty repo + add `HOMEBREW_TAP_GH_TOKEN` to OFEM repo secrets.
8. Tag `v2026.05.0-rc.1`; let CI run; iterate on signing issues.
9. Tag `v2026.05.1` for the first stable release.

---

## Environment check for THIS machine (as of writing)

Run this script to verify your local-dev environment is ready:

```bash
./scripts/check-prereqs.sh
```

A reference snapshot from the maintainer's machine at the time of writing:

| Tool | Status |
|---|---|
| Go 1.26.3 darwin/arm64 | ✅ |
| Xcode 26.5 | ✅ |
| git 2.50.1 | ✅ |
| Homebrew 5.1.13 | ✅ |
| gh 2.92.0 (authenticated as `sdebruyn`) | ✅ |
| macOS 26.3.1 arm64 | ✅ (well above min macOS 14) |
| Xcode Command Line Tools at `/Applications/Xcode.app/...` | ✅ |
| `golangci-lint` | ❌ install via `brew install golangci-lint` |
| `commitlint` | ❌ install via `brew install commitlint` |
| `goreleaser` (publish only) | ❌ install via `brew install goreleaser` (only needed when cutting releases) |
| `create-dmg` (publish only) | ❌ install via `brew install create-dmg` (only needed when cutting releases) |
| Developer ID Application certificate | ❌ not yet acquired; needed only when shipping the first signed build |
| Apple Developer Program membership | ❌ not yet enrolled; required only when shipping signed builds |
| Microsoft Entra App Registration | ✅ client ID `939b4a06-cc18-49eb-9674-a1fc041489f6` (multi-tenant, public client) |
| Azure Application Insights resource | ❌ not yet created |
