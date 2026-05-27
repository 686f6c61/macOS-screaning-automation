# Security Audit

Fecha: 2026-05-27

Resultado: sin hallazgos criticos abiertos tras los cambios de la version `0.3.1`.

## Alcance

- App nativa macOS de barra de menu: `Screening Automation`.
- Captura de region con `screencapture`, reserva ScreenCaptureKit y reserva CoreGraphics.
- Permisos de Accesibilidad y Grabacion de pantalla.
- Activadores globales por clics y esquina.
- Persistencia local con `UserDefaults`.
- Logs locales en `~/Library/Logs/ScreeningAutomation`.
- Actualizaciones in-app con Sparkle `2.9.2`.
- GitHub Actions para CI y release por tags `v*`.
- Scripts de build, instalacion, empaquetado y appcast.

## Versiones

- Xcode local: `26.5`
- Swift local: `6.3.2`
- Swift language mode: `6`
- Swift tools minimo para CI: `6.1`
- Sparkle: `2.9.2`
- macOS minimo del bundle: `13.0`

## Cambios Aplicados

- Renombrada identidad visible a `SA / Screening Automation`.
- Cambiado bundle ID a `tech.686f6c61.screening-automation`.
- Integrado Sparkle con appcast HTTPS en GitHub Releases.
- Aniadida clave publica EdDSA `SUPublicEDKey`.
- Aniadido workflow de release que solo corre en tags `v*` y exige `SPARKLE_PRIVATE_KEY`.
- Eliminado el reconocimiento de patrones dibujados.
- Eliminada la escucha de eventos de boton derecho.
- Limitada la escucha global a clic izquierdo y comprobacion periodica de esquina.
- Aniadida rotacion del log a 512 KB.
- Retiradas coordenadas exactas de clic del log persistente.
- Aniadida validacion de permiso real de Grabacion de pantalla con ScreenCaptureKit.
- Aniadida reserva de captura con ScreenCaptureKit cuando `screencapture` falla.
- Rechazadas capturas negras o placeholders de privacidad antes de guardarlas como exito.
- Ocultada la ventana de ajustes antes de capturar para evitar autocapturas involuntarias.
- Actualizado Sparkle a `2.9.2`.

## Hallazgos

| ID | Severidad | Estado | Detalle |
| --- | --- | --- | --- |
| SA-001 | Media | Corregido | El codigo antiguo de gesto dibujado seguia escuchando boton derecho aunque la funcion ya no era necesaria. Se elimino. |
| SA-002 | Baja | Corregido | El log podia crecer indefinidamente. Ahora rota a 512 KB. |
| SA-003 | Baja | Corregido | El log persistente guardaba coordenadas exactas de clic. Ahora solo registra backend y eventos de disparo. |
| SA-004 | Informativa | Aceptado | Accesibilidad y Grabacion de pantalla son permisos amplios por diseno de macOS. La app limita su uso a activadores y region configurada. |
| SA-005 | Informativa | Aceptado | La app esta firmada localmente, no notarizada. Para distribuir fuera de esta maquina habria que notarizar. |
| SA-006 | Informativa | Aceptado | Sparkle introduce una conexion HTTPS al appcast de GitHub Releases. Las actualizaciones requieren firma EdDSA. |
| SA-007 | Informativa | Aceptado | El cask usa `sha256 :no_check`; la integridad de actualizaciones queda cubierta por HTTPS de GitHub y firma EdDSA de Sparkle. |
| SA-008 | Media | Corregido | macOS podia devolver imagen negra de privacidad aunque el flujo de captura recibiera un `CGImage`. Ahora se detecta y se rechaza. |
| SA-009 | Baja | Corregido | La ventana de ajustes podia aparecer en la zona capturada si estaba encima de la region. Ahora se oculta antes de capturar. |

## Observaciones de Seguridad

- No hay analytics ni red propia.
- Sparkle consulta `https://github.com/686f6c61/macOS-screaning-automation/releases/latest/download/appcast.xml`.
- `screencapture` se invoca por ruta absoluta y con array de argumentos.
- Las capturas solo se guardan en la carpeta local elegida por el usuario.
- Los fallbacks ScreenCaptureKit y CoreGraphics validan imagen negra probable antes de aceptar el resultado.
- Los permisos se solicitan por APIs del sistema y se muestran en UI como OK/Pendiente.
- El permiso de Grabacion de pantalla se valida contra la capacidad real de listar/capturar contenido, no solo contra `CGPreflightScreenCaptureAccess()`.

## Riesgos Residuales

- Al cambiar bundle ID, macOS puede requerir volver a conceder permisos.
- TCC puede quedar cacheado en estado denegado; el usuario puede necesitar desactivar/activar el permiso y reiniciar la app.
- Cualquier app con permiso de Grabacion de pantalla puede capturar contenido visible; es una concesion amplia del sistema.
- Las capturas pueden contener datos sensibles. La carpeta de salida debe elegirse con cuidado.
- El log puede incluir carpeta de salida, region configurada y estados de permisos.
- Para distribucion publica: Developer ID, hardened runtime, notarizacion y stapling.
- La clave privada EdDSA de Sparkle debe conservarse en el llavero o exportarse a un secreto seguro. Si se pierde, habra que rotar clave mediante una version firmada correctamente.

## Verificacion

- `swift build -c release`: OK
- Build con Swift language mode `6`: OK
- Sparkle `2.9.2` resuelto por SwiftPM: OK
- Bundle instalado en `/Applications/Screening Automation.app`: OK
- Firma local verificada con `codesign --verify --deep --strict`: OK
- El appcast firmado se valida en GitHub Actions con `SPARKLE_PRIVATE_KEY`: cubierto por workflow de release
- ZIP `releases/Screening-Automation-0.3.1-arm64.zip` validado con `unzip -t`: OK
- Cask `packaging/homebrew/screening-automation.rb` validado con `ruby -c`: OK
- Sin crash logs `ScreeningAutomation-*.ips`: OK
- Sin referencias restantes en `Sources/` a `GestureMatcher`, `GesturePoint`, `gestureTemplate`, `armedGesture` ni eventos `rightMouse`.
