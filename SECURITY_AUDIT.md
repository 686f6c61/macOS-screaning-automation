# Auditoria de codigo, seguridad y buenas practicas

Fecha: 2026-07-20

## Resultado ejecutivo

La app tiene una base pequena y razonablemente legible, usa Swift 6, no contiene
secretos rastreados y protege los ZIP de Sparkle con EdDSA. La distribucion
publica todavia no debe considerarse endurecida porque el artefacto historico
`v0.3.2` esta firmado `adhoc` y Gatekeeper lo rechaza. El pipeline local ya
protege la clave privada mediante un Environment aprobado y tags protegidos.

Resumen de hallazgos detectados en la primera pasada:

| Severidad | Cantidad |
| --- | ---: |
| Critica | 0 |
| Alta | 2 |
| Media | 7 |
| Baja | 3 |

Estado tras la remediacion del mismo dia: once hallazgos estan corregidos y uno
queda preparado pero pendiente de credenciales externas. El unico riesgo que no
puede cerrarse desde el repositorio es `SA-2026-001`: no existe todavia un
certificado Developer ID ni credenciales de notarizacion para producir y probar
el siguiente artefacto publico. El workflow ya impide publicar sin ellos.

## Alcance y estado revisado

- Repo: `686f6c61/macOS-screaning-automation`.
- Rama remota: `main` en `72b49854aa08a9877ae5939376220e35b3aa6f15`.
- Release publicada: `v0.3.2`, de 2026-05-28.
- Sin diferencias entre `HEAD` y `origin/main` al iniciar la auditoria.
- Se preservaron cinco archivos Swift con cambios locales no publicados.
- Se revisaron fuentes Swift, scripts, plist, SwiftPM, workflows, cask, docs,
  configuracion de seguridad del repo y el ZIP publico de `v0.3.2`.

Los hallazgos marcados como "local" afectan al arbol de trabajo actual, pero no
al binario publico `v0.3.2`.

## Hallazgos

### SA-2026-001 - Alta - El binario publico no tiene identidad de distribucion

**Alcance:** publicado y pipeline.

**Estado actual:** Parcial. El build firma componentes de dentro hacia fuera,
activa Hardened Runtime y exige Developer ID, timestamp, notarizacion, stapling y
aceptacion de Gatekeeper. Faltan provisionar el certificado y las credenciales
Apple; por tanto `v0.3.2` sigue siendo adhoc hasta publicar una version nueva.

`scripts/build_app.sh:25-34` elige una identidad `Apple Development` local y,
si no existe, firma con `-` (adhoc). El workflow llama a ese mismo script desde
`.github/workflows/release.yml:47-48`, sin importar un certificado Developer ID.
Ademas, la firma no incluye `--options runtime` ni `--timestamp` y no existe un
paso de notarizacion.

La inspeccion del ZIP publico confirma:

- `Signature=adhoc`, `TeamIdentifier=not set`.
- Requisito designado ligado solo al CDHash del binario.
- `spctl --assess --type execute` devuelve `rejected`.
- `xcrun stapler validate` indica que no hay ticket adjunto.

**Impacto:** Gatekeeper no puede verificar al editor y una recompilacion cambia
la identidad adhoc. En una app que usa Grabacion de pantalla y activadores
globales, esto tambien hace mas fragil la continuidad de permisos TCC entre
instalaciones.

**Correccion:** firmar cada componente de Sparkle y la app de dentro hacia
fuera con `Developer ID Application`, Hardened Runtime y timestamp seguro;
notarizar con `notarytool`, hacer stapling y exigir que `spctl` acepte el ZIP
extraido antes de publicar. El workflow debe fallar si falta cualquier
credencial de distribucion, nunca degradarse a firma adhoc.

### SA-2026-002 - Alta - La clave Sparkle carece de una frontera de release

**Alcance:** configuracion GitHub y pipeline.

**Estado actual:** Corregido. Existe Environment `release` con aprobacion y
politica exclusiva `v*`; la clave Sparkle se migro a ese entorno; Actions solo
permite acciones de GitHub fijadas por SHA; y `main`/tags tienen rulesets activos.

El workflow se activa con cualquier tag `v*`
(`.github/workflows/release.yml:3-6`), expone `SPARKLE_PRIVATE_KEY` a todo el job
(`:22-25`) y usa `actions/checkout@v4` sin fijar SHA (`:27-29`). La comprobacion
en vivo muestra que:

