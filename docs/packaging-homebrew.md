# Packaging & distribution

OFEM ships as a signed and notarized Homebrew cask of the macOS `.app`.

See also: [Release runbook](release-runbook.md) for the step-by-step process Sam follows when cutting a release.

## Output artifact

A single signed and notarized DMG containing `OneLake.app`. The `.app` bundles:
- The Swift host app (`OneLake`).
- The Swift File Provider Extension (`OneLakeFileProvider.appex`).
- The Go CLI binary (`ofem`), embedded at `OneLake.app/Contents/Resources/bin/ofem`.
- The Go core library is statically linked into the Swift binaries; not shipped separately.

## Build pipeline

The full pipeline is implemented in `.github/workflows/release.yml`.
It splits into two jobs to separate macOS-only work from the Go/GoReleaser work.

```
Job A: build-app (macos-15 runner)
───────────────────────────────────────────────────────────────────────────────
1.  checkout + setup-go
2.  brew install xcodegen create-dmg
3.  Import Developer ID Application cert from APPLE_CERT_P12 into a
    temporary keychain (deleted after the job).
4.  Write App Store Connect API key from APPLE_API_KEY_JSON to a tmp .p8 file.
5.  make apple-gen  -> regenerate apple/OneLake.xcodeproj from project.yml
6.  Write apple/Local.xcconfig with DEVELOPMENT_TEAM=$APPLE_TEAM_ID
7.  xcodebuild archive -scheme OneLake -archivePath build/OneLake.xcarchive
8.  xcodebuild -exportArchive (method: developer-id) -> build/Export/OneLake.app
9.  go build -o build/Export/OneLake.app/Contents/Resources/bin/ofem
10. create-dmg -> dist-app/OneLake-$VERSION.dmg
11. xcrun notarytool submit --wait --timeout 15m
12. xcrun stapler staple
13. Upload DMG to GitHub Release (softprops/action-gh-release)
15. Upload DMG as workflow artifact for Job B

Job B: release-cli-and-cask (ubuntu-latest, needs: build-app)
───────────────────────────────────────────────────────────────────────────────
1.  checkout + setup-go
2.  Download DMG artifact from Job A -> dist-app/
3.  goreleaser release --clean
      - compiles ofem CLI tarball (CGO_ENABLED=0, darwin/arm64)
      - attaches checksums.txt and dist-app/OneLake-*.dmg to GitHub Release
      - pushes CLI formula to sdebruyn/homebrew-ofem Formula/ofem.rb
4.  Render cask template (sed on homebrew/Casks/ofem.rb.tmpl)
5.  Clone homebrew-ofem, commit + push updated Casks/ofem.rb
```

For manual use (local signing without CI), see `scripts/sign-and-notarize.sh`.

## Homebrew cask

We maintain a separate tap repository `homebrew-ofem`. The cask:

```ruby
cask "ofem" do
  arch arm: "arm64"
  version "2026.05.1"
  sha256 "abc123..."

  url "https://github.com/sdebruyn/onelake-explorer-macos/releases/download/v#{version}/OneLake-#{version}.dmg"
  name "OneLake Explorer for macOS"
  desc "Browse Microsoft Fabric OneLake from Finder"
  homepage "https://ofem.debruyn.dev"

  depends_on macos: ">= :sonoma"
  depends_on arch: :arm64

  app "OneLake.app"
  binary "#{appdir}/OneLake.app/Contents/Resources/bin/ofem"

  postflight do
    # Trigger launchd registration on first install
    system_command "#{appdir}/OneLake.app/Contents/Resources/bin/ofem",
                   args: ["daemon", "install"],
                   sudo: false
  end

  uninstall launchctl: "dev.debruyn.ofem.daemon",
            quit:      "dev.debruyn.ofem.app",
            delete:    [
              "~/Library/LaunchAgents/dev.debruyn.ofem.daemon.plist",
            ]

  zap trash: [
    "~/Library/Group Containers/group.dev.debruyn.ofem",
    "~/Library/Preferences/dev.debruyn.ofem.plist",
    "~/Library/CloudStorage/OneLake-*",
  ]
end
```

`zap` runs on `brew uninstall --zap ofem` and wipes user data; default `brew uninstall` preserves it.

### Validating the tap

