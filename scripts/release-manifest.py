#!/usr/bin/env python3
"""Generate a public manifest from the actual packaged bytes."""
import hashlib
import json
import pathlib
import re
import sys

root = pathlib.Path(__file__).resolve().parent.parent
version = re.search(r"^SWITCHBOARD_VERSION=([0-9.]+)$", (root / "scripts/version.sh").read_text(), re.M)[1]
directory = pathlib.Path(sys.argv[1])
assets = []
for suffix in ("zip", "dmg"):
    name = f"Switchboard-{version}-universal.{suffix}"
    path = directory / name
    assets.append({"name": name, "url": f"https://github.com/quasa0/switchboard/releases/download/v{version}/{name}",
                   "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "bytes": path.stat().st_size})
manifest = {"version": version, "minimumMacOS": "14.0", "architectures": ["arm64", "x86_64"],
            "signing": "ad-hoc", "notarized": False, "assets": assets}
text = json.dumps(manifest, indent=2) + "\n"
(directory / "release.json").write_text(text)
(root / "site/release.json").write_text(text)
(directory / "SHA256SUMS.txt").write_text("".join(f"{a['sha256']}  {a['name']}\n" for a in assets))
