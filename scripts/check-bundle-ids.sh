#!/usr/bin/env bash
# check-bundle-ids.sh — CI drift guard for bundle IDs, team prefix, and app-group.
#
# Asserts that the three canonical identifiers are consistent across every
# source that declares them. Fails if any source disagrees so drift is caught
# at PR time rather than at notarization or runtime.
#
# Sources checked:
#   - Packages/OfemKit/Sources/OfemKit/Config/OfemPaths.swift  (OfemPaths.swift constants)
#   - project.yml                                               (XcodeGen spec)
#   - homebrew/Casks/ofem.rb.tmpl                              (cask template)
#   - .github/workflows/release.yml                            (ExportOptions bundle IDs)
#
# The full single-source refactor (xcconfig + entitlements $(…) substitution)
# is intentionally deferred to a dedicated signed-release-validated PR. This
# guard removes the silent-drift risk in the meantime.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

ERRORS=0

fail() {
  echo "ERROR: $*" >&2
  ERRORS=$((ERRORS + 1))
}

# ── Expected values (single source of truth for this check) ──────────────────
EXPECTED_BUNDLE_ID="dev.debruyn.ofem"
EXPECTED_FP_BUNDLE_ID="dev.debruyn.ofem.fileprovider"
EXPECTED_TEAM_ID="6D79CUWZ4J"
EXPECTED_APP_GROUP="${EXPECTED_TEAM_ID}.group.${EXPECTED_BUNDLE_ID}"

echo "Checking bundle IDs and identifiers for consistency..."
echo "  bundleID:       $EXPECTED_BUNDLE_ID"
echo "  fileprovider:   $EXPECTED_FP_BUNDLE_ID"
echo "  teamID:         $EXPECTED_TEAM_ID"
echo "  appGroup:       $EXPECTED_APP_GROUP"

# ── OfemPaths.swift ───────────────────────────────────────────────────────────
PATHS_FILE="Packages/OfemKit/Sources/OfemKit/Config/OfemPaths.swift"

if ! grep -qF "teamID = \"${EXPECTED_TEAM_ID}\"" "$PATHS_FILE"; then
  fail "OfemPaths.teamID is not '${EXPECTED_TEAM_ID}' in $PATHS_FILE"
fi

if ! grep -qF "bundleID = \"${EXPECTED_BUNDLE_ID}\"" "$PATHS_FILE"; then
  fail "OfemPaths.bundleID is not '${EXPECTED_BUNDLE_ID}' in $PATHS_FILE"
fi

# The appGroupIdentifier is composed via Swift string interpolation from the
# teamID and bundleID constants checked above. Verify the assignment references
# those constants by name (so no literal override can silently diverge).
if ! grep -q 'appGroupIdentifier.*teamID.*bundleID' "$PATHS_FILE"; then
  # Fallback: accept a hardcoded literal matching the expected value
  if ! grep -qF "\"${EXPECTED_APP_GROUP}\"" "$PATHS_FILE"; then
    fail "OfemPaths.appGroupIdentifier does not compose from teamID/bundleID in $PATHS_FILE"
  fi
fi

# ── project.yml ───────────────────────────────────────────────────────────────
PROJECT_FILE="project.yml"

if ! grep -qF "PRODUCT_BUNDLE_IDENTIFIER: ${EXPECTED_BUNDLE_ID}" "$PROJECT_FILE"; then
  fail "Host app bundle ID '${EXPECTED_BUNDLE_ID}' not found in $PROJECT_FILE"
fi

if ! grep -qF "PRODUCT_BUNDLE_IDENTIFIER: ${EXPECTED_FP_BUNDLE_ID}" "$PROJECT_FILE"; then
  fail "FPE bundle ID '${EXPECTED_FP_BUNDLE_ID}' not found in $PROJECT_FILE"
fi

# ── homebrew/Casks/ofem.rb.tmpl ───────────────────────────────────────────────
CASK_TMPL="homebrew/Casks/ofem.rb.tmpl"

if ! grep -qF "quit: \"${EXPECTED_BUNDLE_ID}\"" "$CASK_TMPL"; then
  fail "uninstall quit bundle ID '${EXPECTED_BUNDLE_ID}' not found in $CASK_TMPL"
fi

if ! grep -qF "\"~/Library/Group Containers/${EXPECTED_APP_GROUP}\"" "$CASK_TMPL"; then
  fail "App Group path '${EXPECTED_APP_GROUP}' not found in zap stanza of $CASK_TMPL"
fi

# ── release.yml ExportOptions ─────────────────────────────────────────────────
RELEASE_YML=".github/workflows/release.yml"

if ! grep -qF ":provisioningProfiles:${EXPECTED_BUNDLE_ID}" "$RELEASE_YML"; then
  fail "Host app bundle ID '${EXPECTED_BUNDLE_ID}' not found in ExportOptions in $RELEASE_YML"
fi

if ! grep -qF ":provisioningProfiles:${EXPECTED_FP_BUNDLE_ID}" "$RELEASE_YML"; then
  fail "FPE bundle ID '${EXPECTED_FP_BUNDLE_ID}' not found in ExportOptions in $RELEASE_YML"
fi

# ── Result ────────────────────────────────────────────────────────────────────
if [ "$ERRORS" -gt 0 ]; then
  echo ""
  echo "FAIL: $ERRORS bundle-ID consistency error(s) found." >&2
  echo "Fix the drift above before merging." >&2
  exit 1
fi

echo ""
echo "OK: all bundle-ID, team-ID, and app-group references are consistent."
