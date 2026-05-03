#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPARKLE_BIN="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin"
UPDATES_DIR="${1:-$ROOT_DIR/releases}"

if [[ ! -x "$SPARKLE_BIN/generate_appcast" ]]; then
  swift build -c release >/dev/null
fi

ARGS=()
if [[ -n "${DOWNLOAD_URL_PREFIX:-}" ]]; then
  ARGS+=(--download-url-prefix "$DOWNLOAD_URL_PREFIX")
fi
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  printf "%s" "$SPARKLE_PRIVATE_KEY" | "$SPARKLE_BIN/generate_appcast" --ed-key-file - "${ARGS[@]}" "$UPDATES_DIR"
else
  "$SPARKLE_BIN/generate_appcast" "${ARGS[@]}" "$UPDATES_DIR"
fi
echo "$UPDATES_DIR/appcast.xml"
