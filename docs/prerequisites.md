# Prerequisites

This document distinguishes between:

- **Compiling and passing CI checks** — what you need to clone the repo, edit code, verify it compiles (`make build-ci`), and run the tests (`make test`). No Apple account, free or paid.
- **Running the signed app locally (dogfooding)** — additionally needed to produce a *runnable* `.app` with the File Provider Extension you can install on your own Mac (`make build`). Requires a paid Apple Developer Program membership — see below.
- **Publishing & signing** — what additionally is needed to produce the official signed/notarized `.app` and ship it via Homebrew cask.

If you only want to contribute code, the first bullet is all you need: `make build-ci` and `make test` both work on a fresh checkout with zero Apple credentials. The publishing requirements are only relevant to the maintainer and to release CI.

---

## Local development

| Tool | Minimum version | Recommended | How to install |
|---|---|---|---|
| macOS | 14 Sonoma (arm64) | latest stable | – |
| Xcode | 15 | 26.x | App Store |
| git | 2.40 | latest | comes with Xcode CLT |
| Homebrew | any recent | latest | https://brew.sh |
| `gh` CLI | 2.40 | latest | `brew install gh` |
| `commitlint` | 18 | latest | `brew install commitlint` (or `npm i -g @commitlint/cli @commitlint/config-conventional`) |
| `make` (optional) | any | any | comes with Xcode CLT |

Plus a configured **Microsoft Entra tenant** with at least one workspace you can read, so you can sign in from the OneLake menu bar app during development and have something to browse.

### Optional but useful

- `direnv` — for project-local env vars (`brew install direnv`).
- `delta` — nicer diffs in git (`brew install git-delta`).
- `entr` — auto-run tests on file save (`brew install entr`).

### Compiling without an Apple account

`make build-ci` builds the app + extension unsigned (no signing identity, no
provisioning round trip) — exactly what CI runs on every PR. That's enough
to verify your change compiles and to run the unit tests; no Apple account,
free or paid, is required.

### Running the `.app` and File Provider Extension locally requires

- Xcode 15+ (you already need it).
- A **paid Apple Developer Program membership** ($99/yr). The File Provider
  entitlement family is a restricted capability that a free Personal Team
  cannot sign — see [File Provider Extension — architecture § Signing for
  local vs release](file-provider.md#signing-for-local-vs-release) for why.
  Ad-hoc signing with a free Apple ID is not sufficient to produce a runnable
  `.app` with the extension embedded.

#### Xcode project generation

The Xcode project is generated from `project.yml` by XcodeGen, so the
spec stays human-readable and merge-friendly. The generated `.xcodeproj`
is gitignored.

| Tool | Minimum version | Recommended | How to install |
|---|---|---|---|
| `xcodegen` | 2.40 | latest | `brew install xcodegen` |

Then:

```bash
make bootstrap   # writes Local.xcconfig (gitignored)
make gen         # regenerates OneLake.xcodeproj
make build-ci    # unsigned compile-only build — no Apple account needed
# or, with a paid Apple Developer Program team ID set in Local.xcconfig:
make build       # Debug build via xcodebuild, signed and runnable
```

#### Swift Package tests

The OfemKit engine modules have their own test suite:

```bash
cd Packages/OfemKit
swift test
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
| Microsoft Entra App Registration | free | ✅ done — client ID `939b4a06-cc18-49eb-9674-a1fc041489f6` ("OneLake Explorer for macOS", multi-tenant, public client). See [docs/auth.md](auth.md) for the underlying settings. |
| Azure Application Insights resource (Free tier) | free up to 5 GB/month | https://portal.azure.com → "Application Insights" → "+" → choose Pay-As-You-Go subscription, Free pricing tier |
| GitHub repository | free | already exists once initial scaffolding is pushed |
| GitHub Actions secrets (set on the repo) | free | see below |

### Tools

| Tool | How to install |
|---|---|
| `create-dmg` | `brew install create-dmg` |
| `xcrun notarytool` | comes with Xcode |
| `xcrun stapler` | comes with Xcode |

### GitHub Actions secrets to configure

The authoritative secret list lives in the header comment of `.github/workflows/release.yml`.
The table below mirrors it for quick reference.

| Secret | Source | Purpose |
|---|---|---|
| `APPLE_CERT_P12` | `base64 -i cert.p12 \| pbcopy` — export Developer ID Application cert from Keychain Access | Base64-encoded `.p12` certificate for code signing |
| `APPLE_CERT_PASSWORD` | the password you set when exporting the `.p12` | Decrypts `APPLE_CERT_P12` in CI |
| `APPLE_TEAM_ID` | [developer.apple.com/account](https://developer.apple.com/account) → Membership | Apple Developer Team ID (10 chars) |
| `APPLE_API_KEY_JSON` | JSON with `key_id`, `issuer_id`, and `key` fields — see `docs/packaging-homebrew.md` | App Store Connect API key for `notarytool` |
| `APPLE_API_KEY_ID` | 10-character key identifier (also inside `APPLE_API_KEY_JSON`) | `notarytool --key-id` |
| `APPLE_API_ISSUER_ID` | UUID (also inside `APPLE_API_KEY_JSON`) | `notarytool --issuer` |
| `APPLE_PROVISION_PROFILE_APP` | Base64-encoded Developer ID provisioning profile for `dev.debruyn.ofem` — download from [developer.apple.com/account/resources/profiles](https://developer.apple.com/account/resources/profiles), then `base64 -i profile.provisionprofile \| pbcopy` | Host app provisioning profile; required for manual signing in `xcodebuild archive` |
| `APPLE_PROVISION_PROFILE_FP` | Base64-encoded Developer ID provisioning profile for `dev.debruyn.ofem.fileprovider` — same steps as above | File Provider Extension provisioning profile; required for manual signing |
| `HOMEBREW_TAP_GH_TOKEN` | fine-grained PAT with **Contents: write** on `sdebruyn/homebrew-ofem` | The release workflow pushes the rendered cask to the tap |

> **Note:** Provisioning profiles are required for Developer ID distribution even outside the Mac App Store. Each profile maps a bundle ID to the signing certificate. Create them at [developer.apple.com/account/resources/profiles](https://developer.apple.com/account/resources/profiles) → "+" → "Developer ID" → "macOS App" (select the app ID) or "Mac App Extension" (for the FPE).

For detailed instructions on generating the `.p12` and App Store Connect API key, see `docs/packaging-homebrew.md`.

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

## Verify your local environment

```bash
./scripts/check-prereqs.sh
```

Runs through the toolchain above and reports what is missing, with the right install command for each.
