#!/usr/bin/env bash
# inject-build-timestamp.sh — Build phase script: stamps OFEMBuildTimestamp into
# the compiled bundle's Info.plist.
#
# Runs as a post-compile Run Script phase so the timestamp is baked in after
# the Info.plist is processed by Xcode but before codesigning. The sandbox
# permits writing to ${BUILT_PRODUCTS_DIR}; the output file is declared in
# project.yml so the script sandboxing checker is satisfied.
#
# Format: ISO-8601 UTC, e.g. "2026-06-20T14:03:12Z".

set -euo pipefail

PLIST="${BUILT_PRODUCTS_DIR}/${INFOPLIST_PATH}"
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

/usr/libexec/PlistBuddy -c "Delete :OFEMBuildTimestamp" "${PLIST}" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :OFEMBuildTimestamp string ${TIMESTAMP}" "${PLIST}"