- `main` no tiene branch protection.
- No hay rulesets para ramas o tags.
- No hay GitHub Environment de release ni aprobacion requerida.
- Actions permite cualquier accion y no exige pinning por SHA.
- `SPARKLE_PRIVATE_KEY` es un secreto de repositorio.

**Impacto:** una cuenta con permiso de escritura comprometida puede modificar
el workflow, crear un tag y ejecutar codigo con acceso a la clave que firma las
actualizaciones. La perdida de esta clave permite producir ZIP aceptados por
las instalaciones existentes.

**Correccion:** mover la clave a un Environment `release` con aprobacion manual
y politica de tags; proteger `main` y `v*`; fijar acciones a SHA completo;
limitar las acciones permitidas; usar `persist-credentials: false`; y entregar
el secreto solo al paso de firma. Separar build y firma reduce aun mas la
superficie del secreto.

### SA-2026-003 - Media - Releases y assets se pueden reemplazar

**Alcance:** pipeline y configuracion GitHub.

**Estado actual:** Corregido. Immutable Releases esta activo y el workflow crea
un draft completo, lo publica una sola vez y falla si la release ya existe.
Antes de activar la inmutabilidad se actualizo una sola vez el appcast, las notas
y el cask de `v0.3.2` para firmar el feed y fijar su checksum; el ZIP historico no
se reemplazo y conserva el digest publicado.

`.github/workflows/release.yml:63-77` vuelve a subir ZIP, appcast y notas con
`--clobber` si el release ya existe. GitHub no tiene habilitados releases
inmutables ni reglas para impedir mover tags.

**Impacto:** el contenido asociado a una version publicada puede cambiar sin
cambiar el numero de version. Aunque EdDSA protege el ZIP para Sparkle, esta
mutabilidad debilita Homebrew, descargas manuales, trazabilidad y respuesta a
incidentes.

**Correccion:** habilitar immutable releases, crear el release como borrador,
adjuntar todos los assets y publicarlo una sola vez. El workflow debe fallar si
el tag o release ya existe y debe eliminar `--clobber`.

### SA-2026-004 - Media - Homebrew desactiva la verificacion SHA-256

**Alcance:** publicado.

**Estado actual:** Corregido. El cask local, el tap y la release `v0.3.2`
contienen el hash real. El tap sincroniza cada seis horas desde el cask publicado.

`packaging/homebrew/screening-automation.rb:1-5` usa `sha256 :no_check` para una
URL inmutable y versionada. El SHA-256 real del ZIP `v0.3.2` es
`b31be726d8bb6f7bf3fbcfcca573c7d0477b6692d9620ed83e2ce87a6913593c`.
`README.md:102-104` afirma que Sparkle compensa esta omision, pero Sparkle no
participa en la descarga e instalacion realizada por Homebrew.

**Impacto:** el cask no comprueba que el archivo descargado sea exactamente el
auditado para esa version.

**Correccion:** escribir el hash real en el cask y hacer que el release actualice
el tap con version y hash calculados. Mantener `:no_check` solo cuando obtener un
checksum estable sea realmente imposible.

### SA-2026-005 - Media - La UI puede afirmar que un permiso esta concedido

**Alcance:** publicado y local.

**Estado actual:** Corregido y verificado en compilacion y ejecucion local. La
UI usa los estados TCC reales y muestra el backend operativo por separado en
Diagnostico. La comprobacion visual final requiere conceder Supervision de
entrada a la app instalada.

`Sources/ScreeningAutomation/SettingsView.swift:322-331` consideraba Accesibilidad
correcta si `eventMonitor.isRunning` y Captura correcta si alguna captura previa
tuvo exito. El menu repetia la equivalencia en
`Sources/ScreeningAutomation/ScreeningAutomationApp.swift:209-210`. Sin embargo,
`EventTapMonitor.swift:171-185` marca el monitor como activo incluso si solo
existe el temporizador de polling.

**Impacto:** la app puede mostrar `Permisos OK` cuando `AXIsProcessTrusted()` es
falso o cuando el permiso de captura ya fue revocado. Esto dificulta el
diagnostico y reproduce la discrepancia observada entre la app y Ajustes del
Sistema.

