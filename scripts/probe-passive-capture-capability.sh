#!/bin/bash
# Explicit hosted-runner capability observation, never a physical-input test.
set -euo pipefail
if [[ "${FLOWGESTURE_RUN_CAPTURE_CAPABILITY:-}" != 1 || "$(uname -s)" != Darwin ]]; then
  echo 'Refusing live capture capability check without explicit macOS opt-in.' >&2
  exit 2
fi
cd "$(dirname "$0")/.."
swift build --product FlowGestureCapture
BIN_DIR="$(swift build --show-bin-path)"
OUT="$PWD/build/capture-capability/report.json"
mkdir -p "$(dirname "$OUT")"
if [[ -e "$OUT" || -L "$OUT" ]]; then
  echo 'Refusing to replace an existing capture capability report.' >&2
  exit 2
fi
set +e
"$BIN_DIR/FlowGestureCapture" --capture --duration 1 --max-records 256 --scenario baseline --revision "$(git rev-parse HEAD)" --output "$OUT"
STATUS=$?
set -e
python3 - "$OUT" "$STATUS" <<'PY'
import json, sys
with open(sys.argv[1]) as source:
    r = json.load(source)
status = int(sys.argv[2])
assert r['mode'] == 'capture' and r['evidenceScope'] == 'passive_callback_observations_only'
assert r['requestedDurationSeconds'] == 1 and r['maximumRecords'] == 256
assert len(r['records']) <= 256
known_absence = r['stopReason'] in {
    'missing_preexisting_listen_permission', 'inactive_or_unavailable_console_session',
    'console_session_state_unknown', 'console_session_screen_locked'
} or (r['stopReason'] == 'touch_monitor_start_failed' and r['runtime'].get('touchStatusCode') in {2, 3})
assert (status == 0 and r['stopReason'] == 'duration_elapsed' and not r['failureReasons']) or (status == 1 and known_absence), (status, r['stopReason'], r['failureReasons'])
print(json.dumps({
    'scope': 'hosted_runner_capability_only_not_physical_gesture_validation',
    'stopReason': r['stopReason'], 'failureReasons': r['failureReasons'],
    'runtime': r['runtime'], 'devicesEnumerated': len(r['devices']),
    'recordsStored': len(r['records']), 'counts': r['counts'],
    'osBuild': r['environment'].get('exactOSBuild'),
}, sort_keys=True))
PY
