#!/usr/bin/env bash
# Cloudflare Pages build entrypoint for ofem.debruyn.dev.
#
# Configure the CF Pages app with:
#   Build command:        bash docs_build/cloudflare_pages.sh
#   Build output dir:     docs_build/site
#   Root directory:       (leave empty — defaults to repo root)
#   Environment:          PYTHON_VERSION = 3.12   (or 3.13, both work)
#
# CF Pages auto-installs requirements.txt if present in the root
# directory; we keep ours under docs_build/ to scope Python tooling to
# the docs build only. The pip install below covers it.
#
# We sideload Umami's /t.js at the end so the analytics partial in
# overrides/partials/integrations/analytics/custom.html keeps working
# even if the upstream script-host changes URLs.

set -ex

python -m pip install --upgrade pip
python -m pip install -r docs_build/requirements.txt

# pip installs console scripts to sysconfig's "scripts" path. On CF
# Pages' buildhome that resolves to ~/.local/bin (PEP 668 enforces
# --user installs into the user site), which is not on PATH by default.
# Resolve it and prepend so `zensical` is found regardless of how the
# build image initialises its shell.
SCRIPTS_DIR=$(python -c "import sysconfig; print(sysconfig.get_paths()['scripts'])")
USER_SCRIPTS_DIR=$(python -c "import site, os; print(os.path.join(site.getuserbase(), 'bin'))")
export PATH="${SCRIPTS_DIR}:${USER_SCRIPTS_DIR}:${PATH}"

zensical build

curl -sLo ./docs_build/site/t.js "https://cloud.umami.is/script.js"
