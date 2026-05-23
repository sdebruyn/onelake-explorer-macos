# Packaging & distribution

## Phase 0 (developer-only)

No distribution. `go build ./cmd/ofe` produces a local binary for development. No Apple Developer artifacts required.

## Phase 1+ — Homebrew cask of the macOS `.app`

### Output artifact

A single signed and notarized DMG containing `OneLake.app`. The `.app` bundles:
- The Swift host app (`OneLake`).
- The Swift File Provider Extension (`OneLakeFileProvider.appex`).
- The Go CLI binary (`ofe`), embedded at `OneLake.app/Contents/Resources/bin/ofe`.
- The Go core library is statically linked into the Swift binaries; not shipped separately.

### Build pipeline

```
        GitHub Actions (runs on macos-15-arm64)
        ────────────────────────────────────────
1. checkout
2. setup-go (1.26.x)
3. setup-xcode (latest 26.x)
4. cache go build, xcodebuild derived data
5. go build -buildmode=c-archive -o build/libofecore.a ./core
6. go build -o build/ofe ./cmd/ofe
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
14. goreleaser bumps homebrew-ofe tap repo with new cask version
```

### Homebrew cask

We maintain a separate tap repository `homebrew-ofe`. The cask:

```ruby
cask "ofe" do
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
  binary "#{appdir}/OneLake.app/Contents/Resources/bin/ofe"

  postflight do
    # Trigger launchd registration on first install
    system_command "#{appdir}/OneLake.app/Contents/Resources/bin/ofe",
                   args: ["daemon", "install"],
                   sudo: false
  end

  uninstall launchctl: "dev.debruyn.ofe.daemon",
            quit:      "dev.debruyn.ofe.app",
            delete:    [
              "~/Library/LaunchAgents/dev.debruyn.ofe.daemon.plist",
            ]

  zap trash: [
    "~/Library/Application Support/dev.debruyn.ofe",
    "~/Library/Caches/dev.debruyn.ofe",
    "~/Library/Logs/dev.debruyn.ofe",
    "~/Library/Preferences/dev.debruyn.ofe.plist",
    "~/Library/Group Containers/group.dev.debruyn.ofe",
    "~/Library/CloudStorage/OneLake-*",
  ]
end
```

`zap` runs on `brew uninstall --zap ofe` and wipes user data; default `brew uninstall` preserves it.

### Versioning

CalVer: `YYYY.MM.PATCH` (e.g. `2026.05.1`). A git tag `v2026.05.1` triggers the release pipeline.

### Signing identity and notarization

We need:
- Apple Developer Program enrollment (~$99/year). Required to obtain code signing certificates.
- A **Developer ID Application** certificate, exported as a `.p12` and stored in GitHub Actions secrets (`DEVELOPER_ID_APPLICATION_P12_BASE64` + `DEVELOPER_ID_APPLICATION_P12_PASSWORD`).
- An **App Store Connect API key** for `notarytool` (preferred over app-specific passwords because it doesn't expire and is per-team scoped):
  - `NOTARY_KEY_ID` — the 10-character key identifier.
  - `NOTARY_ISSUER_ID` — the issuer UUID.
  - `NOTARY_API_KEY_P8` — the contents of the `.p8` private key.
- A **Provisioning profile** is not required for non-Mac-App-Store distribution; Developer ID signing is sufficient.

### Entitlements

`apple/OneLake.entitlements`:
- `com.apple.security.app-sandbox` = true.
- `com.apple.security.application-groups` = `[group.dev.debruyn.ofe]`.
- `com.apple.security.network.client` = true.
- `com.apple.security.files.user-selected.read-write` = true.
- `com.apple.security.keychain-access-groups` = `[$(AppIdentifierPrefix)group.dev.debruyn.ofe]`.

`apple/OneLakeFileProvider.entitlements` adds:
- `com.apple.developer.file-provider.testing-mode` = true (in dev builds only).
- `NSExtension` plist with `NSExtensionFileProviderSupportedItemActions` enumerated.

### GoReleaser config (`.goreleaser.yaml`)

GoReleaser handles the Go binary part (`ofe` CLI) and Release upload. The Xcode part is a separate workflow step that produces the DMG which GoReleaser then attaches as a release artifact.

```yaml
project_name: ofe
before:
  hooks:
    - go mod tidy
builds:
  - id: ofe-cli
    main: ./cmd/ofe
    binary: ofe
    env:
      - CGO_ENABLED=1
    goos: [darwin]
    goarch: [arm64]
    ldflags:
      - -s -w
      - -X main.version={{.Version}}
      - -X main.appInsightsConnString={{.Env.OFE_APPINSIGHTS_CONNSTRING}}
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
      name: homebrew-ofe
    homepage: https://github.com/sdebruyn/onelake-explorer-macos
    description: OneLake File Explorer for macOS CLI
    test: |
      system "#{bin}/ofe", "--version"
```

Note: the `brews` block is for the **CLI-only** formula in `homebrew-ofe` (for users who want just the CLI without the full `.app`). The `.app` is shipped via the **cask** which is updated by a separate workflow step.

### Pre-release / beta channel

No formal beta tap. Pre-release versions are tagged like `v2026.05.0-rc.1` and GoReleaser marks the GitHub Release as "prerelease". Users who want to try them download the DMG directly from the Releases page. Stable installs via Homebrew see only stable tags.

### Update mechanism

`brew upgrade --cask ofe`. No in-app update check; no Sparkle. The daemon logs the running version on startup so users can compare against `brew info ofe` output.

### Uninstall

```bash
brew uninstall --cask ofe          # removes app, keeps data
brew uninstall --cask --zap ofe    # removes app + all user data
```

The `uninstall launchctl:` directive in the cask stops the daemon. The `app` directive removes `OneLake.app`. `zap` removes everything else.

### Local development distribution

For pre-release dogfooding, developers can run `./scripts/build-local.sh` which:
1. Builds the Go binary (no codesigning).
2. Builds the Xcode project with the locally available developer certificate (or ad-hoc signing).
3. Skips notarization.
4. Produces `build/OneLake.app` ready to drag into `/Applications`.

This won't pass Gatekeeper on other machines without manual override (`xattr -d com.apple.quarantine`), which is fine for personal dogfooding.
