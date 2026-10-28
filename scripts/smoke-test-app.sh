#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
LOG="$(mktemp -t flowgesture-smoke)"
PID=""
cleanup() {
  if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then kill "$PID"; wait "$PID" 2>/dev/null || true; fi
  rm -f "$LOG"
}
trap cleanup EXIT
# No permission grants and no configured input actions: this verifies startup only.
build/FlowGesture.app/Contents/MacOS/FlowGesture >"$LOG" 2>&1 &
PID=$!
sleep 3
if ! kill -0 "$PID" 2>/dev/null; then cat "$LOG"; echo 'App exited during launch smoke test'; exit 1; fi
echo 'PASS: app remained running for launch smoke test (not hardware interaction validation)'
