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
    <key>CFBundleName</key><string>Vein</string>
    <key>CFBundleDisplayName</key><string>Vein</string>
    <key>CFBundleIdentifier</key><string>com.midagedev.KeymapOverlay</string>
    <key>CFBundleExecutable</key><string>KeymapOverlay</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSUIElement</key><true/>
    <key>LSMinimumSystemVersion</key><string>12.0</string>
    <key>NSAccessibilityUsageDescription</key>
    <string>타이핑한 키를 하이라이트하려면 손쉬운 사용 권한이 필요합니다.</string>
</dict>
</plist>
EOF

cp presets/*.json "$APP/Contents/Resources/"
if [[ -f assets/AppIcon.icns ]]; then
    cp assets/AppIcon.icns "$APP/Contents/Resources/"
fi
if [[ -d assets/fx ]]; then
    mkdir -p "$APP/Contents/Resources/fx"
    cp assets/fx/* "$APP/Contents/Resources/fx/"
fi
swiftc -swift-version 5 -O -o "$APP/Contents/MacOS/KeymapOverlay" *.swift
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | rg -o 'Apple Development: [^"]+' | head -1)"
if [[ -n "${IDENTITY:-}" ]]; then
    codesign --force -s "$IDENTITY" "$APP" >/dev/null 2>&1
else
    codesign --force -s - "$APP" >/dev/null 2>&1
fi
echo "Built $APP (signed: ${IDENTITY:-adhoc})"
