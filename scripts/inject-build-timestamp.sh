#!/usr/bin/env bash
# inject-build-timestamp.sh — Post-compile build phase: writes OFEMBuildInfo.plist
# into the built bundle's Resources directory.
#
# This is a pure-output script: it writes a SIDECAR file rather than modifying
# an existing one. Because the output does not overlap with any Xcode built-in
# step (Process Info.plist, codesign), there is no dependency cycle and no
# mutable-output error.
#
# Build-system wiring (project.yml):
#   inputFiles:  none             — timestamp is generated fresh; no input needed
#   outputFiles: [sidecar plist]  — pure distinct output; sandbox write permission
#   basedOnDependencyAnalysis: false — runs every build so the timestamp is current
#
# The sidecar is read at runtime via Bundle.url(forResource:withExtension:).
#
# Format: ISO-8601 UTC, e.g. "2026-06-20T14:03:12Z".

set -euo pipefail

# Guard: UNLOCALIZED_RESOURCES_FOLDER_PATH must be set and non-empty.
: "${UNLOCALIZED_RESOURCES_FOLDER_PATH:?UNLOCALIZED_RESOURCES_FOLDER_PATH is not set — is this script running outside an Xcode build phase?}"

DEST="${BUILT_PRODUCTS_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/OFEMBuildInfo.plist"
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# The Resources directory may not exist yet at post-compile time.
mkdir -p "$(dirname "${DEST}")"

# Write a fresh plist each build. Delete any prior value first so
# PlistBuddy can always use the Add command.
/usr/libexec/PlistBuddy -c "Delete :OFEMBuildTimestamp" "${DEST}" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :OFEMBuildTimestamp string ${TIMESTAMP}" "${DEST}"
