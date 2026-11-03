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
APP_BUNDLE="$(basename "$APP_SRC")"
APP_DST="/Applications/$APP_BUNDLE"

# Se copia y verifica en un directorio temporal del mismo volumen; la app
# anterior solo se borra cuando la nueva ya está en su sitio.
STAGING="$(mktemp -d /Applications/.screening-automation-install.XXXXXX)"
trap 'rm -rf "$STAGING"' EXIT
STAGED_APP="$STAGING/$APP_BUNDLE"
/usr/bin/ditto "$APP_SRC" "$STAGED_APP"
/usr/bin/codesign --verify --deep --strict "$STAGED_APP" >/dev/null

if [[ -d "$APP_DST" ]]; then
  mv "$APP_DST" "$STAGING/previous.app"
fi
if ! mv "$STAGED_APP" "$APP_DST"; then
  [[ -d "$STAGING/previous.app" ]] && mv "$STAGING/previous.app" "$APP_DST"
  echo "error: no se pudo instalar $APP_DST; se ha restaurado la versión anterior" >&2
  exit 1
fi
if [[ -d "$LEGACY_APP_DST" ]]; then
  rm -rf "$LEGACY_APP_DST"
fi

echo "$APP_DST"
