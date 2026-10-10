# Screening Automation

[![CI](https://github.com/686f6c61/macOS-screaning-automation/actions/workflows/ci.yml/badge.svg)](https://github.com/686f6c61/macOS-screaning-automation/actions/workflows/ci.yml)
[![Release](https://github.com/686f6c61/macOS-screaning-automation/actions/workflows/release.yml/badge.svg)](https://github.com/686f6c61/macOS-screaning-automation/actions/workflows/release.yml)

Screening Automation es una utilidad nativa para la barra de menu de macOS.
Aparece como `SA`, recuerda una zona fija y guarda capturas silenciosas sin
mostrar el selector durante cada captura.

## Estado

- Version preparada en `main`: `0.3.4` (`CFBundleVersion` 7).
- Ultima version publica: `0.3.2`.
- Bundle ID: `tech.686f6c61.screening-automation`.
- macOS minimo: `13.0`.
- Swift tools: `6.1`; Swift language mode: `6`.
- Toolchain local verificado: Xcode `26.6`, Swift `6.3.3`.
- Updater: Sparkle `2.9.4` (ultima version estable comprobada el 2026-07-20),
  archivos y feed firmados con EdDSA.
- Appcast: `https://github.com/686f6c61/macOS-screaning-automation/releases/latest/download/appcast.xml`.
- Las releases hasta `v0.3.2` tienen firma adhoc y no estan notarizadas. `v0.3.4`
  solo debe etiquetarse cuando el Environment `release` tenga Developer ID y
  credenciales de notarizacion validos.

## Instalacion

Homebrew:

```sh
brew install --cask 686f6c61/macOS-screaning-automation/screening-automation
```

O separando el tap:

```sh
brew tap 686f6c61/macOS-screaning-automation
brew install --cask screening-automation
brew upgrade --cask screening-automation
```

El tap real es
`686f6c61/homebrew-macOS-screaning-automation`. Su CI consulta cada seis horas
el cask incluido en la ultima release inmutable y conserva el SHA-256 publicado.
Mientras `v0.3.4` no este firmada y notarizada, la distribucion publica disponible
puede ser rechazada por Gatekeeper.

## Uso

1. Abre `Screening Automation` y localiza `SA` en la barra de menu.
2. Pulsa `Definir zona` y arrastra sobre la region que quieras conservar.
3. Elige carpeta, PNG/JPG y activadores desde `Ajustes`.
4. Captura desde el menu, con la rafaga de clics o manteniendo el puntero en la
   esquina configurada.

Las capturas usan el nombre `SA_yyyy-MM-dd_HH-mm-ss-SSS.png` o `.jpg`.

## Activadores

- `Clics`: dispara al alcanzar el numero configurado dentro de la ventana de tiempo.
- `Esquina`: dispara al mantener el puntero en una esquina durante `N` segundos.
- `Cooldown`: separacion minima entre dos disparos automaticos.
- `Pausar activadores`: detiene clics y esquina sin cerrar la app.
- `Modo armado`: espera el tiempo indicado y realiza una cantidad limitada de
  capturas con un intervalo fijo. Una sesion cancelada no puede modificar la
  siguiente.

El modo armado permite programar la captura antes de entrar en una app que no
entrega eventos globales. No puede eludir la proteccion de contenido de macOS:
ventanas seguras, DRM o video protegido pueden seguir produciendo una imagen
negra, que Screening Automation descarta como error.

## Permisos

macOS controla dos permisos independientes:

- `Monitorizacion de los dispositivos de entrada`: permite escuchar clics
  globales con un event tap pasivo.
- `Grabacion de pantalla`: permite capturar el contenido visible.

La app muestra el estado TCC real separado del backend operativo. Un timer o
monitor activo no se presenta como permiso concedido. La validacion de captura
usa ScreenCaptureKit sin inferir el permiso a partir del color de un unico pixel.
Al conceder Monitorizacion de entrada, macOS debe cerrar y volver a abrir la app
para que el permiso sea efectivo.

## Build local

```sh
./scripts/build_app.sh
./scripts/install_app.sh
open "/Applications/Screening Automation.app"
```

El build local usa una identidad `Apple Development` disponible y firma Sparkle
de dentro hacia fuera con Hardened Runtime. Si no hay identidad, permite firma
adhoc solo para desarrollo. Un build de release nunca degrada a adhoc.

Pruebas y validaciones:

```sh
swift test -Xswiftc -warnings-as-errors
swift build -c release -Xswiftc -warnings-as-errors
bash -n scripts/*.sh
plutil -lint Resources/Info.plist
```

## Releases

`.github/workflows/release.yml` solo acepta tags `v*` que apunten a un commit
alcanzable desde `main` y coincidan con `CFBundleShortVersionString`. El job:

1. Espera aprobacion del Environment protegido `release`.
2. Importa un certificado `Developer ID Application` en un keychain temporal.
3. Firma la app y los componentes de Sparkle con Hardened Runtime y timestamp.
4. Notariza con `notarytool`, adjunta el ticket y exige que Gatekeeper acepte.
5. Firma ZIP, feed y notas con EdDSA; el feed usa URLs del tag y no anuncia deltas no publicados.
6. Genera un cask con SHA-256 y publica un draft que pasa a release inmutable.

Secretos del Environment `release`:

```txt
APPLE_APP_PASSWORD
APPLE_ID
APPLE_TEAM_ID
DEVELOPER_ID_APPLICATION_P12
DEVELOPER_ID_APPLICATION_PASSWORD
KEYCHAIN_PASSWORD
SPARKLE_PRIVATE_KEY
```

Todos deben guardarse como secretos del Environment protegido `release`, nunca
en el repositorio. Un `Personal Team` de Xcode no puede emitir certificados
`Developer ID Application`; hace falta una membresia Apple Developer Program y
un equipo autorizado. El workflow falla antes de publicar si falta un secreto.

Preparacion de una version:

```sh
# Actualizar Resources/Info.plist y CHANGELOG.md primero.
swift test -Xswiftc -warnings-as-errors
git push origin main

# Solo con Developer ID, notarizacion y secretos ya preparados.
git tag vX.Y.Z
git push origin vX.Y.Z
```

Las releases no se reemplazan: no se usa `--clobber`, los tags `v*` estan
protegidos y GitHub Immutable Releases esta habilitado.

## Privacidad y seguridad

- No hay analytics ni servidores propios.
- La unica red de la app es Sparkle sobre HTTPS contra GitHub Releases.
- `/usr/sbin/screencapture` se ejecuta por ruta absoluta y sin shell intermedio.
- ScreenCaptureKit y CoreGraphics actuan como rutas alternativas.
- La captura tiene timeout y elimina archivos parciales o imagenes negras vacias.
- Los logs no guardan carpeta, coordenadas ni ruta completa de las capturas.
- `~/Library/Logs/ScreeningAutomation` usa `0700` y sus logs `0600`.
- Cada PNG/JPG nuevo se fuerza a permisos privados `0600`.
- `.gitignore` excluye configuracion local, artefactos, keychains y material de firma.
- Secret scanning, push protection, Dependabot, CodeQL y reporte privado estan
  activos.

Consulta [SECURITY.md](SECURITY.md) para reportar vulnerabilidades y
[SECURITY_AUDIT.md](SECURITY_AUDIT.md) para la auditoria tecnica.

## Repositorios

- App y releases: `https://github.com/686f6c61/macOS-screaning-automation`.
- Homebrew tap: `https://github.com/686f6c61/homebrew-macOS-screaning-automation`.

## Licencia

MIT. Consulta [LICENSE](LICENSE).
