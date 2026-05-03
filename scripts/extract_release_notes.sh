#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <version>" >&2
  exit 64
fi

VERSION="${1#v}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

awk -v version="$VERSION" '
  $0 == "## " version " - 2026-05-03" || $0 ~ ("^## " version "([[:space:]]|-|$)") {
    found = 1
    next
  }
  found && /^## / {
    exit
  }
  found {
    print
  }
' "$ROOT_DIR/CHANGELOG.md" | sed '/^[[:space:]]*$/N;/^\n$/D'