**Correccion:** mostrar por separado el estado TCC real y el estado operativo de
cada backend. La escucha pasiva se comprueba ahora con
`CGPreflightListenEventAccess()` y solicita `CGRequestListenEventAccess()`, que
corresponden a Supervision de entrada; no se usa Accesibilidad como sustituto.
Un temporizador activo debe llamarse `Backend operativo`, no `Permiso OK`. Un
exito historico puede servir de diagnostico, nunca de estado de permiso actual.

### SA-2026-006 - Media - La validacion de permiso e imagen negra es inconsistente

**Alcance:** publicado y local.

**Estado actual:** Corregido. El probe usa disponibilidad de ScreenCaptureKit,
la ruta principal decodifica y valida la imagen, y `screencapture` tiene timeout,
fallbacks y limpieza de parciales. Una captura real de la zona fue correcta.

`Sources/ScreeningAutomation/Permissions.swift:106-139` captura un rectangulo de
`1x1` en `(0,0)` y trata un pixel oscuro como permiso denegado. Ese contenido
puede ser negro de forma legitima. En el extremo contrario,
`CaptureManager.swift:241-281` acepta cualquier archivo producido por
`/usr/sbin/screencapture` con codigo cero sin inspeccion; la deteccion de imagen
negra solo se aplica a los fallbacks (`:287-339`). Esto contradice las garantias
de `README.md:127` y `README.md:153`.

El proceso tampoco tiene timeout: `waitUntilExit()` puede dejar la app en estado
`Capturando...` indefinidamente si la utilidad no termina.

**Impacto:** falsos `Pendiente`, capturas negras aceptadas como exito y posibles
bloqueos operativos.

**Correccion:** decidir el permiso con la API y su error, no por el color de un
pixel. Validar tambien el archivo de la ruta principal, diferenciando una imagen
uniforme legitima de un placeholder de privacidad. Anadir timeout, terminacion
controlada y limpieza del archivo parcial.

### SA-2026-007 - Media - Una captura cancelada puede alterar una rafaga nueva

**Alcance:** solo cambios locales no publicados.

**Estado actual:** Corregido. Cada sesion y operacion tiene identidad propia; las
completions obsoletas se ignoran. Hay prueba automatizada y prueba real de rafaga.

`Sources/ScreeningAutomation/CaptureManager.swift:142-205` cancela el timer y
reinicia todo el estado, incluido `armedCaptureInFlight`, pero no puede cancelar
el trabajo ya enviado a la cola global. Si el usuario vuelve a armar antes de
que termine, la completion antigua modifica contadores, mensajes, URL y estado
de la rafaga nueva. Tambien puede marcar `isCapturing=false` mientras la nueva
sesion esta capturando.

**Impacto:** capturas omitidas, finalizacion anticipada o mensajes y archivos
atribuidos a la rafaga equivocada.

**Correccion:** asignar un UUID/generacion inmutable a cada rafaga y descartar
completions cuyo ID ya no sea el activo. La cancelacion debe impedir nuevas
mutaciones de la sesion antigua y mantener separado el estado de capturas
manuales y programadas.

### SA-2026-008 - Media - No existe una suite de pruebas

**Alcance:** publicado y local.

**Estado actual:** Corregido. Existe un test target con quince pruebas y CI
ejecuta tests y build con warnings tratados como errores.

`Package.swift:20-29` solo define el target ejecutable y
`.github/workflows/ci.yml:24-37` compila y valida sintaxis. `swift test` termina
con `error: no tests found`.

**Impacto:** conversiones multi-monitor, estados TCC, filtrado de imagen negra,
cooldown y concurrencia del modo armado pueden romperse sin que CI lo detecte.

**Correccion:** crear un target de tests y extraer interfaces pequenas para
reloj, capturador y permisos. Cobertura minima: conversion AppKit/Quartz en
varias disposiciones de pantalla, limites de settings, detector de imagen,
cooldown, cancelacion/rearmado y completions obsoletas. CI debe ejecutar
`swift test` y tratar warnings como errores.

### SA-2026-009 - Baja - Mantenimiento de dependencias incompleto

**Alcance:** publicado y configuracion GitHub.

**Estado actual:** Corregido. Sparkle esta en `2.9.4`; Dependabot security updates
y `.github/dependabot.yml` estan activos para SwiftPM y GitHub Actions.

