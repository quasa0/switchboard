#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build.sh
SWITCHBOARD_DEST="$HOME/Applications/Switchboard.app"
if pgrep -x Switchboard >/dev/null; then
  printf 'Quit Switchboard before installing.\n' >&2
  exit 1
fi
mkdir -p "$SWITCHBOARD_DEST"
rsync -a --delete dist/Switchboard.app/ "$SWITCHBOARD_DEST/"
codesign --verify --strict "$SWITCHBOARD_DEST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$SWITCHBOARD_DEST"
printf 'Installed: %s\n' "$SWITCHBOARD_DEST"
