#!/bin/bash
# Build a tester artifact only. This never enables live capture or asks for access.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --arch arm64 --arch x86_64 --product FlowGestureCapture
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
OUT="$PWD/build/capture-tool"
mkdir -p "$OUT"
cp "$BIN_DIR/FlowGestureCapture" "$OUT/FlowGestureCapture"
lipo "$OUT/FlowGestureCapture" -verify_arch arm64 x86_64
codesign --force --sign - "$OUT/FlowGestureCapture"
codesign --verify --strict "$OUT/FlowGestureCapture"
git rev-parse HEAD > "$OUT/SOURCE_REVISION.txt"
"$OUT/FlowGestureCapture" --help > "$OUT/USAGE.txt"
cat > "$OUT/README.txt" <<'TEXT'
FlowGestureCapture is an explicit, passive research collector, not a native-gesture blocker.
This CI artifact is ad-hoc signed, not Developer ID signed or notarized.
Do not disable or bypass macOS security protections to run it. Source is available
in the repository at SOURCE_REVISION.txt for an authorized developer/tester build.

It requests no permission and changes no system settings. Live capture requires
pre-existing access and a verifiably eligible local session. Output is local and
new-file-only; review it before choosing whether to share. Numeric device IDs,
contact coordinates and narrowly scoped event metadata can be present.

USAGE.txt describes explicit --capture and hardware-free --self-test modes.
A successful self-test or CI run does not validate physical provenance, complete
stream visibility, raw/native correlation, or macOS gesture suppression.

Known live-capture limitation (verified 2026-11-09): macOS 15 ARM/Intel and 26 ARM
hosted sessions omit the explicit screen-lock Boolean even in an active console
session. This collector rejects that unknown state before device enumeration or
capture. Its tests and refusal path pass, but physical live capture has not been
demonstrated. A normal unlocked machine may therefore also be refused. Do not
treat missing lock state as false or weaken the gate merely to obtain a trace.
TEXT
TMP="$(mktemp -d -t flowgesture-capture-release-check)"
trap 'rm -rf "$TMP"' EXIT
"$OUT/FlowGestureCapture" --self-test --duration 1 --output "$TMP/report.json"
python3 - "$TMP/report.json" <<'PY'
import json, sys
with open(sys.argv[1]) as source:
    report = json.load(source)
assert report['mode'] == 'self-test'
assert report['stopReason'] == 'synthetic_self_test_complete'
assert not report['failureReasons']
assert len(report['records']) == 4
PY
(cd "$OUT" && shasum -a 256 FlowGestureCapture SOURCE_REVISION.txt USAGE.txt README.txt > SHA256SUMS.txt)
echo 'PASS: universal passive collector packaged and self-tested without hardware.'
