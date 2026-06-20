#!/usr/bin/env bash
# inject-build-timestamp.sh — Post-compile build phase: stamps OFEMBuildTimestamp
# into the compiled bundle's Info.plist.
#
# The script phase declares the plist as both an input and output file, which
# creates a dependency edge that forces Xcode to run "Process Info.plist"
# before this script. basedOnDependencyAnalysis is false so the script runs
# on every build and the timestamp is always current.
#
# Format: ISO-8601 UTC, e.g. "2026-06-20T14:03:12Z".

set -euo pipefail

# Guard: INFOPLIST_PATH must be set and non-empty (Xcode injects it; an
# absent or empty value means the build environment is misconfigured).
: "${INFOPLIST_PATH:?INFOPLIST_PATH is not set — is this script running outside an Xcode build phase?}"

PLIST="${BUILT_PRODUCTS_DIR}/${INFOPLIST_PATH}"

# Guard: the plist must already exist (written by Xcode's Process Info.plist
# step, which this script's input-file declaration orders before us).
if [[ ! -f "${PLIST}" ]]; then
    echo "error: Info.plist not found at '${PLIST}' — Process Info.plist step may not have run yet" >&2
    exit 1
fi

TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

/usr/libexec/PlistBuddy -c "Delete :OFEMBuildTimestamp" "${PLIST}" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :OFEMBuildTimestamp string ${TIMESTAMP}" "${PLIST}"
