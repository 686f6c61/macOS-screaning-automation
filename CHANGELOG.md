# Changelog

## 0.4.1 - 2026-10-12

- Las releases se firman con la identidad estable `Screening Automation
  Release` para que macOS conserve los permisos entre actualizaciones; la firma
  `adhoc` anterior cambiaba con cada version y TCC volvia a pedir todos los
  permisos aunque Ajustes los mostrara concedidos.
- La app ya no reabre Ajustes del Sistema tras cada captura fallida y el
  dialogo automatico de permiso de captura se muestra como mucho una vez por
  sesion.
- Corregida la maquetacion de Ajustes: ventana mas alta y redimensionable, las
  cinco secciones visibles, iconos de ayuda junto a su etiqueta y valores
  alineados a la derecha.
- La caja de log de Diagnostico muestra un mensaje cuando no hay eventos.
- Anadido el argumento de arranque `--settings` para abrir Ajustes al lanzar.

## 0.4.0 - 2026-10-11

- Aniadido onboarding de primera ejecucion con tres pasos: zona, permisos y disparadores.
- Aniadida grabacion de video de la zona en MP4 (H.264) con ScreenCaptureKit; se
  detiene desde el menu, al salir de la app o al alcanzar 10 minutos.
- Aniadidos los formatos de salida PDF y TIFF ademas de PNG y JPG.
- Invertida la cadena de captura: ScreenCaptureKit es la via principal y
  `/usr/sbin/screencapture` queda como fallback; retirado el fallback deprecado
  `CGWindowListCreateImage`.
- Aniadido `os.Logger` al lado del log de archivo para diagnostico desde Console.app.
- El panel Diagnostico muestra las ultimas lineas del log con boton de copiar.
- El sondeo de permiso de captura pendiente aplica backoff exponencial de 5 a 30 segundos.
- Interfaz traducida al ingles y al espanol con tablas `.lproj` incluidas en el bundle.

## 0.3.5 - 2026-10-10

- Publicada con firma `adhoc` mediante la variable de repo
  `RELEASE_SIGNING_MODE=adhoc`; el modo `developer-id` (firma, notarizacion y
  Gatekeeper) se restaura cambiando esa variable cuando existan credenciales
  Apple.
- `0.3.4` se preparo pero nunca se publico: su pipeline fallo porque Sparkle
  `2.10` ya no firma el feed completo desde `generate_appcast` y el tag quedo
  inutilizable bajo proteccion. Todos sus cambios se incluyen aqui.

- Aniadido modo armado con espera, intervalo y numero limitado de capturas.
- Blindadas cancelacion y reactivacion mediante IDs de sesion y operacion.
- Corregida la UI para consultar Monitorizacion de entrada en lugar de Accesibilidad.
- Aniadido reintento automatico del event tap al conceder el permiso y reiniciar la app.
- Aniadido `isolated deinit` al monitor de eventos para invalidar el event tap si se libera sin `stop()`.
- Anadido un icono de ayuda junto a cada ajuste que explica su funcion al pasar el puntero.
- Acotada la actividad `latencyCritical` a los holds reales de esquina para reducir el impacto en bateria.
- Eliminado el sondeo de permiso basado en un unico pixel negro.
- Validada la imagen producida por `screencapture` y aniadido timeout con fallbacks.
- Reducidas rutas y coordenadas de logs; directorio y archivos usan `0700/0600`.
- Forzadas las capturas nuevas a `0600` y anadida redaccion defensiva de rutas.
- Eliminado una vez el log historico que podia contener rutas de versiones antiguas.
- Aniadidas quince pruebas para ajustes, permisos, activadores, coordenadas, imagen, privacidad y concurrencia.
- Corregido `Probar activador` para que la simulacion no sea descartada como clics duplicados.
- Actualizado Sparkle a `2.10.0` y activada la firma EdDSA del feed y notas.
- Limitado el appcast a una version completa, sin deltas no publicados ni URLs mutables.
- El generador de appcast falla si falta la clave privada de Sparkle en lugar de publicar un feed sin firma.
- Endurecido el release con Developer ID, Hardened Runtime, timestamp y notarizacion.
- La notarizacion usa un perfil de llavero cuando esta disponible, sin contrasena en argv durante la espera.
- Eliminado `--clobber`; releases, tags y Environment de produccion quedan protegidos.
- Sustituido `sha256 :no_check` por checksums versionados en Homebrew.
- Aniadidos `SECURITY.md`, `CODEOWNERS` y licencia MIT.
- Eliminada la configuracion de Dependabot; las actualizaciones de dependencias pasan a ser manuales.
- Eliminadas las claves obsoletas de Sparkle 1 del `Info.plist` y el codigo muerto del extractor de notas.
- Activado CodeQL con consultas extendidas para Swift, Actions y Ruby.
- Reforzado `.gitignore` para excluir configuracion local, artefactos y material de firma.
- Eliminados metadatos AppleDouble de los ZIP de distribucion y notarizacion.
- Subida la version del bundle a `0.3.4` (`CFBundleVersion` 7).

## 0.3.2 - 2026-05-28

- Redisenado el selector de zona con overlay transparente, lineas discontinuas y contorno mucho mas sutil.
- Eliminado el relleno azul de la region seleccionada para que solo queden bordes y esquinas de referencia.
- Validada la seleccion de zona y una captura real tras el cambio visual.
- Subida la version del bundle a `0.3.2` (`CFBundleVersion` 5).

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
