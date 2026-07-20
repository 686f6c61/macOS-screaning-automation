#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: $0 <release-zip> [output-file]" >&2
  exit 64
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZIP_PATH="$1"
OUTPUT_PATH="${2:-$ROOT_DIR/releases/screening-automation.rb}"
APP_PLIST="$ROOT_DIR/.build/release/Screening Automation.app/Contents/Info.plist"

if [[ ! -f "$ZIP_PATH" || ! -f "$APP_PLIST" ]]; then
  echo "error: release ZIP or app metadata missing" >&2
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP_PLIST")"
SHA256="$(/usr/bin/shasum -a 256 "$ZIP_PATH" | /usr/bin/awk '{print $1}')"
mkdir -p "$(dirname "$OUTPUT_PATH")"

{
  printf 'cask "screening-automation" do\n'
  printf '  version "%s"\n' "$VERSION"
  printf '  sha256 "%s"\n\n' "$SHA256"
  printf '  url "https://github.com/686f6c61/macOS-screaning-automation/releases/download/v#{version}/Screening-Automation-#{version}-arm64.zip"\n'
  printf '  name "Screening Automation"\n'
  printf '  desc "Menu bar capture automation for a configured screen region"\n'
  printf '  homepage "https://github.com/686f6c61/macOS-screaning-automation"\n\n'
  printf '  auto_updates true\n\n'
  printf '  app "Screening Automation.app"\n\n'
  printf '  zap trash: [\n'
  printf '    "~/Library/Logs/ScreeningAutomation",\n'
  printf '    "~/Library/Preferences/tech.686f6c61.screening-automation.plist",\n'
  printf '  ]\n'
  printf 'end\n'
} > "$OUTPUT_PATH"

/usr/bin/ruby -c "$OUTPUT_PATH" >/dev/null
echo "$OUTPUT_PATH"
