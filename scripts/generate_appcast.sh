#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPARKLE_BIN="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin"
UPDATES_DIR="${1:-$ROOT_DIR/releases}"

if [[ ! -x "$SPARKLE_BIN/generate_appcast" ]]; then
  swift build -c release >/dev/null
fi

ARGS=(--maximum-versions 1 --maximum-deltas 0)
if [[ -n "${DOWNLOAD_URL_PREFIX:-}" ]]; then
  ARGS+=(
    --download-url-prefix "$DOWNLOAD_URL_PREFIX"
    --release-notes-url-prefix "${RELEASE_NOTES_URL_PREFIX:-$DOWNLOAD_URL_PREFIX}"
  )
fi
if [[ -z "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  echo "error: SPARKLE_PRIVATE_KEY is required to sign the appcast" >&2
  exit 1
fi
printf "%s" "$SPARKLE_PRIVATE_KEY" | "$SPARKLE_BIN/generate_appcast" --ed-key-file - "${ARGS[@]}" "$UPDATES_DIR"
echo "$UPDATES_DIR/appcast.xml"
