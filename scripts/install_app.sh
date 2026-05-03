#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_SRC="$ROOT_DIR/.build/release/Screening Automation.app"
APP_DST="/Applications/Screening Automation.app"
LEGACY_APP_DST="/Applications/Monitor Screening.app"

"$ROOT_DIR/scripts/build_app.sh" >/dev/null

rm -rf "$APP_DST"
cp -R "$APP_SRC" "$APP_DST"
if [[ -d "$LEGACY_APP_DST" ]]; then
  rm -rf "$LEGACY_APP_DST"
fi
/usr/bin/codesign --verify --deep --strict "$APP_DST" >/dev/null

echo "$APP_DST"
