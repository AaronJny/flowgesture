#!/bin/bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
output="${1:-$here/AppIcon.icns}"
/usr/bin/iconutil --convert icns "$here/AppIcon.iconset" --output "$output"
echo "$output"