`Package.swift:18` y `Package.resolved:9-10` fijan Sparkle `2.9.2`; la ultima
version comprobada es `2.9.4`. Los dos avisos de seguridad publicados para
Sparkle en mayo de 2026 afectan a versiones `<= 2.9.1`, por lo que `2.9.2` no
esta dentro de esos rangos vulnerables. Aun asi, `2.9.4` corrige la activacion de
ventanas en apps sin Dock, un caso directamente relevante para `LSUIElement`.

GitHub tiene secret scanning y push protection activos, pero Dependabot security
updates esta desactivado y no existe `.github/dependabot.yml`.

**Correccion:** actualizar a Sparkle `2.9.4` despues de pruebas de update e
instalacion; activar Dependabot alerts/security updates y programar revisiones
de SwiftPM y GitHub Actions.

### SA-2026-010 - Baja - El log guarda rutas y coordenadas con permisos implicitos

**Alcance:** publicado y local.

**Estado actual:** Corregido. Los mensajes omiten rutas y coordenadas; el
directorio usa `0700` y el archivo `0600`, comprobados en la app instalada. El
logger tambien redacta rutas defensivamente y cada captura nueva se fuerza a
permisos `0600`.

`Sources/ScreeningAutomation/CaptureManager.swift:72-84` registra zona, carpeta y
ruta completa de cada captura; el modo armado tambien registra el archivo en
`:183`. `Diagnostics.swift:38-47` crea directorio y archivo con los permisos por
defecto del proceso.

**Impacto:** el log revela donde se guardan capturas potencialmente sensibles y
que zona se vigila. El riesgo es local y limitado por los permisos del perfil de
usuario.

**Correccion:** registrar solo nombre de archivo o una ruta redactada, evitar
coordenadas salvo diagnostico opt-in y crear directorio/archivos con `0700/0600`.

### SA-2026-011 - Baja - Faltan controles de gobernanza del repo publico

**Alcance:** repositorio.

**Estado actual:** Corregido. Se anadieron `SECURITY.md`, reporte privado,
`CODEOWNERS`, licencia MIT, Dependabot, CodeQL y documentacion de release
actualizada.

No hay `SECURITY.md` con canal de reporte, licencia, `CODEOWNERS` ni plantilla de
Dependabot. El archivo historico de auditoria tambien declaraba como aceptables
la firma local y `sha256 :no_check`, conclusiones sustituidas por este informe.

**Impacto:** usuarios y colaboradores no tienen reglas claras de uso, reporte de
vulnerabilidades, propiedad de cambios sensibles o mantenimiento.

**Correccion:** anadir una licencia elegida por el propietario, politica de
seguridad con versiones soportadas y contacto privado, y ownership para
workflows, scripts de firma, plist y updater.

### SA-2026-012 - Media - El appcast anuncia assets inexistentes o mutables

**Alcance:** publicado y local.

**Estado actual:** Corregido para la siguiente release. El generador conserva
una sola version completa, desactiva deltas y usa URLs ligadas al tag. El
workflow rechaza feeds con deltas, mas de un item o URLs `latest/download`.

El appcast historico `v0.3.2` contiene deltas y versiones anteriores cuyos siete
enlaces se comprobaron: cinco devuelven `404` y solo el ZIP y las notas de
`0.3.2` responden. Ademas, los deltas generados no formaban parte de los assets
subidos por `.github/workflows/release.yml`.

**Impacto:** Sparkle puede intentar descargar un delta inexistente y tener que
recurrir al ZIP completo. Al cambiar la release marcada como `latest`, los
enlaces historicos dejan de identificar un artefacto estable.

**Correccion:** publicar y validar todos los assets anunciados o, para este
proyecto pequeno, distribuir solo el ZIP completo mas reciente con una URL
inmutable. La segunda opcion reduce superficie y es la implementada.

## Controles positivos verificados

- No se encontraron claves privadas, certificados ni secretos rastreados.
- `.gitignore` cubre claves Sparkle, `p12`, certificados y datos de notarizacion.
- Secret scanning y push protection estan activos en GitHub.
- CodeQL default setup esta activo semanalmente con consultas extendidas para
  Swift, Actions y Ruby y modelo de amenazas remoto y local.
