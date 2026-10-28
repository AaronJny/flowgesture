#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="$PWD/build/FlowGesture.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/FlowGesture" "$APP/Contents/MacOS/FlowGesture"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>FlowGesture</string>
<key>CFBundleIdentifier</key><string>com.aaronjny.flowgesture</string>
<key>CFBundleName</key><string>FlowGesture</string>
<key>CFBundleDisplayName</key><string>FlowGesture</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSAppleEventsUsageDescription</key><string>Run automation actions that you configure.</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$PWD/build/FlowGesture-macos.zip"
printf '\nBuilt %s\n' "$APP"
