#!/bin/bash
# No permissions, taps, MT devices, or physical input are used by this check.
set -euo pipefail
cd "$(dirname "$0")/.."
swift test --filter FlowGestureCaptureTests
swift build --product FlowGestureCapture
BIN_DIR="$(swift build --show-bin-path)"
TMP="$(mktemp -d -t flowgesture-capture-selftest)"
trap 'rm -rf "$TMP"' EXIT
"$BIN_DIR/FlowGestureCapture" --self-test --duration 1 --output "$TMP/report.json"
python3 - "$TMP/report.json" <<'PY'
import json, sys
with open(sys.argv[1]) as source:
    report = json.load(source)
assert report['mode'] == 'self-test'
assert report['evidenceScope'] == 'synthetic_in_memory_serialization_only'
assert report['stopReason'] == 'synthetic_self_test_complete'
assert not report['failureReasons']
assert len(report['records']) == 4
assert 'listenPermissionPreflight' not in report['runtime']
assert 'quartzTapEnabledElapsedNanoseconds' not in report['runtime']
assert report['records'][2]['quartz']['physicalProvenance'] == 'unverified_including_PID_zero'
PY
# Existing destinations must fail without replacing even one byte.
cp "$TMP/report.json" "$TMP/original.json"
if "$BIN_DIR/FlowGestureCapture" --self-test --duration 1 --output "$TMP/report.json"; then
  echo 'Existing output was incorrectly accepted' >&2
  exit 1
fi
cmp "$TMP/report.json" "$TMP/original.json"
printf 'Synthetic passive-capture serialization and exclusive-output checks passed.\n'
