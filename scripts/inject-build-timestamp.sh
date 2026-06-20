#!/usr/bin/env bash
# inject-build-timestamp.sh — Post-compile build phase: stamps OFEMBuildTimestamp
# into the compiled bundle's Info.plist.
#
# Build-system wiring (project.yml):
#   inputFiles:  [plist]         — ordering edge; forces "Process Info.plist" first
#   outputFiles: [plist, stamp]  — plist: sandbox write permission
#                                  stamp: distinct output node required by llbuild
#                                  when the task is alwaysOutOfDate (mutable output)
#   basedOnDependencyAnalysis: false — runs every build so the timestamp is current
#
# The stamp file (${DERIVED_FILE_DIR}/ofem-build-timestamp.stamp) is the "other
# virtual output node" llbuild requires to schedule an always-run task that also
# has a mutable (in-place) output. Without it the build fails with:
#   "invalid task … with mutable output but no other virtual output node"
#
# Format: ISO-8601 UTC, e.g. "2026-06-20T14:03:12Z".

set -euo pipefail

# Guard: INFOPLIST_PATH must be set and non-empty (Xcode injects it; an
# absent or empty value means the build environment is misconfigured).
: "${INFOPLIST_PATH:?INFOPLIST_PATH is not set — is this script running outside an Xcode build phase?}"

PLIST="${BUILT_PRODUCTS_DIR}/${INFOPLIST_PATH}"
STAMP="${DERIVED_FILE_DIR}/ofem-build-timestamp.stamp"

# Guard: the plist must already exist (written by Xcode's Process Info.plist
# step, which this script's input-file declaration orders before us).
if [[ ! -f "${PLIST}" ]]; then
    echo "error: Info.plist not found at '${PLIST}' — Process Info.plist step may not have run yet" >&2
    exit 1
fi

TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

/usr/libexec/PlistBuddy -c "Delete :OFEMBuildTimestamp" "${PLIST}" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :OFEMBuildTimestamp string ${TIMESTAMP}" "${PLIST}"

# Write the stamp so the declared output node exists (required by llbuild).
touch "${STAMP}"
