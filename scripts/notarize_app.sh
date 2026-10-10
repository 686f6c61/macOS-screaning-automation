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

# A keychain profile keeps the app password out of argv for the whole --wait window
NOTARY_PROFILE="screening-automation-notary"
SUBMIT_ARGS=(--apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD")
if [[ -n "${KEYCHAIN_PATH:-}" && -f "$KEYCHAIN_PATH" ]]; then
  xcrun notarytool store-credentials "$NOTARY_PROFILE" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_PASSWORD" \
    --keychain "$KEYCHAIN_PATH"
  SUBMIT_ARGS=(--keychain-profile "$NOTARY_PROFILE" --keychain "$KEYCHAIN_PATH")
fi
xcrun notarytool submit "$NOTARY_ARCHIVE" "${SUBMIT_ARGS[@]}" \
  --wait \
  --timeout 20m
xcrun stapler staple "$APP_DIR"
xcrun stapler validate "$APP_DIR"
/usr/sbin/spctl --assess --type execute --verbose=4 "$APP_DIR"
