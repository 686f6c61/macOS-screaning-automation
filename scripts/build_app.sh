#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

swift build -c release

APP_NAME="Screening Automation.app"
APP_DIR="$ROOT_DIR/.build/release/$APP_NAME"
BIN_SRC="$ROOT_DIR/.build/release/ScreeningAutomation"
BIN_DST="$APP_DIR/Contents/MacOS/ScreeningAutomation"
SPARKLE_SRC="$ROOT_DIR/.build/release/Sparkle.framework"
SPARKLE_DST="$APP_DIR/Contents/Frameworks/Sparkle.framework"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$APP_DIR/Contents/Frameworks"
cp "$BIN_SRC" "$BIN_DST"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
ditto "$SPARKLE_SRC" "$SPARKLE_DST"

chmod +x "$BIN_DST"

SIGNING_IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null \
    | /usr/bin/awk -F '"' '/Apple Development/ { print $2; exit }')"
fi
if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="-"
fi

/usr/bin/codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP_DIR" >/dev/null

echo "$APP_DIR"
