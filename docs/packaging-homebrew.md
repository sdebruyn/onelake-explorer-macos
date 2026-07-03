# Packaging & distribution

OFEM ships as a signed and notarized Homebrew cask of the macOS `.app`.

See also: [Release runbook](release-runbook.md) for the step-by-step release process.

## Output artifact

A single signed and notarized DMG containing `OneLake.app`. The `.app` bundles:
- The Swift host app (`OneLake`).
- The Swift File Provider Extension (`OneLakeFileProvider.appex`).

The File Provider Extension owns all engine logic; end users interact with OneLake through the menu bar app and Finder.

## Build pipeline

The full pipeline is implemented in `.github/workflows/release.yml` as a single macOS-only job. The canonical step-by-step sequence lives there; the summary below reflects the current hardened workflow:

```
build-app (macos-15 runner)
───────────────────────────────────────────────────────────────────────────────
1.  checkout
2.  brew install xcodegen create-dmg
3.  Import Developer ID Application cert from APPLE_CERT_P12 into a
    temporary keychain (deleted after the job).
4.  Write App Store Connect API key from APPLE_API_KEY_JSON to a tmp .p8 file.
5.  Write Local.xcconfig with DEVELOPMENT_TEAM=$APPLE_TEAM_ID.
6.  Guard against pre-release tags — exits 1 if GITHUB_REF_NAME contains a
    hyphen (e.g. -rc.1), preventing accidental stable-tap publishes.
7.  make gen  -> regenerate OneLake.xcodeproj from project.yml.
8.  swift test (OfemKit unit tests) + make test (host-app unit tests).
9.  xcodebuild archive -scheme OneLake -archivePath build/OneLake.xcarchive
    (host app + File Provider Extension).
10. xcodebuild -exportArchive (method: developer-id) -> build/Export/OneLake.app
11. codesign --verify --deep --strict build/Export/OneLake.app
12. xcrun notarytool submit --wait --timeout 45m  (notarize the .app)
13. xcrun stapler staple build/Export/OneLake.app
14. create-dmg -> dist-app/OneLake-$VERSION.dmg  (DMG wraps the stapled .app)
15. xcrun notarytool submit --wait --timeout 45m  (notarize the DMG)
16. xcrun stapler staple dist-app/OneLake-$VERSION.dmg
17. spctl --assess --type open ... OneLake.app    (Gatekeeper check, .app)
    spctl --assess --type install ... OneLake-$VERSION.dmg  (Gatekeeper, DMG)
18. Compute DMG SHA-256
19. Upload DMG to the GitHub Release (softprops/action-gh-release)
20. Render homebrew/Casks/ofem.rb.tmpl with the new version + SHA-256 and
    push it to sdebruyn/homebrew-ofem as Casks/ofem.rb.
```

## Homebrew cask

We maintain a separate tap repository `homebrew-ofem`. The cask:

