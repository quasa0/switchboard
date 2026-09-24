#!/bin/bash
# Run only with authorization to publish the website.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/check-site.py
SWITCHBOARD_DEPLOYMENT=$(vercel deploy site --prod --yes)
python3 scripts/smoke-site.py "$SWITCHBOARD_DEPLOYMENT"
python3 scripts/smoke-site.py https://switchboard.quasa0.com
printf 'Verified: %s\n' "$SWITCHBOARD_DEPLOYMENT"
