# Changelog

## 0.3.1 - 2026-05-27

- Corregida la deteccion de permiso de Grabacion de pantalla cuando macOS muestra la app como autorizada pero TCC sigue rechazando la captura.
- Aniadido sondeo con ScreenCaptureKit para validar el permiso real de captura y registrar errores TCC utiles en diagnostico.
- Aniadido fallback de captura con ScreenCaptureKit para macOS moderno cuando `/usr/sbin/screencapture` devuelve `could not create image from rect`.
- Evitado guardar capturas negras o placeholders de privacidad como capturas correctas.
- La ventana de ajustes se oculta antes de capturar para que no aparezca dentro de la region.
- El boton de permiso de captura abre Ajustes del Sistema cuando macOS no concede el permiso directamente.
- Actualizado Sparkle a `2.9.2`.
- Subida la version del bundle a `0.3.1` (`CFBundleVersion` 4).

## 0.3.0 - 2026-05-03

- Renombrada la app a `Screening Automation`.
- Ajustado `swift-tools-version` a `6.1` para que GitHub Actions `macos-latest` compile sin bajar el language mode `6`.
- Cambiado el texto de barra de menu de `MS` a `SA`.
- Cambiado el bundle ID a `tech.686f6c61.screening-automation`.
- Cambiados binario, bundle y scripts a `ScreeningAutomation` / `Screening Automation.app`.
- Integrado Sparkle `2.9.1` para `Buscar actualizaciones...` desde la app.
- Aniadido appcast URL: `https://github.com/686f6c61/macOS-screaning-automation/releases/latest/download/appcast.xml`.
- Generada clave publica Sparkle `SUPublicEDKey`; la clave privada queda en el llavero local.
- Aniadidos scripts `package_release.sh` y `generate_appcast.sh`.
- Aniadidos workflows de GitHub Actions para CI y release por tags `v*`.
- Aniadida extraccion automatica de release notes desde `CHANGELOG.md`.
- El workflow de release sube tambien el `.md` de release notes usado por Sparkle.
- Aniadido cask base para el tap `686f6c61/macOS-screaning-automation` con `auto_updates true`.
- Cambiado prefijo de capturas a `SA_`.
- Cambiados logs nuevos a `~/Library/Logs/ScreeningAutomation`.

## 0.2.0 - 2026-05-03

- Cambiado el proyecto a Swift language mode `6` con Xcode `26.4.1` / Swift `6.3.1`.
- Aniadido activador por esquina sin clic: mantener el puntero en una esquina durante `N` segundos.
- Retirado el motor de gesto dibujado y la escucha de eventos de boton derecho.
- Reducida la informacion sensible en logs de eventos de clic.
- Redactadas coordenadas exactas de logs historicos generados durante pruebas locales.
- Aniadida rotacion de logs a 512 KB.
- Mejorada la pantalla de permisos con estado OK/Pendiente y acciones directas.
- Ajustada la ventana de settings para pantallas pequenas con contenido scrollable.
- Subida la version del bundle a `0.2.0` (`CFBundleVersion` 2).
- Aniadidos `README.md`, `CHANGELOG.md` y `SECURITY_AUDIT.md`.

## 0.1.0 - 2026-05-03

- Primera version funcional como app de barra de menu.
- Seleccion persistente de region de pantalla.
- Captura silenciosa de la region configurada en PNG/JPG.
- Carpeta de salida configurable.
- Activador por rafaga de clics.
- Panel de ajustes, diagnostico basico y acceso a permisos de macOS.
