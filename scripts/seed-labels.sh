#!/usr/bin/env bash
# Sync GitHub issue labels from .github/labels.yml.
#
# Idempotent: existing labels are updated, missing ones are created. Labels
# not in the YAML are left alone (we do not destructively prune by default).
# Pass --prune to also delete labels that are not in the YAML.
#
# Usage:
#   ./scripts/seed-labels.sh            # create + update
#   ./scripts/seed-labels.sh --prune    # also delete labels not in YAML

set -eo pipefail

repo="${OFE_REPO:-sdebruyn/onelake-explorer-macos}"
labels_file=".github/labels.yml"
prune=false

for arg in "$@"; do
    case "$arg" in
        --prune) prune=true ;;
        *) echo "Unknown argument: $arg" >&2; exit 1 ;;
    esac
done

if ! command -v gh >/dev/null 2>&1; then
    echo "gh CLI is required: https://cli.github.com/" >&2
    exit 1
fi

if ! command -v yq >/dev/null 2>&1; then
    echo "yq is required: brew install yq" >&2
    exit 1
fi

if [ ! -f "$labels_file" ]; then
    echo "Cannot find $labels_file (run from repo root)" >&2
    exit 1
fi

echo "Syncing labels into $repo from $labels_file"

# Build "desired" set from YAML
desired_names=$(yq eval '.[].name' "$labels_file")

# Existing labels in the repo
existing_names=$(gh label list --repo "$repo" --limit 200 --json name --jq '.[].name')

# Create or update each desired label.
count=$(yq eval '. | length' "$labels_file")
for ((i = 0; i < count; i++)); do
    name=$(yq eval ".[${i}].name"        "$labels_file")
    color=$(yq eval ".[${i}].color"      "$labels_file")
    desc=$(yq eval ".[${i}].description" "$labels_file")

    if echo "$existing_names" | grep -Fxq "$name"; then
        gh label edit "$name" --repo "$repo" --color "$color" --description "$desc" >/dev/null
        printf '  updated  %s\n' "$name"
    else
        gh label create "$name" --repo "$repo" --color "$color" --description "$desc" >/dev/null
        printf '  created  %s\n' "$name"
    fi
done

if [ "$prune" = true ]; then
    echo
    echo "Pruning labels not present in $labels_file..."
    for name in $existing_names; do
        if ! echo "$desired_names" | grep -Fxq "$name"; then
            gh label delete "$name" --repo "$repo" --confirm >/dev/null
            printf '  deleted  %s\n' "$name"
        fi
    done
fi

echo
echo "Done."
