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

# Se copia y verifica en un directorio temporal del mismo volumen.
STAGING="$(mktemp -d /Applications/.screening-automation-install.XXXXXX)"
trap 'rm -rf "$STAGING"' EXIT
STAGED_APP="$STAGING/$APP_BUNDLE"
/usr/bin/ditto "$APP_SRC" "$STAGED_APP"
/usr/bin/codesign --verify --deep --strict "$STAGED_APP" >/dev/null

# La app anterior se aparta fuera del directorio temporal (que el trap borra)
# y solo se elimina cuando la nueva ya está en su sitio.
PREVIOUS_APP=""
if [[ -d "$APP_DST" ]]; then
  PREVIOUS_APP="$(mktemp -d /Applications/.screening-automation-previous.XXXXXX)/$APP_BUNDLE"
  mv "$APP_DST" "$PREVIOUS_APP"
fi
if ! mv "$STAGED_APP" "$APP_DST"; then
  if [[ -n "$PREVIOUS_APP" ]] && mv "$PREVIOUS_APP" "$APP_DST"; then
    echo "error: no se pudo instalar $APP_DST; se ha restaurado la versión anterior" >&2
  else
    echo "error: no se pudo instalar $APP_DST; la versión anterior está en $PREVIOUS_APP" >&2
  fi
  exit 1
fi
if [[ -n "$PREVIOUS_APP" ]]; then
  rm -rf "$(dirname "$PREVIOUS_APP")"
fi
if [[ -d "$LEGACY_APP_DST" ]]; then
  rm -rf "$LEGACY_APP_DST"
fi

echo "$APP_DST"
