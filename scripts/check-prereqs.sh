#!/usr/bin/env bash
# Validate the local environment for OFEM development.
#
# Run this before your first build to see what is installed and what is
# missing. Distinguishes "needed for local dev" from "needed only when
# publishing signed releases" so contributors are not asked to set up
# things they don't need.
#
# Usage: ./scripts/check-prereqs.sh

set -o pipefail

# Colors when stdout is a TTY.
if [ -t 1 ]; then
    RED=$'\033[0;31m'
    GRN=$'\033[0;32m'
    YLW=$'\033[0;33m'
    BLU=$'\033[0;34m'
    BLD=$'\033[1m'
    RST=$'\033[0m'
else
    RED='' GRN='' YLW='' BLU='' BLD='' RST=''
fi

fail_count=0
warn_count=0

ok()    { printf '  %s✓%s %s\n' "$GRN" "$RST" "$1"; }
miss()  { printf '  %s✗%s %s\n' "$RED" "$RST" "$1"; fail_count=$((fail_count+1)); }
warn()  { printf '  %s!%s %s\n' "$YLW" "$RST" "$1"; warn_count=$((warn_count+1)); }
hdr()   { printf '\n%s%s%s\n' "$BLD" "$1" "$RST"; }
hint()  { printf '      %s↳ %s%s\n' "$BLU" "$1" "$RST"; }

