#!/usr/bin/env bash
# Compila e instala la app en /Applications.
#
# Instala la variante que genere build_app.sh: «Screening Automation.app» si hay
# identidad de release en el llavero, o «Screening Automation Dev.app» si no.
# Nunca sobrescribe la app de release con una compilación de desarrollo, lo que
# rompería los permisos de TCC (ver build_app.sh).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LEGACY_APP_DST="/Applications/Monitor Screening.app"

APP_SRC="$("$ROOT_DIR/scripts/build_app.sh")"
APP_DST="/Applications/$(basename "$APP_SRC")"

# Se copia a un temporal en el mismo volumen y se sustituye después, para no
# quedarse sin app si la copia falla a medias.
STAGING="$(mktemp -d /Applications/.screening-automation-install.XXXXXX)"
trap 'rm -rf "$STAGING"' EXIT
/usr/bin/ditto "$APP_SRC" "$STAGING/$(basename "$APP_SRC")"
/usr/bin/codesign --verify --deep --strict "$STAGING/$(basename "$APP_SRC")" >/dev/null

rm -rf "$APP_DST"
mv "$STAGING/$(basename "$APP_SRC")" "$APP_DST"
if [[ -d "$LEGACY_APP_DST" ]]; then
  rm -rf "$LEGACY_APP_DST"
fi

echo "$APP_DST"
