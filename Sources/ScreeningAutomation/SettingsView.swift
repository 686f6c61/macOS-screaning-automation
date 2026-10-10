import SwiftUI

struct SettingsView: View {
    @ObservedObject private var settings: AppSettings
    @ObservedObject private var captureManager: CaptureManager
    @ObservedObject private var permissions: PermissionStatus
    @ObservedObject private var eventMonitor: EventTapMonitor
    @ObservedObject private var updater: AppUpdater
    private let controller: AppController

    init(controller: AppController) {
        self.controller = controller
        _settings = ObservedObject(wrappedValue: controller.settings)
        _captureManager = ObservedObject(wrappedValue: controller.captureManager)
        _permissions = ObservedObject(wrappedValue: controller.permissions)
        _eventMonitor = ObservedObject(wrappedValue: controller.eventMonitor)
        _updater = ObservedObject(wrappedValue: controller.updater)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    zoneSection
                    outputSection
                    triggerSection
                    permissionsSection
                    diagnosticsSection
                }
                .padding(.trailing, 8)
            }

            footer
        }
        .padding(16)
        .frame(width: 520, height: 560)
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Screening Automation")
                    .font(.headline.weight(.semibold))
                Text("SA")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            Spacer()
            Button {
                controller.captureNow(source: "header")
            } label: {
                Label("Capturar ahora", systemImage: "camera.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(settings.selectedRegion == nil || captureManager.isCapturing)
        }
    }

    private var zoneSection: some View {
        GroupBox("Zona") {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text(settings.selectedRegion?.summary ?? "Sin zona definida")
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .help(HelpText.zone)
                InfoHint(text: HelpText.zone)
                Spacer()
                    Button {
                        controller.defineRegion()
                    } label: {
                        Label("Definir", systemImage: "viewfinder")
                    }
                    Button {
                        controller.captureNow(source: "settings")
                    } label: {
                        Label("Capturar", systemImage: "camera")
                    }
                    .disabled(settings.selectedRegion == nil || captureManager.isCapturing)
                }
                if let region = settings.selectedRegion {
                    Text(region.displayName)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
            .padding(6)
        }
    }

    private var outputSection: some View {
        GroupBox("Salida") {
            VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text(settings.outputFolderPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(HelpText.outputFolder)
                InfoHint(text: HelpText.outputFolder)
                Spacer()
                    Button {
                        settings.chooseOutputFolder()
                    } label: {
                        Label("Carpeta", systemImage: "folder")
                    }
                    Button {
                        settings.revealOutputFolder()
                    } label: {
                        Label("Abrir", systemImage: "arrow.up.forward.app")
                    }
                }

            HStack(spacing: 4) {
                Picker("Formato", selection: $settings.imageFormat) {
                    ForEach(ImageFormat.allCases) { format in
                        Text(format.label).tag(format)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
                .help(HelpText.imageFormat)
                InfoHint(text: HelpText.imageFormat)
            }
            }
            .padding(6)
        }
    }

    private var triggerSection: some View {
        GroupBox("Activador") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    Toggle("Pausar activadores", isOn: $settings.triggersPaused)
                        .help(HelpText.triggersPaused)
                    InfoHint(text: HelpText.triggersPaused)
                    Spacer()
                }

                HStack(spacing: 4) {
                    Stepper("Clics: \(settings.clickCount)", value: $settings.clickCount, in: 2...12)
                        .help(HelpText.clickCount)
                    InfoHint(text: HelpText.clickCount)
                    Spacer()
                    InfoHint(text: HelpText.clickWindow)
                    Text("\(settings.clickWindowSeconds, specifier: "%.1f") s")
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                        .help(HelpText.clickWindow)
                }
                Slider(value: $settings.clickWindowSeconds, in: 0.4...5.0, step: 0.1)
                    .help(HelpText.clickWindow)

                HStack(spacing: 4) {
                    Text("Cooldown")
                    InfoHint(text: HelpText.cooldown)
                    Spacer()
                    Text("\(settings.triggerCooldownSeconds, specifier: "%.1f") s")
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                        .help(HelpText.cooldown)
                }
                Slider(value: $settings.triggerCooldownSeconds, in: 0.2...15.0, step: 0.1)
                    .help(HelpText.cooldown)

                Divider()

                HStack(spacing: 4) {
                    Toggle("Activar por esquina sin clic", isOn: $settings.hoverGestureEnabled)
                        .help(HelpText.hoverEnabled)
                    InfoHint(text: HelpText.hoverEnabled)
                    Spacer()
                }
                HStack(spacing: 4) {
                    Picker("Esquina", selection: $settings.hoverGestureCorner) {
                        ForEach(HoverGestureCorner.allCases) { corner in
                            Text(corner.label).tag(corner)
                        }
                    }
                    .labelsHidden()
                    .help(HelpText.hoverCorner)
                    InfoHint(text: HelpText.hoverCorner)
                    Spacer()
                    InfoHint(text: HelpText.hoverTimeout)
                    Text("\(settings.hoverGestureTimeoutSeconds, specifier: "%.1f") s")
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                        .help(HelpText.hoverTimeout)
                }
                Slider(value: $settings.hoverGestureTimeoutSeconds, in: 0.8...5.0, step: 0.1)
                    .help(HelpText.hoverTimeout)

                Divider()

                HStack(spacing: 4) {
                    Text("Modo armado")
                    InfoHint(text: HelpText.armedMode)
                    Spacer()
                    Text(captureManager.armedCaptureActive ? "Activo" : "Inactivo")
                        .foregroundStyle(captureManager.armedCaptureActive ? .green : .secondary)
                }

                HStack(spacing: 4) {
                    Text("Espera")
                    InfoHint(text: HelpText.armedDelay)
                    Spacer()
                    Text("\(settings.armedCaptureDelaySeconds, specifier: "%.1f") s")
                        .foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .trailing)
                        .help(HelpText.armedDelay)
                }
                Slider(value: $settings.armedCaptureDelaySeconds, in: 2.0...60.0, step: 1.0)
                    .disabled(captureManager.armedCaptureActive)
                    .help(HelpText.armedDelay)

                HStack(spacing: 4) {
                    Text("Intervalo")
                    InfoHint(text: HelpText.armedInterval)
                    Spacer()
                    Text("\(settings.armedCaptureIntervalSeconds, specifier: "%.1f") s")
                        .foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .trailing)
                        .help(HelpText.armedInterval)
                }
                Slider(value: $settings.armedCaptureIntervalSeconds, in: 0.5...30.0, step: 0.5)
                    .disabled(captureManager.armedCaptureActive)
                    .help(HelpText.armedInterval)

                HStack(spacing: 4) {
                    Stepper(
                        "Capturas: \(settings.armedCaptureCount)",
                        value: $settings.armedCaptureCount,
                        in: 1...120
                    )
                    .disabled(captureManager.armedCaptureActive)
                    .help(HelpText.armedCount)
                    InfoHint(text: HelpText.armedCount)
                    Spacer()
                }

                HStack {
                    Button {
                        if captureManager.armedCaptureActive {
                            captureManager.cancelArmedBurst()
                        } else {
                            captureManager.startArmedBurst()
                        }
                    } label: {
                        Label(
                            captureManager.armedCaptureActive ? "Cancelar" : "Armar rafaga",
                            systemImage: captureManager.armedCaptureActive ? "stop.circle" : "timer"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(settings.selectedRegion == nil)

                    Text(captureManager.armedCaptureMessage)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(6)
        }
    }

    private var permissionsSection: some View {
        GroupBox("Permisos") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(
                        permissionsReady ? "Permisos OK" : "Permisos pendientes",
                        systemImage: permissionsReady ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(permissionsReady ? .green : .orange)
                    Spacer()
                    Button {
                        permissions.refresh()
                    } label: {
                        Label("Actualizar", systemImage: "arrow.clockwise")
                    }
                }
                Divider()
                PermissionRow(
                    title: "Monitorizacion de entrada",
                    allowed: inputMonitoringReady,
                    requestTitle: "Solicitar",
                    requestAction: {
                        controller.eventMonitor.requestInputMonitoringPermission()
                        permissions.refresh()
                    },
                    settingsAction: controller.eventMonitor.openInputMonitoringSettings,
                    helpText: HelpText.inputMonitoring
                )
                PermissionRow(
                    title: "Captura de pantalla",
                    allowed: captureReady,
                    requestTitle: "Solicitar",
                    requestAction: {
                        if !ScreenCapturePermission.request() {
                            ScreenCapturePermission.openSettings()
                        }
                        permissions.refresh()
                    },
                    settingsAction: ScreenCapturePermission.openSettings,
                    helpText: HelpText.screenCapture
                )
            }
            .padding(6)
        }
    }

    private var diagnosticsSection: some View {
        GroupBox("Diagnostico") {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Escucha", value: eventMonitor.backendDescription)
                LabeledContent("Captura", value: captureReady ? "OK" : "Sin validar")
                LabeledContent("Clics", value: eventMonitor.clickProgressDescription)
                LabeledContent("Esquina", value: eventMonitor.cornerHoldProgressDescription)
                LabeledContent("Ultimo evento", value: eventMonitor.lastEventDescription)
                LabeledContent("Ultimo disparo", value: eventMonitor.lastTriggerDescription)
                if !eventMonitor.lastStartError.isEmpty {
                    Text(eventMonitor.lastStartError)
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
                HStack {
                    Button {
                        controller.eventMonitor.simulateClickBurst()
                    } label: {
                        Label("Probar activador", systemImage: "bolt")
                    }
                    Button {
                        DiagnosticLog.reveal()
                    } label: {
                        Label("Log", systemImage: "doc.text.magnifyingglass")
                    }
                    Button {
                        updater.checkForUpdates()
                    } label: {
                        Label("Updates", systemImage: "arrow.down.circle")
                    }
                    .disabled(!updater.canCheckForUpdates)
                }
            }
            .font(.caption)
            .padding(6)
        }
    }

    private var footer: some View {
        HStack {
            Text(captureManager.lastMessage)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button {
                captureManager.revealLastCapture()
            } label: {
                Label("Ultima", systemImage: "doc.viewfinder")
            }
        }
    }

    private var permissionsReady: Bool {
        inputMonitoringReady && captureReady
    }

    private var inputMonitoringReady: Bool {
        permissions.inputMonitoringAllowed
    }

    private var captureReady: Bool {
        permissions.screenCaptureAllowed
    }
}

