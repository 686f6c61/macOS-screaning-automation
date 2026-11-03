#!/usr/bin/env bash
# Compila y firma el bundle .app en .build/release.
#
# Elección de identidad de firma (por orden):
#   1. CODESIGN_IDENTITY, si está definida (lo usa CI).
#   2. RELEASE_BUILD=1: la primera identidad «Developer ID Application».
#   3. «Screening Automation Release», si está en el llavero local.
#   4. Variante de desarrollo: «Apple Development» o, si no hay, firma ad hoc.
#
# Por qué existe la variante de desarrollo: TCC (Grabación de pantalla,
# Monitorización de entrada) asocia los permisos al requisito designado, es
# decir, bundle ID + certificado. Si una compilación local con otro certificado
# sobrescribe la app de release con el mismo bundle ID, los interruptores de
# Ajustes siguen encendidos pero dejan de aplicarse y la app pide permisos en
# bucle. La variante de desarrollo usa otro bundle ID y otro nombre, así que
# tiene sus propios permisos y nunca pisa la instalación de release.
#
# Salida: imprime en stdout la ruta del .app generado.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

RELEASE_IDENTITY_NAME="Screening Automation Release"
RELEASE_BUILD="${RELEASE_BUILD:-0}"
SIGNING_IDENTITY="${CODESIGN_IDENTITY:-}"

find_identity() {
  /usr/bin/security find-identity -v -p codesigning 2>/dev/null \
    | /usr/bin/awk -F '"' -v pattern="$1" 'index($2, pattern) == 1 { print $2; exit }'
}

if [[ -z "$SIGNING_IDENTITY" && "$RELEASE_BUILD" == "1" ]]; then
  SIGNING_IDENTITY="$(find_identity "Developer ID Application")"
elif [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="$(find_identity "$RELEASE_IDENTITY_NAME")"
fi

if [[ "$RELEASE_BUILD" == "1" && "$SIGNING_IDENTITY" != Developer\ ID\ Application:* ]]; then
  echo "error: RELEASE_BUILD requires a Developer ID Application identity" >&2
  exit 1
fi

# Sin identidad de release (ni Developer ID ni la autofirmada estable) se genera
# la variante de desarrollo.
VARIANT="release"
if [[ -z "$SIGNING_IDENTITY" ]]; then
  VARIANT="dev"
  SIGNING_IDENTITY="$(find_identity "Apple Development")"
  if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="-"
    echo "warning: no hay identidad de firma; se firma ad hoc. TCC tratará cada compilación como una app nueva y habrá que volver a conceder los permisos." >&2
  fi
fi

if [[ "$VARIANT" == "dev" ]]; then
  APP_NAME="Screening Automation Dev.app"
else
  APP_NAME="Screening Automation.app"
fi

swift build -c release >&2

APP_DIR="$ROOT_DIR/.build/release/$APP_NAME"
BIN_SRC="$ROOT_DIR/.build/release/ScreeningAutomation"
BIN_DST="$APP_DIR/Contents/MacOS/ScreeningAutomation"
SPARKLE_SRC="$ROOT_DIR/.build/release/Sparkle.framework"
SPARKLE_DST="$APP_DIR/Contents/Frameworks/Sparkle.framework"
INFO_PLIST="$APP_DIR/Contents/Info.plist"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$APP_DIR/Contents/Frameworks"
cp "$BIN_SRC" "$BIN_DST"
cp "$ROOT_DIR/Resources/Info.plist" "$INFO_PLIST"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
for LPROJ in "$ROOT_DIR"/Resources/*.lproj; do
  [ -d "$LPROJ" ] && cp -R "$LPROJ" "$APP_DIR/Contents/Resources/"
done
/usr/bin/ditto --norsrc "$SPARKLE_SRC" "$SPARKLE_DST"

if [[ "$VARIANT" == "dev" ]]; then
  BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")"
  /usr/libexec/PlistBuddy \
    -c "Set :CFBundleIdentifier ${BUNDLE_ID}.dev" \
    -c "Set :CFBundleName Screening Automation Dev" \
    -c "Set :CFBundleDisplayName Screening Automation Dev" \
    -c "Set :SUEnableAutomaticChecks false" \
    "$INFO_PLIST"
  echo "info: variante de desarrollo (${BUNDLE_ID}.dev) firmada con: $SIGNING_IDENTITY" >&2
fi

chmod +x "$BIN_DST"

# `disable-library-validation` solo es necesario con certificados sin Team ID
# (autofirmado o ad hoc), porque Sparkle.framework no comparte equipo con el
# binario. Con Developer ID o Apple Development se mantiene la validación.
ENTITLEMENTS="$ROOT_DIR/Resources/Entitlements.plist"
if [[ "$SIGNING_IDENTITY" == "-" || "$SIGNING_IDENTITY" == "$RELEASE_IDENTITY_NAME" ]]; then
  ENTITLEMENTS="$ROOT_DIR/Resources/ReleaseEntitlements.plist"
fi

sign_item() {
  local item="$1"
  shift
  local args=(--force --sign "$SIGNING_IDENTITY")
  if [[ "$SIGNING_IDENTITY" != "-" ]]; then
    args+=(--options runtime)
  fi
  if [[ "$RELEASE_BUILD" == "1" ]]; then
    args+=(--timestamp)
  fi
  /usr/bin/codesign "${args[@]}" "$@" "$item" >/dev/null
}

if [[ "$SIGNING_IDENTITY" != "-" ]]; then
  SPARKLE_VERSION_DIR="$SPARKLE_DST/Versions/B"
  sign_item "$SPARKLE_VERSION_DIR/XPCServices/Installer.xpc"
  sign_item "$SPARKLE_VERSION_DIR/XPCServices/Downloader.xpc" --preserve-metadata=entitlements
  sign_item "$SPARKLE_VERSION_DIR/Autoupdate"
  sign_item "$SPARKLE_VERSION_DIR/Updater.app"
  sign_item "$SPARKLE_DST"
fi
sign_item "$APP_DIR" --entitlements "$ENTITLEMENTS"

/usr/bin/codesign --verify --deep --strict "$APP_DIR"
if [[ "$RELEASE_BUILD" == "1" ]]; then
  SIGNATURE_DETAILS="$(/usr/bin/codesign -d --verbose=4 "$APP_DIR" 2>&1)"
  /usr/bin/grep -q 'Authority=Developer ID Application:' <<<"$SIGNATURE_DETAILS"
  /usr/bin/grep -Eq 'flags=.*runtime' <<<"$SIGNATURE_DETAILS"
fi

echo "$APP_DIR"