A dummy `0.0.0` cask lives at [`sdebruyn/homebrew-ofem`](https://github.com/sdebruyn/homebrew-ofem)
(mirrored in this repo at `homebrew/ofem.rb`). It points at a release asset
that does not exist yet, so `brew install --cask` will 404 — but the rest of
the tap pipeline (`brew tap` → `brew info` → `brew audit` → `brew style`) is
validated end-to-end against the real GitHub-hosted tap.

To re-run the validation after a cask edit:

```bash
brew tap sdebruyn/ofem
brew tap | grep sdebruyn/ofem                            # confirms tap is registered
brew info --cask sdebruyn/ofem/ofem                      # version 0.0.0, arm64, macOS >= 14
brew audit --cask --strict --online sdebruyn/ofem/ofem   # one expected curl 404 on the DMG, nothing else
brew style --fix $(brew --repository sdebruyn/ofem)/Casks/ofem.rb
brew untap sdebruyn/ofem
```

Expected audit output:

```
* exception while auditing ofem: Download failed on Cask 'ofem' with message:
  Download failed: https://github.com/.../v0.0.0/OneLake-0.0.0.dmg
  curl: (56) The requested URL returned error: 404
```

The 404 disappears the moment the first real CalVer tag (`v2026.MM.PATCH`)
is pushed and the release workflow uploads the signed DMG. Until then, the
livecheck stanza in the cask is set to `skip` to keep `brew audit` honest.

## Versioning

CalVer: `YYYY.MM.PATCH` (e.g. `2026.05.1`). A git tag `v2026.05.1` triggers the release pipeline.

## Signing identity and notarization

We need:
- Apple Developer Program enrollment (~$99/year). Required to obtain code signing certificates.
- A **Developer ID Application** certificate, exported as a `.p12` and stored in GitHub Actions secrets (`APPLE_CERT_P12` + `APPLE_CERT_PASSWORD`).
- An **App Store Connect API key** for `notarytool` (preferred over app-specific passwords because it doesn't expire and is per-team scoped):
  - `APPLE_API_KEY_JSON` — the full API key JSON (`key_id`, `issuer_id`, `key`).
  - `APPLE_API_KEY_ID` — the 10-character key identifier (also inside `APPLE_API_KEY_JSON`).
  - `APPLE_API_ISSUER_ID` — the issuer UUID (also inside `APPLE_API_KEY_JSON`).
- A **Provisioning profile** is not required for non-Mac-App-Store distribution; Developer ID signing is sufficient.

## Entitlements

`apple/OneLake.entitlements`:
- `com.apple.security.app-sandbox` = true.
- `com.apple.security.application-groups` = `[group.dev.debruyn.ofem]`.
- `com.apple.security.network.client` = true.
- `com.apple.security.files.user-selected.read-write` = true.
- `com.apple.security.keychain-access-groups` = `[$(AppIdentifierPrefix)group.dev.debruyn.ofem]`.

`apple/OneLakeFileProvider.entitlements` adds:
- `NSExtension` plist with `NSExtensionFileProviderSupportedItemActions` enumerated.

Note: `com.apple.developer.file-provider.testing-mode` is **not** used. The paid
Developer ID team provides a provisioning profile that grants the required File
Provider entitlements directly. Contributors using a free Personal Team can build
the host app only (`make apple-build-host`); the extension requires a paid team.

## GitHub Secrets

The following secrets must be configured in the repository under
**Settings > Secrets and variables > Actions** before the first release tag is
pushed. None of them are committed to the repository.

| Secret | Description |
|---|---|
| `APPLE_CERT_P12` | Base64-encoded Developer ID Application `.p12` certificate. Export from Keychain Access (right-click the certificate > Export > Personal Information Exchange `.p12`), then encode: `base64 -i cert.p12 \| pbcopy`. |
| `APPLE_CERT_PASSWORD` | Password chosen when exporting the `.p12`. |
| `APPLE_TEAM_ID` | Apple Developer Team ID. For Debruyn Consultancy this is `6D79CUWZ4J`. Find yours at [developer.apple.com/account](https://developer.apple.com/account) under Membership. |
| `APPLE_API_KEY_JSON` | App Store Connect API key as a JSON object with keys `key_id`, `issuer_id`, and `key` (PEM content). Generate at [appstoreconnect.apple.com/access/integrations/api](https://appstoreconnect.apple.com/access/integrations/api). Store the full JSON as the secret value. |
| `APPLE_API_KEY_ID` | The 10-character key identifier, also present inside `APPLE_API_KEY_JSON`. Stored separately so it can be used in environment-variable interpolation without parsing JSON. |
| `APPLE_API_ISSUER_ID` | The issuer UUID, also present inside `APPLE_API_KEY_JSON`. |
| `HOMEBREW_TAP_GH_TOKEN` | Fine-grained GitHub PAT with **Contents: write** on `sdebruyn/homebrew-ofem`. The CLI formula push and cask update both use this token. |

### How to generate the Developer ID `.p12`

1. Open **Keychain Access** > My Certificates.
2. Locate the **Developer ID Application** certificate (issued by Apple).
3. Right-click > **Export...** > choose Personal Information Exchange (`.p12`).
4. Set a strong password; note it for `APPLE_CERT_PASSWORD`.
5. `base64 -i ~/Downloads/cert.p12 | pbcopy` — paste as `APPLE_CERT_P12`.

### How to generate an App Store Connect API key

1. Sign in at [appstoreconnect.apple.com](https://appstoreconnect.apple.com).
2. Go to **Users and Access** > **Integrations** > **App Store Connect API**.
3. Click **+**, name it `ofem-notarization`, grant **Developer** access.
4. Download the `.p8` file (available only once).
5. Note the **Key ID** (10 chars) and the **Issuer ID** (UUID).
6. Build the JSON secret:
   ```bash
   jq -n \
     --arg key_id "XXXXXXXXXX" \
     --arg issuer_id "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" \
     --rawfile key ~/Downloads/AuthKey_XXXXXXXXXX.p8 \
     '{"key_id":$key_id,"issuer_id":$issuer_id,"key":$key}' | pbcopy
   ```
7. Paste as `APPLE_API_KEY_JSON`. Also store the Key ID as `APPLE_API_KEY_ID` and the Issuer ID as `APPLE_API_ISSUER_ID`.

### The `homebrew-ofem` tap repo

`homebrew-ofem` is a **separate GitHub repository** (`sdebruyn/homebrew-ofem`).
The tap already exists and was bootstrapped with a dummy `0.0.0` cask in PR #35.
No manual setup is required — the release workflow's `release-cli-and-cask` job
renders the cask template and pushes the updated `Casks/ofem.rb` to
`sdebruyn/homebrew-ofem` automatically on every release tag.

## GoReleaser config (`.goreleaser.yaml`)

GoReleaser handles the Go CLI binary part and attaches it (plus checksums) to
the GitHub Release. It does **not** manage the Homebrew cask — the cask is
rendered from `homebrew/Casks/ofem.rb.tmpl` and committed to the tap by the
`Update Homebrew cask` workflow step after the DMG SHA-256 is known.

```yaml
project_name: ofem
before:
  hooks:
    - go mod tidy
builds:
  - id: ofem
    main: ./cmd/ofem
    binary: ofem
    env:
      - CGO_ENABLED=0
    goos: [darwin]
    goarch: [arm64]
    flags:
      - -trimpath
    ldflags:
      - -s -w
      - -X github.com/sdebruyn/onelake-explorer-macos/internal/buildinfo.Version={{ .Version }}
      - -X github.com/sdebruyn/onelake-explorer-macos/internal/buildinfo.Commit={{ .Commit }}
      - -X github.com/sdebruyn/onelake-explorer-macos/internal/buildinfo.Date={{ .Date }}
release:
  github:
    owner: sdebruyn
    name: onelake-explorer-macos
  prerelease: auto
  extra_files:
    - glob: ./dist-app/OneLake-*.dmg
```

## Pre-release / beta channel

No formal beta tap. Pre-release versions are tagged like `v2026.05.0-rc.1` and GoReleaser marks the GitHub Release as "prerelease". Users who want to try them download the DMG directly from the Releases page. Stable installs via Homebrew see only stable tags.

## Update mechanism

`brew upgrade --cask ofem`. No in-app update check; no Sparkle. The daemon logs the running version on startup so users can compare against `brew info ofem` output.

## Uninstall

```bash
brew uninstall --cask ofem          # removes app, keeps data
brew uninstall --cask --zap ofem    # removes app + all user data
```

The `uninstall launchctl:` directive in the cask stops the daemon. The `app` directive removes `OneLake.app`. `zap` removes everything else.

## Local development distribution

For pre-release dogfooding, build the app manually:

```bash
# Generate the Xcode project from project.yml
make apple-gen

# Build the host app (ad-hoc or with your local Developer ID cert)
make apple-build-host
```

The resulting app lands in `build/Export/OneLake.app`. Drag it into
`/Applications`. Without notarization it will not pass Gatekeeper on other
machines; override locally with `xattr -d com.apple.quarantine OneLake.app`.

### Manual sign and notarize

`scripts/sign-and-notarize.sh` is a local developer convenience that signs an
already-built `OneLake.app`, wraps it in a DMG, and submits it to the Apple
notarization service. It expects the following environment variables (none of
these are GitHub Secrets — they are local-only, never committed):

| Variable | Description |
|---|---|
| `APPLE_TEAM_ID` | Apple Developer Team ID (e.g. `6D79CUWZ4J`). |
| `APPLE_API_KEY_ID` | App Store Connect API key identifier (10 characters). |
| `APPLE_API_ISSUER_ID` | App Store Connect API issuer UUID. |
| `NOTARY_API_KEY_PATH` | Absolute path to the `.p8` private key file on your local machine. Download it once from App Store Connect (see "How to generate an App Store Connect API key" above). |
| `VERSION` | CalVer string used to name the DMG (e.g. `2026.05.1`). |

Optional: `OUTPUT_DIR` (default `./dist-app`) and `NOTARY_TIMEOUT` (default `15m`).

Example:
```bash
export APPLE_TEAM_ID=6D79CUWZ4J
export APPLE_API_KEY_ID=XXXXXXXXXX
export APPLE_API_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
export NOTARY_API_KEY_PATH=~/Downloads/AuthKey_XXXXXXXXXX.p8
export VERSION=2026.05.1
scripts/sign-and-notarize.sh build/Export/OneLake.app
```
