#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/.build/release/Screening Automation.app"

for variable in APPLE_ID APPLE_TEAM_ID APPLE_APP_PASSWORD; do
  if [[ -z "${!variable:-}" ]]; then
    echo "error: missing $variable" >&2
    exit 1
  fi
done
if [[ ! -d "$APP_DIR" ]]; then
  echo "error: app bundle not found at $APP_DIR" >&2
  exit 1
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/screening-automation-notary.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
NOTARY_ARCHIVE="$WORK_DIR/Screening-Automation-notary.zip"

/usr/bin/ditto -c -k --norsrc --keepParent "$APP_DIR" "$NOTARY_ARCHIVE"
xcrun notarytool submit "$NOTARY_ARCHIVE" \
  --apple-id "$APPLE_ID" \
  --team-id "$APPLE_TEAM_ID" \
  --password "$APPLE_APP_PASSWORD" \
  --wait \
  --timeout 20m
xcrun stapler staple "$APP_DIR"
xcrun stapler validate "$APP_DIR"
/usr/sbin/spctl --assess --type execute --verbose=4 "$APP_DIR"
