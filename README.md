# Screening Automation

[![CI](https://github.com/686f6c61/macOS-screaning-automation/actions/workflows/ci.yml/badge.svg)](https://github.com/686f6c61/macOS-screaning-automation/actions/workflows/ci.yml)
[![Release](https://github.com/686f6c61/macOS-screaning-automation/actions/workflows/release.yml/badge.svg)](https://github.com/686f6c61/macOS-screaning-automation/actions/workflows/release.yml)

Screening Automation es una utilidad nativa de macOS para la barra de menu. Aparece como `SA`, permite definir una zona fija de pantalla y guarda capturas de esa zona sin mostrar lineas de recorte ni selector visible durante la captura.

## Estado

- Version: `0.3.1`
- App instalada: `/Applications/Screening Automation.app`
- Bundle ID: `tech.686f6c61.screening-automation`
- Repo GitHub: `686f6c61/macOS-screaning-automation`
- Tap previsto: `686f6c61/macOS-screaning-automation`
- Appcast Sparkle: `https://github.com/686f6c61/macOS-screaning-automation/releases/latest/download/appcast.xml`
- Toolchain local usado: Xcode `26.5`, Swift `6.3.2`, Swift language mode `6`
- Swift tools minimo para CI: `6.1`
- Updater: Sparkle `2.9.2`
- macOS minimo: `13.0`

## GitHub About

Descripcion sugerida:

```txt
Native macOS menu bar app for silent, fixed-region screen capture automation.
```

Topics sugeridos:

```txt
macos, swift, swiftui, screen-capture, menu-bar, sparkle, automation, productivity, homebrew-cask, screening-automation
```

## Uso Rapido

1. Ejecuta `./scripts/install_app.sh`.
2. Abre `/Applications/Screening Automation.app`.
3. En el menu `SA`, pulsa `Definir zona` y marca la region una sola vez.
4. En `Ajustes`, elige carpeta, formato y activadores.
5. Usa `Capturar ahora`, los clics configurados, o deja el puntero en la esquina configurada durante los segundos elegidos.

Las capturas se guardan como `SA_yyyy-MM-dd_HH-mm-ss-SSS.png` o `.jpg` en la carpeta configurada.

## Activadores

- Esquina sin clic: deja el puntero quieto en la esquina configurada durante `N` segundos.
- Clics: realiza el numero configurado de clics dentro de la ventana de tiempo elegida.
- Cooldown: tiempo minimo entre capturas automaticas. Evita dobles disparos accidentales.
- Pausa: `Pausar activadores` desactiva clics y esquina sin cerrar la app.

## Actualizaciones

La app integra Sparkle. Desde el menu `SA` o desde `Ajustes > Diagnostico` se puede usar `Buscar actualizaciones...`.

Flujo local de release:

```sh
./scripts/package_release.sh
./scripts/generate_appcast.sh
```

Despues se suben a GitHub Releases, en el repo `686f6c61/macOS-screaning-automation`:

- `Screening-Automation-<version>-arm64.zip`
- `appcast.xml`
- release notes/changelog

## Release con GitHub Actions

El repo incluye `.github/workflows/release.yml`. El workflow se ejecuta solo con tags `v*`, valida que el tag coincide con `CFBundleShortVersionString`, genera el ZIP, firma el `appcast.xml` con Sparkle y publica la GitHub Release.

Secret requerido en `Settings > Secrets and variables > Actions`:

```txt
SPARKLE_PRIVATE_KEY
```

Exportacion local de la clave:

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle_private_key.txt
```

Publicacion:

```sh
git tag v0.3.1
git push origin v0.3.1
```

El Homebrew tap previsto es:

```sh
brew tap 686f6c61/macOS-screaning-automation
brew install --cask screening-automation
brew upgrade --cask screening-automation
```

Para que ese comando funcione con la forma corta de Homebrew, el repo del tap debe llamarse `686f6c61/homebrew-macOS-screaning-automation`. El repo de releases/appcast de la app queda como `686f6c61/macOS-screaning-automation`.

El cask base esta en `packaging/homebrew/screening-automation.rb`.
Incluye `auto_updates true` porque la app tambien puede actualizarse por Sparkle.
Usa `sha256 :no_check` porque el ZIP se genera en CI y Sparkle valida la actualizacion con firma EdDSA.

La clave privada de Sparkle esta guardada en el llavero local. Para mover el proceso a CI hay que exportarla a un secreto seguro con:

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle_private_key.txt
```

No subas ese archivo al repo. En CI, `generate_appcast` puede recibirla con `--ed-key-file -` desde una variable secreta.

## Repos

- App y releases: `https://github.com/686f6c61/macOS-screaning-automation`
- Tap Homebrew: `https://github.com/686f6c61/homebrew-macOS-screaning-automation`

## Permisos

macOS requiere:

- Accesibilidad: ayuda a escuchar activadores globales de raton. La app tambien puede usar escucha AppKit/HID cuando macOS lo permite.
- Grabacion de pantalla: necesaria para capturar la region seleccionada.

Al cambiar el nombre y bundle ID de `Monitor Screening` a `Screening Automation`, macOS puede pedir conceder permisos de nuevo.
Si Ajustes del Sistema muestra el permiso activado pero la app indica `Pendiente`, desactiva y activa de nuevo `Screening Automation`, cierra la app y vuelve a abrirla. La app valida el permiso real con ScreenCaptureKit y rechaza capturas negras de privacidad.

## Build e Instalacion

Build local:

```sh
./scripts/build_app.sh
open ".build/release/Screening Automation.app"
```

Instalacion en `/Applications`:

```sh
./scripts/install_app.sh
open "/Applications/Screening Automation.app"
```

El script firma la app con la primera identidad `Apple Development` disponible. Para distribuir publicamente conviene usar Developer ID, hardened runtime y notarizacion.

## Privacidad y Seguridad

- No usa analytics ni servidores propios.
- La unica conexion prevista es la consulta HTTPS de Sparkle al appcast de GitHub Releases.
- La captura se realiza con `/usr/sbin/screencapture` usando argumentos directos, sin shell intermedio, y usa ScreenCaptureKit como reserva en macOS moderno.
- La app oculta su ventana de ajustes antes de capturar para no incluirla en la region seleccionada.
- Las capturas negras devueltas por privacidad/TCC se descartan y se muestran como error.
- Los logs estan en `~/Library/Logs/ScreeningAutomation/ScreeningAutomation.log`.
- El log rota al superar 512 KB y conserva una copia `ScreeningAutomation.log.1`.

La auditoria esta en `SECURITY_AUDIT.md`.
