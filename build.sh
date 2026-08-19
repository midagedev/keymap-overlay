#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP=build/KeymapOverlay.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>KeymapOverlay</string>
    <key>CFBundleIdentifier</key><string>com.midagedev.KeymapOverlay</string>
    <key>CFBundleExecutable</key><string>KeymapOverlay</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSUIElement</key><true/>
    <key>LSMinimumSystemVersion</key><string>12.0</string>
    <key>NSAccessibilityUsageDescription</key>
    <string>Pressed-key highlighting uses the macOS Accessibility API.</string>
</dict>
</plist>
EOF

cp presets/*.json "$APP/Contents/Resources/"
swiftc -swift-version 5 -O -o "$APP/Contents/MacOS/KeymapOverlay" *.swift
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | rg -o 'Apple Development: [^"]+' | head -1)"
if [[ -n "${IDENTITY:-}" ]]; then
    codesign --force -s "$IDENTITY" "$APP" >/dev/null 2>&1
else
    codesign --force -s - "$APP" >/dev/null 2>&1
fi
echo "Built $APP (signed: ${IDENTITY:-adhoc})"