# Version comparison: returns 0 (true) if $1 >= $2 (semver-ish: dot-separated ints).
version_ge() {
    local IFS=.
    local -a a=($1) b=($2)
    local i
    for ((i=0; i<${#b[@]}; i++)); do
        local left=${a[i]:-0}
        local right=${b[i]:-0}
        if ((10#$left > 10#$right)); then return 0; fi
        if ((10#$left < 10#$right)); then return 1; fi
    done
    return 0
}

check_command() {
    local cmd="$1" min="$2" install_hint="$3"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        miss "$cmd is not installed"
        hint "$install_hint"
        return 1
    fi
    local got
    got=$($cmd --version 2>&1 | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
    if [ -z "$got" ]; then
        ok "$cmd (version detection failed; assuming OK)"
        return 0
    fi
    if version_ge "$got" "$min"; then
        ok "$cmd $got (need $min+)"
    else
        miss "$cmd $got is older than required $min"
        hint "$install_hint"
    fi
}

# --- macOS sanity ---

hdr "macOS environment"

os_name=$(uname -s)
if [ "$os_name" != "Darwin" ]; then
    miss "OFEM targets macOS; you are running $os_name"
else
    ok "Running macOS"
fi

arch=$(uname -m)
if [ "$arch" != "arm64" ]; then
    warn "Architecture is $arch; OFEM ships arm64-only binaries but you can still build for development on Intel"
else
    ok "Apple Silicon (arm64)"
fi

os_version=$(sw_vers -productVersion 2>/dev/null || echo "unknown")
if [ "$os_version" = "unknown" ]; then
    miss "Could not determine macOS version via sw_vers"
else
    if version_ge "$os_version" "14.0"; then
        ok "macOS $os_version (need 14.0+ for File Provider Extension target)"
    else
        warn "macOS $os_version is below the 14.0 target; you can still build but the File Provider Extension will not load"
    fi
fi

# --- Local development toolchain ---

hdr "Local development (required to build and test)"

check_command go      "1.26"  "brew install go"
check_command git     "2.40"  "comes with Xcode Command Line Tools"
check_command gh      "2.40"  "brew install gh"
check_command brew    "4.0"   "https://brew.sh"
check_command make    "3.81"  "comes with Xcode Command Line Tools"

if xcode-select -p >/dev/null 2>&1; then
    ok "Xcode Command Line Tools at $(xcode-select -p)"
else
    miss "Xcode Command Line Tools not installed"
    hint "xcode-select --install"
fi

if /usr/bin/xcodebuild -version >/dev/null 2>&1; then
    xcode_ver=$(xcodebuild -version 2>/dev/null | head -1 | awk '{print $2}')
    ok "Xcode $xcode_ver (only required when working on the .app / File Provider Extension)"
else
    warn "Full Xcode is not installed; not needed for Phase 0 Go development but required for Phase 1+"
    hint "install from the App Store, then run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
fi

# --- Lint and CI parity tools ---

hdr "Lint and CI parity (recommended)"

check_command golangci-lint "1.55" "brew install golangci-lint"
if command -v commitlint >/dev/null 2>&1; then
    cl_ver=$(commitlint --version 2>&1 | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
    if [ -n "$cl_ver" ] && version_ge "$cl_ver" "18.0"; then
        ok "commitlint $cl_ver (need 18.0+)"
    elif [ -n "$cl_ver" ]; then
        warn "commitlint $cl_ver is older than the 18.0+ documented in docs/prerequisites.md"
        hint "brew upgrade commitlint (or: npm i -g @commitlint/cli@latest)"
    else
        ok "commitlint installed (version detection failed; assuming OK)"
    fi
else
    warn "commitlint not installed (only needed if you want CI parity for commit-message validation)"
    hint "brew install commitlint (or: npm i -g @commitlint/cli @commitlint/config-conventional)"
fi

# goimports comes via go install; not strictly required.
if command -v goimports >/dev/null 2>&1; then
    ok "goimports installed"
else
    warn "goimports not installed (optional but recommended for 'make fmt')"
    hint "go install golang.org/x/tools/cmd/goimports@latest"
fi

# xcodegen owns the Xcode project (apple/project.yml); required from Phase 1
# onwards for `make apple-gen` / `make apple-build`. Treat absence as a warning
# (not a hard miss) because Phase 0 Go work doesn't need it, but if it *is*
# installed, compare the version against the 2.40 minimum from
# docs/prerequisites.md instead of just printing it.
if command -v xcodegen >/dev/null 2>&1; then
    xg_ver=$(xcodegen --version 2>&1 | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
    if [ -z "$xg_ver" ]; then
        ok "xcodegen installed (version detection failed; assuming OK)"
    elif version_ge "$xg_ver" "2.40"; then
        ok "xcodegen $xg_ver (need 2.40+, used by apple-gen/apple-build)"
    else
        warn "xcodegen $xg_ver is older than the 2.40+ documented in docs/prerequisites.md"
        hint "brew upgrade xcodegen"
    fi
else
    warn "xcodegen not installed (needed once you start working on the Phase 1 .app / File Provider Extension)"
    hint "brew install xcodegen"
fi

# --- GitHub authentication ---

hdr "GitHub authentication"

if gh auth status >/dev/null 2>&1; then
    gh_user=$(gh api user --jq .login 2>/dev/null || echo "?")
    ok "gh is authenticated (user: $gh_user)"
else
    warn "gh CLI is installed but not authenticated"
    hint "gh auth login"
fi

# --- Publishing / signing (informational only) ---

hdr "Publishing & signing (only required when cutting an official release)"

if command -v create-dmg >/dev/null 2>&1; then
    ok "create-dmg installed"
else
    warn "create-dmg not installed (only needed when packaging the .app)"
    hint "brew install create-dmg"
fi

# Look for a Developer ID Application code-signing certificate.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
    ok "Developer ID Application certificate present in the login keychain"
else
    warn "No Developer ID Application certificate in the login keychain (required only when shipping signed builds)"
    hint 'Apple Developer Program enrollment ($99/yr), then Xcode → Settings → Accounts → Manage Certificates → +'
fi

# notarytool ships with Xcode.
if xcrun --find notarytool >/dev/null 2>&1; then
    ok "xcrun notarytool available"
else
    warn "xcrun notarytool not found (comes with Xcode 13+; only needed for notarized releases)"
fi

# --- Summary ---

hdr "Summary"

printf 'Missing required: %s%d%s\n' "$RED" "$fail_count" "$RST"
printf 'Warnings:         %s%d%s\n' "$YLW" "$warn_count" "$RST"
echo
if [ "$fail_count" -gt 0 ]; then
    echo "Resolve the items marked ✗ before running 'make ci'."
    exit 1
fi
if [ "$warn_count" -gt 0 ]; then
    echo "You can build and test OFEM locally. Warnings cover optional or release-only tools."
fi
exit 0
