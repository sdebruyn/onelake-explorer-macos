#!/usr/bin/env bash
# sign-and-notarize.sh — sign OneLake.app, create a DMG, submit for notarization,
# and staple the ticket. Prints the path to the stapled DMG on stdout.
#
# Usage:
#   sign-and-notarize.sh <path/to/OneLake.app>
#
# Required environment variables:
#   APPLE_TEAM_ID           Apple Developer Team ID (e.g. 6D79CUWZ4J).
#   APPLE_API_KEY_ID        App Store Connect API key identifier (10 chars).
#   APPLE_API_ISSUER_ID     App Store Connect API issuer UUID.
#   NOTARY_API_KEY_PATH     Absolute path to the .p8 private key file for notarytool.
#   VERSION                 CalVer string used to name the DMG, e.g. 2026.05.1.
#
# Optional environment variables:
#   OUTPUT_DIR              Directory where the DMG is written (default: ./dist-app).
#   NOTARY_TIMEOUT          Timeout passed to notarytool --timeout (default: 15m).
#
# Dependencies (must be on PATH):
#   codesign, xcrun, create-dmg (brew install create-dmg)
set -euo pipefail

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <path/to/OneLake.app>" >&2
    exit 1
fi
APP_PATH="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"

# ---------------------------------------------------------------------------
# Validate required env vars
# ---------------------------------------------------------------------------
: "${APPLE_TEAM_ID:?APPLE_TEAM_ID is required}"
: "${APPLE_API_KEY_ID:?APPLE_API_KEY_ID is required}"
: "${APPLE_API_ISSUER_ID:?APPLE_API_ISSUER_ID is required}"
: "${NOTARY_API_KEY_PATH:?NOTARY_API_KEY_PATH is required}"
: "${VERSION:?VERSION is required}"

OUTPUT_DIR="${OUTPUT_DIR:-./dist-app}"
NOTARY_TIMEOUT="${NOTARY_TIMEOUT:-15m}"

DMG_NAME="OneLake-${VERSION}.dmg"
DMG_PATH="${OUTPUT_DIR}/${DMG_NAME}"

# ---------------------------------------------------------------------------
# Codesign the app bundle recursively.
#
# xcodebuild already signs during the archive+export step, but this pass
# ensures the embedded CLI binary and any helper tools are also signed with
# the hardened runtime entitlements. --force re-signs everything; --timestamp
# embeds a secure timestamp required for notarization; --deep signs nested
# bundles (the .appex extension).
# ---------------------------------------------------------------------------
echo "Signing ${APP_PATH} ..."
codesign \
    --force \
    --deep \
    --options runtime \
    --timestamp \
    --sign "Developer ID Application: Debruyn Consultancy ($APPLE_TEAM_ID)" \
    "$APP_PATH"

echo "Verifying signature ..."
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
spctl --assess --type exec --verbose=4 "$APP_PATH" 2>&1 || true
# spctl can fail in CI if the Gatekeeper database is not fully initialized;
# the notarization step is the authoritative gate.

# ---------------------------------------------------------------------------
# Create the DMG.
# ---------------------------------------------------------------------------
mkdir -p "$OUTPUT_DIR"
echo "Creating ${DMG_PATH} ..."
create-dmg \
    --volname "OneLake ${VERSION}" \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 100 \
    --icon "OneLake.app" 175 190 \
    --hide-extension "OneLake.app" \
    --app-drop-link 425 190 \
    "$DMG_PATH" \
    "$APP_PATH"

# ---------------------------------------------------------------------------
# Submit DMG to the Apple notarization service.
# ---------------------------------------------------------------------------
echo "Submitting ${DMG_PATH} for notarization ..."
xcrun notarytool submit \
    "$DMG_PATH" \
    --key "$NOTARY_API_KEY_PATH" \
    --key-id "$APPLE_API_KEY_ID" \
    --issuer "$APPLE_API_ISSUER_ID" \
    --wait \
    --timeout "$NOTARY_TIMEOUT"

# ---------------------------------------------------------------------------
# Staple the notarization ticket so Gatekeeper works offline.
# ---------------------------------------------------------------------------
echo "Stapling notarization ticket ..."
xcrun stapler staple "$DMG_PATH"

echo "Done: $DMG_PATH"
