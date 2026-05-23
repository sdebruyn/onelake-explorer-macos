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
# directory; we have one under docs_build/ instead so the project root
# stays a clean Go project. The pip install below covers it.
#
# We sideload Umami's /t.js at the end so the analytics partial in
# overrides/partials/integrations/analytics/custom.html keeps working
# even if the upstream script-host changes URLs.

set -ex

python -m pip install --upgrade pip
python -m pip install -r docs_build/requirements.txt

zensical build

curl -sLo ./docs_build/site/t.js "https://cloud.umami.is/script.js"
