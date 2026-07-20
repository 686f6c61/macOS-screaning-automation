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

RELEASE_BUILD="${RELEASE_BUILD:-0}"
SIGNING_IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" && "$RELEASE_BUILD" == "1" ]]; then
  SIGNING_IDENTITY="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null \
    | /usr/bin/awk -F '"' '/Developer ID Application/ { print $2; exit }')"
elif [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null \
    | /usr/bin/awk -F '"' '/Apple Development/ { print $2; exit }')"
fi

if [[ "$RELEASE_BUILD" == "1" && "$SIGNING_IDENTITY" != Developer\ ID\ Application:* ]]; then
  echo "error: RELEASE_BUILD requires a Developer ID Application identity" >&2
  exit 1
fi
if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="-"
fi

sign_item() {
  local item="$1"
  shift
  local args=(--force --sign "$SIGNING_IDENTITY")
  if [[ "$SIGNING_IDENTITY" != "-" ]]; then
    args+=(--options runtime)
  fi
  if [[ "$RELEASE_BUILD" == "1" ]]; then
    args+=(--timestamp)
  fi
  /usr/bin/codesign "${args[@]}" "$@" "$item" >/dev/null
}

if [[ "$SIGNING_IDENTITY" != "-" ]]; then
  SPARKLE_VERSION_DIR="$SPARKLE_DST/Versions/B"
  sign_item "$SPARKLE_VERSION_DIR/XPCServices/Installer.xpc"
  sign_item "$SPARKLE_VERSION_DIR/XPCServices/Downloader.xpc" --preserve-metadata=entitlements
  sign_item "$SPARKLE_VERSION_DIR/Autoupdate"
  sign_item "$SPARKLE_VERSION_DIR/Updater.app"
  sign_item "$SPARKLE_DST"
fi
sign_item "$APP_DIR"

/usr/bin/codesign --verify --deep --strict "$APP_DIR"
if [[ "$RELEASE_BUILD" == "1" ]]; then
  SIGNATURE_DETAILS="$(/usr/bin/codesign -d --verbose=4 "$APP_DIR" 2>&1)"
  /usr/bin/grep -q 'Authority=Developer ID Application:' <<<"$SIGNATURE_DETAILS"
  /usr/bin/grep -Eq 'flags=.*runtime' <<<"$SIGNATURE_DETAILS"
fi

echo "$APP_DIR"