private struct PermissionRow: View {
    var title: String
    var allowed: Bool
    var requestTitle: String
    var requestAction: () -> Void
    var settingsAction: () -> Void
    var helpText: String

    var body: some View {
        HStack {
            HStack(spacing: 4) {
                Label(title, systemImage: allowed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(allowed ? .green : .orange)
                InfoHint(text: helpText)
            }
            .help(helpText)
            Spacer()
            Text(allowed ? "OK" : "Pendiente")
                .font(.caption.weight(.semibold))
                .foregroundStyle(allowed ? .green : .orange)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background((allowed ? Color.green : Color.orange).opacity(0.12))
                .clipShape(Capsule())
            Button(requestTitle, action: requestAction)
                .disabled(allowed)
            Button {
                settingsAction()
            } label: {
                Label("Ajustes", systemImage: "gearshape")
            }
        }
    }
}

private struct InfoHint: View {
    let text: String

    var body: some View {
        Image(systemName: "info.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(text)
    }
}

private enum HelpText {
    static let zone = "Region fija de la pantalla que se captura en cada disparo. Redefinela con Definir."
    static let outputFolder = "Carpeta del disco donde se guardan las capturas."
    static let imageFormat = "Formato de archivo de las capturas: PNG sin perdidas o JPG mas ligero."
    static let triggersPaused = "Detiene los activadores de clics y de esquina sin cerrar la app. Las capturas manuales del menu siguen funcionando."
    static let clickCount = "Numero de clics necesario para disparar una captura dentro de la ventana de tiempo."
    static let clickWindow = "Segundos maximos en los que deben caer los clics para contar como una rafaga."
    static let cooldown = "Tiempo minimo entre dos disparos automaticos; evita capturas encadenadas."
    static let hoverEnabled = "Dispara una captura al mantener el puntero en la esquina elegida, sin hacer clic."
    static let hoverCorner = "Esquina de la pantalla que activa la captura."
    static let hoverTimeout = "Tiempo que el puntero debe permanecer en la esquina antes de disparar."
    static let armedMode = "Programa una serie de capturas automaticas tras una espera inicial. Util antes de entrar en apps que no entregan eventos globales."
    static let armedDelay = "Segundos de espera antes de comenzar la serie de capturas."
    static let armedInterval = "Separacion en segundos entre las capturas de la serie."
    static let armedCount = "Numero total de capturas de la serie."
    static let inputMonitoring = "Permiso de macOS para escuchar los clics globales con un event tap pasivo."
    static let screenCapture = "Permiso de macOS para capturar el contenido visible de la pantalla."
}
