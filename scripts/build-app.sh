#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --arch arm64 --arch x86_64
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
lipo "$BIN_DIR/FlowGesture" -verify_arch arm64 x86_64
APP="$PWD/build/FlowGesture.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/FlowGesture" "$APP/Contents/MacOS/FlowGesture"
bash assets/AppIcon/build-icns.sh "$APP/Contents/Resources/AppIcon.icns"
cp assets/MenuBar/MenuBarTemplate*.png "$APP/Contents/Resources/"
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
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSAppleEventsUsageDescription</key><string>Run automation actions that you configure.</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
plutil -lint "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
STAGING="$(mktemp -d -t flowgesture-dmg)"
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP" "$STAGING/FlowGesture.app"
ln -s /Applications "$STAGING/Applications"
cp "$APP/Contents/Resources/AppIcon.icns" "$STAGING/.VolumeIcon.icns"
SetFile -a C "$STAGING"
hdiutil create -volname "FlowGesture" -srcfolder "$STAGING" -ov -format UDZO "$PWD/build/FlowGesture-macos.dmg"
hdiutil verify "$PWD/build/FlowGesture-macos.dmg"
printf '\nBuilt %s\n' "$APP"
