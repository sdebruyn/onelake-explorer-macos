# Release runbook

Step-by-step process for cutting an OFEM release. Versioning follows CalVer:
`YYYY.MM.PATCH` (e.g. `2026.05.1`). The tag format is `vYYYY.MM.PATCH`.

## Prerequisites

- All secrets listed in [docs/packaging-homebrew.md](packaging-homebrew.md#github-secrets)
  are configured in GitHub Actions.
- The `sdebruyn/homebrew-ofem` tap repo exists and has been bootstrapped with
  the dummy `0.0.0` cask.
- The `HOMEBREW_TAP_GH_TOKEN` has Contents: write on `sdebruyn/homebrew-ofem`.
- `main` is green on CI.

## Steps

### 1. Confirm the version number

Pick the next CalVer string. PATCH resets to 1 on a new month:

```
2026.05.1, 2026.05.2, ...  (first patch of May 2026, second, ...)
2026.06.1                   (first patch of June 2026)
```

### 2. Update CHANGELOG (if maintained)

If the project has a `CHANGELOG.md`, update it now with the release notes.
Commit with `docs(changelog): v$VERSION`.

### 3. Tag and push

```bash
VERSION=2026.05.1
git tag -a "v$VERSION" -m "chore(release): v$VERSION"
git push origin "v$VERSION"
```

### 4. Watch the GitHub Actions release workflow

Navigate to **Actions > Release** in the repository. The two jobs should
run sequentially:

- **Build, sign, and notarize app** (~10-15 min, depends on notarization queue).
- **Publish CLI release and update cask** (~3 min).

If either job fails, see the troubleshooting section below.

### 5. Verify the GitHub Release

At [github.com/sdebruyn/onelake-explorer-macos/releases](https://github.com/sdebruyn/onelake-explorer-macos/releases),
confirm:

- `OneLake-$VERSION.dmg` is attached and has the correct size.
- `ofem_$VERSION_darwin_arm64.tar.gz` is attached.
- `checksums.txt` is attached.
- The release is not marked as a draft.
- Pre-release flag is correct (set for `-rc.*` tags, unset for stable).

### 6. Verify the Homebrew tap

```bash
brew tap sdebruyn/ofem
brew update
brew info --cask sdebruyn/ofem/ofem    # confirms new version
brew install --cask sdebruyn/ofem/ofem
/Applications/OneLake.app/Contents/Resources/bin/ofem --version
brew uninstall --cask sdebruyn/ofem/ofem
brew untap sdebruyn/ofem
```

### 7. Announce (placeholder)

Post a brief release note in the #release Slack channel (or wherever the team
communicates). Include the version number and a link to the GitHub Release.

## Troubleshooting

### Notarization times out

Increase `NOTARY_TIMEOUT` in the workflow or re-run the job. Apple's
notarization queue is typically under 5 minutes for a small app.

### DMG SHA-256 mismatch in cask

The cask update step computes the SHA-256 from the DMG on disk immediately
after notarization. If the artifact is re-uploaded, re-run the
`release-cli-and-cask` job after re-running `build-app`.

### Signing identity not found

The temporary keychain import may have failed. Check that `APPLE_CERT_P12`
is properly base64-encoded and `APPLE_CERT_PASSWORD` matches the export
password. Verify locally with:
```bash
echo "$APPLE_CERT_P12" | base64 --decode > /tmp/test.p12
security import /tmp/test.p12 -P "$APPLE_CERT_PASSWORD" -T /usr/bin/codesign
rm /tmp/test.p12
```

### Cask push fails with permission error

Verify that `HOMEBREW_TAP_GH_TOKEN` has Contents: write on `sdebruyn/homebrew-ofem`
and that the token has not expired (fine-grained PATs can be set to expire).
