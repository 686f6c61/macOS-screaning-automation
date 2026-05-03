#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/.build/release/Screening Automation.app"
"$ROOT_DIR/scripts/build_app.sh" >/dev/null
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")"
ARCHIVE_DIR="$ROOT_DIR/releases"
ARCHIVE_NAME="Screening-Automation-${VERSION}-arm64.zip"
ARCHIVE_PATH="$ARCHIVE_DIR/$ARCHIVE_NAME"
NOTES_PATH="$ARCHIVE_DIR/${ARCHIVE_NAME%.zip}.md"

mkdir -p "$ARCHIVE_DIR"
rm -f "$ARCHIVE_PATH"
"$ROOT_DIR/scripts/extract_release_notes.sh" "$VERSION" > "$NOTES_PATH"
if [[ ! -s "$NOTES_PATH" ]]; then
  printf 'Screening Automation %s\n' "$VERSION" > "$NOTES_PATH"
fi

(
  cd "$(dirname "$APP_DIR")"
  /usr/bin/ditto -c -k --keepParent "$(basename "$APP_DIR")" "$ARCHIVE_PATH"
)

shasum -a 256 "$ARCHIVE_PATH"
echo "$ARCHIVE_PATH"
