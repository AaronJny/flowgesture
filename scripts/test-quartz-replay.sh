#!/usr/bin/env bash
# Opt-in OS transport test. Only zero-motion public scroll packets are posted.
# Never grants access, changes TCC/system settings, or launches the app engine.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "${FLOWGESTURE_RUN_QUARTZ_REPLAY:-}" != 1 ]]; then
  echo 'Refusing live event posting without FLOWGESTURE_RUN_QUARTZ_REPLAY=1.' >&2
  exit 2
fi
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'Live Quartz replay requires macOS; no events were posted.' >&2
  exit 2
fi
cd "$ROOT"
export FLOWGESTURE_QUARTZ_REPLAY_REVISION="$(git rev-parse HEAD)"
export FLOWGESTURE_QUARTZ_REPLAY_REPORT="${FLOWGESTURE_QUARTZ_REPLAY_REPORT:-$ROOT/build/quartz-replay/report.json}"
mkdir -p "$(dirname -- "$FLOWGESTURE_QUARTZ_REPLAY_REPORT")"
swift test --filter QuartzReplayProbeTests/testOptInLiveQuartzReplay