- `screencapture` se invoca por ruta absoluta y argumentos estructurados, sin
  shell ni interpolacion ejecutable.
- Sparkle esta fijado a revision exacta en `Package.resolved`.
- El appcast publico usa HTTPS y el enclosure de `v0.3.2` contiene firma EdDSA.
- Los avisos conocidos consultados para Sparkle afectan versiones anteriores a
  la `2.9.4` fijada por el proyecto.
- El log rota a 512 KB.
- Los workflows usan permisos globales de solo lectura salvo el job de release,
  que declara `contents: write` porque publica assets.
- Los ultimos runs publicos de CI y Release finalizaron correctamente.

## Accion pendiente

Antes de crear el siguiente tag hay que provisionar en el Environment `release`:

- `DEVELOPER_ID_APPLICATION_P12`.
- `DEVELOPER_ID_APPLICATION_PASSWORD`.
- `APPLE_ID`.
- `APPLE_TEAM_ID`.
- `APPLE_APP_PASSWORD`.

`SPARKLE_PRIVATE_KEY` y `KEYCHAIN_PASSWORD` ya estan configurados. El pipeline
falla antes de construir si falta alguna credencial, por lo que no puede volver
a publicar accidentalmente un artefacto adhoc.

La comprobacion en Xcode del 2026-07-20 muestra que la cuenta local pertenece a
un `Personal Team`: el gestor de certificados solo ofrece `Apple Development` y
el llavero no contiene ninguna identidad `Developer ID Application`. Para cerrar
este punto hace falta una membresia Apple Developer Program o un equipo distinto
que ya disponga de capacidad de distribucion.

## Verificacion ejecutada

- `git fetch --prune origin`: OK.
- `git rev-list --left-right --count HEAD...origin/main`: `0 0`.
- `swift build -c release`: OK.
- `swift test -Xswiftc -warnings-as-errors`: 15 pruebas, OK.
- `bash -n scripts/*.sh`: OK.
- `plutil -lint Resources/Info.plist`: OK.
- `ruby -c packaging/homebrew/screening-automation.rb`: OK.
- `swift package dump-package`: OK.
- `git diff --check`: OK.
- `actionlint`: workflows y metadata de Actions, OK.
- ZIP publico descargado desde GitHub: hash coincide con el digest del asset y
  `unzip` es valido. El ZIP local ignorado en `releases/` no se usa como prueba.
- Feed y notas publicas `v0.3.2`: firma EdDSA verificada.
- Dry run del siguiente appcast: un item, URL de tag, sin deltas y firma valida.
- Homebrew: descarga `0.3.2` y verifica el SHA-256, OK.
- App local: Hardened Runtime y firma Apple Development, OK.
- Captura manual real: imagen correcta, OK.
- Modo armado real: captura y cancelacion, OK.
- Sparkle desde la app: `Estas al dia`, sin error de feed, OK.
- CI del tap Homebrew: OK.
- CodeQL inicial sobre `main`: Swift, Actions y Ruby, OK; cero alertas abiertas.

CodeQL ha analizado el `main` remoto en `72b4985`; los cambios locales de esta
remediacion se analizaran automaticamente en su primer push o pull request.

No se creo tag ni release nueva durante la remediacion. El artefacto publico
seguira siendo adhoc hasta disponer de Developer ID y ejecutar el nuevo pipeline.

## Fuentes oficiales

- Apple, notarizacion: https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
- Apple, Hardened Runtime: https://developer.apple.com/documentation/security/hardened-runtime
- GitHub, uso seguro de Actions: https://docs.github.com/en/actions/reference/security/secure-use
- GitHub, releases inmutables: https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases
- Apple, permiso de supervision de entrada: https://developer.apple.com/documentation/coregraphics/cgpreflightlisteneventaccess%28%29
- Sparkle, feeds firmados: https://sparkle-project.org/documentation/customization/
- GitHub, Dependabot: https://docs.github.com/en/code-security/how-tos/secure-your-supply-chain/secure-your-dependencies/configure-security-updates
- Homebrew, Cask Cookbook: https://docs.brew.sh/Cask-Cookbook
- Sparkle, documentacion: https://sparkle-project.org/documentation/
- Sparkle `2.9.4`: https://github.com/sparkle-project/Sparkle/releases/tag/2.9.4
