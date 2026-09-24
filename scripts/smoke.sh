#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
SWITCHBOARD_SMOKE_APP="${1:-$PWD/dist/Switchboard.app}"
codesign --verify --strict "$SWITCHBOARD_SMOKE_APP"
python3 - "$SWITCHBOARD_SMOKE_APP" "$PWD/artifacts" <<'PY'
import pathlib, subprocess, sys
app, artifacts = map(pathlib.Path, sys.argv[1:])
binary = app / 'Contents/MacOS/Switchboard'
artifacts.mkdir(exist_ok=True)
subprocess.run([str(binary), '--smoke-test'], check=True, timeout=30)
subprocess.run([str(binary), '--check-quit'], check=True, timeout=10)
for name, flags in [('accounts-light', []), ('accounts-dark', ['--dark']), ('empty', ['--empty'])]:
    output = artifacts / (name + '.png')
    output.unlink(missing_ok=True)
    subprocess.run([str(binary), '--render-preview', str(output), *flags], check=True, timeout=20)
    if not output.exists() or output.stat().st_size < 10000:
        raise SystemExit(f'Preview rendering failed: {name}')
print('PASS: light, dark, and empty native screens rendered.')
PY
