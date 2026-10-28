#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
IMAGE="${1:?DMG path required}"
WORK="$(mktemp -d -t flowgesture-install)"
MOUNT="$WORK/mount"
ATTACHED=0
cleanup() {
  if [[ "$ATTACHED" == 1 ]]; then hdiutil detach "$MOUNT" >/dev/null || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT
hdiutil verify "$IMAGE"
mkdir "$MOUNT"
hdiutil attach "$IMAGE" -readonly -nobrowse -mountpoint "$MOUNT"
ATTACHED=1
[[ "$(readlink "$MOUNT/Applications")" == /Applications ]]
# Exercise drag-install semantics outside the mounted, read-only image.
ditto "$MOUNT/FlowGesture.app" "$WORK/FlowGesture.app"
APP="$WORK/FlowGesture.app"
plutil -lint "$APP/Contents/Info.plist"
codesign --verify --strict "$APP"
lipo "$APP/Contents/MacOS/FlowGesture" -verify_arch arm64 x86_64
[[ -x "$APP/Contents/MacOS/FlowGesture" ]]
bash scripts/smoke-test-app.sh "$APP"
hdiutil detach "$MOUNT"
ATTACHED=0
shasum -a 256 "$IMAGE"
echo 'PASS: DMG verified, mounted read-only, drag-install copy verified and launched'
