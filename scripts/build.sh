#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
SWITCHBOARD_APP="$PWD/dist/Switchboard.app"
mkdir -p "$SWITCHBOARD_APP/Contents/MacOS" "$SWITCHBOARD_APP/Contents/Resources"
cp .build/release/Switchboard "$SWITCHBOARD_APP/Contents/MacOS/Switchboard"
cat > "$SWITCHBOARD_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Switchboard</string>
<key>CFBundleIdentifier</key><string>com.quasa0.switchboard</string>
<key>CFBundleName</key><string>Switchboard</string>
<key>CFBundleDisplayName</key><string>Switchboard</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.5.0</string>
<key>CFBundleVersion</key><string>8</string>
<key>CFBundleIconFile</key><string>Switchboard.icns</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
if [ -f scripts/icon.swift ]; then
  swift scripts/icon.swift "$SWITCHBOARD_APP/Contents/Resources/Switchboard.icns"
fi
SWITCHBOARD_IDENTITY="${SWITCHBOARD_SIGNING_IDENTITY:--}"
if [ "$SWITCHBOARD_IDENTITY" = "-" ]; then
  SWITCHBOARD_DETECTED=$(security find-identity -v -p codesigning | sed -n 's/.*) \([A-F0-9]\{40\}\) "Apple Development:.*/\1/p' | awk 'NR == 1 { print }')
  if [ -n "$SWITCHBOARD_DETECTED" ]; then SWITCHBOARD_IDENTITY="$SWITCHBOARD_DETECTED"; fi
fi
codesign --force --sign "$SWITCHBOARD_IDENTITY" --options runtime "$SWITCHBOARD_APP"
codesign --verify --strict "$SWITCHBOARD_APP"
printf 'Built: %s\n' "$SWITCHBOARD_APP"
