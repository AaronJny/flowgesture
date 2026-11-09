#!/bin/bash
# Synthetic-only: no opt-in, session/registry calls, permissions, or input.
set -euo pipefail
cd "$(dirname "$0")/.."
TMP="$(mktemp -d "${TMPDIR:-/tmp}/flowgesture-console-probe-selftest.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
# Compile all macOS branches too, without invoking the live probe.
if [[ "$(uname -s)" == Darwin ]]; then
  swiftc scripts/probe-console-session.swift -framework IOKit -framework Security -o "$TMP/probe"
else
  swiftc scripts/probe-console-session.swift -o "$TMP/probe"
fi
# Explicitly remove a possible inherited opt-in before verifying the refusal.
unset FLOWGESTURE_RUN_CONSOLE_SESSION_PROBE
"$TMP/probe" --self-test > "$TMP/synthetic.json"
python3 - "$TMP/synthetic.json" <<'PY'
import json, sys
with open(sys.argv[1]) as source:
    report = json.load(source)
assert set(report) == {'mode', 'scope', 'result', 'checks'}
assert report['mode'] == 'self_test'
assert report['scope'] == 'synthetic_in_memory_only_no_session_or_registry_reads'
assert report['result'] == 'passed' and report['checks'] >= 80
PY
set +e
"$TMP/probe" --probe > "$TMP/refused.json" 2> "$TMP/refused.txt"
STATUS=$?
set -e
[[ "$STATUS" == 2 && ! -s "$TMP/refused.json" ]]
grep -Fxq 'Refusing console-session read without FLOWGESTURE_RUN_CONSOLE_SESSION_PROBE=1.' "$TMP/refused.txt"
printf 'Synthetic console-session matching, strict-type, privacy, and opt-in checks passed.\n'