```ruby
cask "ofem" do
  version "2026.05.1"
  sha256 "abc123..."

  url "https://github.com/sdebruyn/onelake-explorer-macos/releases/download/v#{version}/OneLake-#{version}.dmg"
  name "OneLake Explorer for macOS"
  desc "Browse Microsoft Fabric OneLake from Finder"
  homepage "https://ofem.debruyn.dev"

  depends_on macos: :sonoma
  depends_on arch: :arm64

  app "OneLake.app"

  uninstall quit: "dev.debruyn.ofem"

  zap trash: [
    "~/Library/Group Containers/6D79CUWZ4J.group.dev.debruyn.ofem",
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
the tap pipeline (`brew tap` -> `brew info` -> `brew audit` -> `brew style`) is
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
- **Two Developer ID provisioning profiles** — one for the host app (`dev.debruyn.ofem`) and one for the File Provider Extension (`dev.debruyn.ofem.fileprovider`). Provisioning profiles are required even for non-Mac-App-Store Developer ID distribution when the app uses entitlements that Apple must explicitly grant (App Sandbox, App Groups, File Provider). Create them at [developer.apple.com/account/resources/profiles](https://developer.apple.com/account/resources/profiles) → "+" → "Developer ID". Store the base64-encoded profiles as:
  - `APPLE_PROVISION_PROFILE_APP` — host app profile.
  - `APPLE_PROVISION_PROFILE_FP` — File Provider Extension profile.

## Entitlements

`OneLake/OneLake.entitlements`:
- `com.apple.security.app-sandbox` = true.
- `com.apple.security.application-groups` = `[$(TeamIdentifierPrefix)group.dev.debruyn.ofem]` (Xcode expands to `6D79CUWZ4J.group.dev.debruyn.ofem` at sign-time; team-prefixed so the same value is valid for both Developer ID and Mac App Store).
- `com.apple.security.network.client` = true.
- `com.apple.security.files.user-selected.read-write` = true.
- `com.apple.security.keychain-access-groups` = `[$(AppIdentifierPrefix)group.dev.debruyn.ofem]`.

`OneLakeFileProvider/OneLakeFileProvider.entitlements` carries the same sandbox and
App Group entitlements as the host app. The `NSExtension` principal class and
`NSExtensionFileProviderSupportedItemActions` are declared in
`OneLakeFileProvider/Info.plist`, not in the entitlements file.

Note: `com.apple.developer.file-provider.testing-mode` is **not** used. The paid
Developer ID provisioning profiles grant the required File Provider entitlements directly.

## GitHub Secrets

The following secrets must be configured in the repository under
**Settings > Secrets and variables > Actions** before the first release tag is
pushed. None of them are committed to the repository.

| Secret | Description |
|---|---|
| `APPLE_CERT_P12` | Base64-encoded Developer ID Application `.p12` certificate. Export from Keychain Access (right-click the certificate > Export > Personal Information Exchange `.p12`), then encode: `base64 -i cert.p12 \| pbcopy`. |
| `APPLE_CERT_PASSWORD` | Password chosen when exporting the `.p12`. |
| `APPLE_TEAM_ID` | Apple Developer Team ID. Find yours at [developer.apple.com/account](https://developer.apple.com/account) under Membership. |
| `APPLE_API_KEY_JSON` | App Store Connect API key as a JSON object with keys `key_id`, `issuer_id`, and `key` (PEM content). Generate at [appstoreconnect.apple.com/access/integrations/api](https://appstoreconnect.apple.com/access/integrations/api). Store the full JSON as the secret value. |
| `APPLE_API_KEY_ID` | The 10-character key identifier, also present inside `APPLE_API_KEY_JSON`. Stored separately so it can be used in environment-variable interpolation without parsing JSON. |
| `APPLE_API_ISSUER_ID` | The issuer UUID, also present inside `APPLE_API_KEY_JSON`. |
| `APPLE_PROVISION_PROFILE_APP` | Base64-encoded Developer ID provisioning profile for the host app (`dev.debruyn.ofem`). Download from [developer.apple.com/account/resources/profiles](https://developer.apple.com/account/resources/profiles), then encode: `base64 -i profile.provisionprofile \| pbcopy`. |
| `APPLE_PROVISION_PROFILE_FP` | Base64-encoded Developer ID provisioning profile for the File Provider Extension (`dev.debruyn.ofem.fileprovider`). Same steps as above. |
| `HOMEBREW_TAP_GH_TOKEN` | Fine-grained GitHub PAT with **Contents: write** on `sdebruyn/homebrew-ofem`. Used by the `Update Homebrew cask` workflow step. |

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
No manual setup is required — the release workflow's `Update Homebrew cask` step
renders the cask template and pushes the updated `Casks/ofem.rb` to
`sdebruyn/homebrew-ofem` automatically on every release tag.

## Pre-release / beta channel

No formal beta tap. Pre-release versions are tagged like `v2026.05.0-rc.1`. Users who want to try them download the DMG directly from the Releases page. Stable installs via Homebrew see only stable tags.

## Update mechanism

`brew upgrade --cask ofem`. No in-app update check; no Sparkle. The running version is visible in the About window (menu bar → OneLake → About OneLake); users can compare it against `brew info ofem` output.

## Uninstall

```bash
brew uninstall --cask ofem          # removes app, keeps data
brew uninstall --cask --zap ofem    # removes app + all user data
```

The `uninstall quit:` directive terminates the running OneLake app. The `app` directive removes `OneLake.app`. `zap` removes everything else.

## Local development distribution

For pre-release dogfooding, the fastest path is:

```bash
make install   # build + install Debug app into /Applications, then relaunch
```

Under the hood, that runs `make build`, quits the running host app and FPE
(polling for each to fully exit before touching the bundle, since
`fileproviderd` can fault the domain if the `.appex` disappears mid-shutdown),
copies the fresh `.app` into `/Applications` via a staged `.new` sibling (so a
failed copy never clobbers the existing install), unregisters the DerivedData
build path from LaunchServices (avoids a duplicate `dev.debruyn.ofem`
registration causing `providerNotFound`), and relaunches so the host
re-registers its File Provider domains against the new binary.

The manual steps `make install` automates:

```bash
# Generate the Xcode project from project.yml
make gen

# Build the host app + File Provider Extension with your Developer ID cert
make build
```

The resulting app lands in `build/Export/OneLake.app`. Drag it into
`/Applications`. Without notarization it will not pass Gatekeeper on other
machines; override locally with `xattr -d com.apple.quarantine OneLake.app`.

