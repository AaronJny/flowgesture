#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/flowgesture-native.XXXXXX")"
trap 'rm -rf -- "$BUILD"' EXIT
CC="${CC:-cc}"
FLAGS=(-std=c11 -Wall -Wextra -Werror -pedantic -g)
LINK=(-lm)
if [[ "$(uname -s)" == Darwin ]]; then
  # Tests intentionally do not start hardware capture or request permissions.
  LINK+=(-framework CoreFoundation -framework CoreGraphics -framework IOKit)
fi
if [[ "${SANITIZE:-0}" == 1 ]]; then
  FLAGS+=(-fsanitize=address,undefined)
fi
"$CC" "${FLAGS[@]}" \
  -I "$ROOT/Sources/FlowGestureNative/include" \
  -I "$ROOT/Sources/FlowGestureNative" \
  "$ROOT/Tests/FlowGestureNativeTests/bridge_test.c" \
  "$ROOT/Sources/FlowGestureNative/TouchDecode.c" \
  "$ROOT/Sources/FlowGestureNative/FlowGestureNative.c" \
  "${LINK[@]}" -o "$BUILD/bridge-test"
"$BUILD/bridge-test"
