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
"${1:-build/FlowGesture.app}/Contents/MacOS/FlowGesture" --ui-smoke-test >"$LOG" 2>&1 &
PID=$!
for _ in {1..100}; do
  if ! kill -0 "$PID" 2>/dev/null; then
    if wait "$PID"; then cat "$LOG"; PID=""; exit 0; else cat "$LOG"; PID=""; exit 1; fi
  fi
  sleep 0.1
done
cat "$LOG"
echo 'FAIL: visible-window launch test timed out'
exit 1
