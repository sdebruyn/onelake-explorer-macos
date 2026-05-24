# Packaging & distribution

OFEM ships as a signed and notarized Homebrew cask of the macOS `.app`.

## Output artifact

A single signed and notarized DMG containing `OneLake.app`. The `.app` bundles:
- The Swift host app (`OneLake`).
- The Swift File Provider Extension (`OneLakeFileProvider.appex`).
- The Go CLI binary (`ofem`), embedded at `OneLake.app/Contents/Resources/bin/ofem`.
- The Go core library is statically linked into the Swift binaries; not shipped separately.

## Build pipeline

```
        GitHub Actions (runs on macos-15-arm64)
        ────────────────────────────────────────
1. checkout
2. setup-go (1.26.x)
3. setup-xcode (latest 26.x)
4. cache go build, xcodebuild derived data
5. go build -buildmode=c-archive -o build/libofemcore.a ./core
6. go build -o build/ofem ./cmd/ofem
7. xcodebuild archive -scheme OneLake -archivePath build/OneLake.xcarchive
8. xcodebuild -exportArchive ... -exportPath build/Export
9. codesign --force --options runtime --sign "$DEVELOPER_ID_APPLICATION" \
       --entitlements apple/OneLake.entitlements build/Export/OneLake.app
10. create-dmg build/Export/OneLake.app build/OneLake-$VERSION.dmg
11. xcrun notarytool submit build/OneLake-$VERSION.dmg --wait \
        --key-id "$NOTARY_KEY_ID" --key "$NOTARY_API_KEY_P8" \
        --issuer "$NOTARY_ISSUER_ID"
12. xcrun stapler staple build/OneLake-$VERSION.dmg
13. goreleaser release (uploads DMG + checksums to GH Releases)
14. goreleaser bumps homebrew-ofem tap repo with new cask version
```

## Homebrew cask

We maintain a separate tap repository `homebrew-ofem`. The cask:

```ruby
cask "ofem" do
  arch arm: "arm64"
  version "2026.05.1"
  sha256 "abc123..."

  url "https://github.com/sdebruyn/onelake-explorer-macos/releases/download/v#{version}/OneLake-#{version}.dmg"
  name "OneLake"
  desc "OneLake File Explorer for macOS — Finder integration for Microsoft Fabric"
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
    "~/Library/Application Support/dev.debruyn.ofem",
    "~/Library/Caches/dev.debruyn.ofem",
    "~/Library/Logs/dev.debruyn.ofem",
    "~/Library/Preferences/dev.debruyn.ofem.plist",
    "~/Library/Group Containers/group.dev.debruyn.ofem",
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

## GoReleaser config (`.goreleaser.yaml`)

GoReleaser handles the Go binary part (`ofem` CLI) and Release upload. The Xcode part is a separate workflow step that produces the DMG which GoReleaser then attaches as a release artifact.

```yaml
project_name: ofem
before:
  hooks:
    - go mod tidy
builds:
  - id: ofem-cli
    main: ./cmd/ofem
    binary: ofem
    env:
      - CGO_ENABLED=1
    goos: [darwin]
    goarch: [arm64]
    ldflags:
      - -s -w
      - -X main.version={{.Version}}
      - -X main.appInsightsConnString={{.Env.OFEM_APPINSIGHTS_CONNSTRING}}
release:
  github:
    owner: sdebruyn
    name: onelake-explorer-macos
  prerelease: auto
  extra_files:
    - glob: ./build/OneLake-*.dmg
brews:
  - repository:
      owner: sdebruyn
      name: homebrew-ofem
    homepage: https://github.com/sdebruyn/onelake-explorer-macos
    description: OneLake File Explorer for macOS CLI
    test: |
      system "#{bin}/ofem", "--version"
```

Note: the `brews` block is for the **CLI-only** formula in `homebrew-ofem` (for users who want just the CLI without the full `.app`). The `.app` is shipped via the **cask** which is updated by a separate workflow step.

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
