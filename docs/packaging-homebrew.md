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
5.  make cgo-build  -> apple/build/cgo/libofemcore.{a,h}
6.  make apple-gen  -> regenerate apple/OneLake.xcodeproj from project.yml
7.  Write apple/Local.xcconfig with DEVELOPMENT_TEAM=$APPLE_TEAM_ID
8.  xcodebuild archive -scheme OneLake -archivePath build/OneLake.xcarchive
9.  xcodebuild -exportArchive (method: developer-id) -> build/Export/OneLake.app
10. go build -o build/Export/OneLake.app/Contents/Resources/bin/ofem
11. create-dmg -> dist-app/OneLake-$VERSION.dmg
12. xcrun notarytool submit --wait --timeout 15m
13. xcrun stapler staple
14. Upload DMG to GitHub Release (softprops/action-gh-release)
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
  homepage "https://github.com/sdebruyn/onelake-explorer-macos"

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
- A **Developer ID Application** certificate, exported as a `.p12` and stored in GitHub Actions secrets (`DEVELOPER_ID_APPLICATION_P12_BASE64` + `DEVELOPER_ID_APPLICATION_P12_PASSWORD`).
- An **App Store Connect API key** for `notarytool` (preferred over app-specific passwords because it doesn't expire and is per-team scoped):
  - `NOTARY_KEY_ID` — the 10-character key identifier.
  - `NOTARY_ISSUER_ID` — the issuer UUID.
  - `NOTARY_API_KEY_P8` — the contents of the `.p8` private key.
- A **Provisioning profile** is not required for non-Mac-App-Store distribution; Developer ID signing is sufficient.

## Entitlements

`apple/OneLake.entitlements`:
- `com.apple.security.app-sandbox` = true.
- `com.apple.security.application-groups` = `[group.dev.debruyn.ofem]`.
- `com.apple.security.network.client` = true.
- `com.apple.security.files.user-selected.read-write` = true.
- `com.apple.security.keychain-access-groups` = `[$(AppIdentifierPrefix)group.dev.debruyn.ofem]`.

`apple/OneLakeFileProvider.entitlements` adds:
- `com.apple.developer.file-provider.testing-mode` = true (in dev builds only).
- `NSExtension` plist with `NSExtensionFileProviderSupportedItemActions` enumerated.

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
| `HOMEBREW_TAP_PAT` | Fine-grained GitHub PAT with **Contents: write** on `sdebruyn/homebrew-ofem`. The CLI formula push and cask update both use this token. |

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
It must be created manually once before the first release:

```bash
gh repo create sdebruyn/homebrew-ofem --public --description "Homebrew tap for OFEM"
# Add the dummy 0.0.0 cask to bootstrap the tap validation pipeline:
# copy homebrew/ofem.rb from this repo into homebrew-ofem/Casks/ofem.rb.
```

The release workflow's `release-cli-and-cask` job renders the cask template
and pushes the updated `Casks/ofem.rb` to `sdebruyn/homebrew-ofem` on every
release.

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

For pre-release dogfooding, developers can run `./scripts/build-local.sh` which:
1. Builds the Go binary (no codesigning).
2. Builds the Xcode project with the locally available developer certificate (or ad-hoc signing).
3. Skips notarization.
4. Produces `build/OneLake.app` ready to drag into `/Applications`.

This won't pass Gatekeeper on other machines without manual override (`xattr -d com.apple.quarantine`), which is fine for personal dogfooding.
