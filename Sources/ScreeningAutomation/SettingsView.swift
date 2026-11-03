// Ventana de Ajustes: zona, salida, activadores, permisos y diagnóstico.

import SwiftUI

/// Ventana de Ajustes. Observa los modelos de `AppController` y escribe en
/// `AppSettings`, que persiste cada cambio al instante.
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

            if let warning = settings.loadWarning {
                LoadWarningBanner(message: warning, onDismiss: settings.dismissLoadWarning)
            }

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
        .frame(minWidth: 540, idealWidth: 560, minHeight: 600, idealHeight: 680)
    }

    private var canCapture: Bool {
        settings.selectedRegion != nil && !captureManager.isCapturing
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
                controller.captureNow(source: .header)
            } label: {
                Label("Capturar ahora", systemImage: "camera.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canCapture)
        }
    }

    private var zoneSection: some View {
        GroupBox("Zona") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    Text(settings.selectedRegion?.summary ?? L10n.t("Sin zona definida"))
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
                        controller.captureNow(source: .settings)
                    } label: {
                        Label("Capturar", systemImage: "camera")
                    }
                    .disabled(!canCapture)
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
                    Text("Formato")
                    InfoHint(text: HelpText.imageFormat)
                    Spacer()
                    Picker("Formato", selection: $settings.imageFormat) {
                        ForEach(ImageFormat.allCases) { format in
                            Text(format.label).tag(format)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 220)
                    .help(HelpText.imageFormat)
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

                SecondsSliderRow(
                    value: $settings.clickWindowSeconds,
                    range: AppSettings.clickWindowRange,
                    step: 0.1,
                    helpText: HelpText.clickWindow
                ) {
                    Stepper(
                        "Clics: \(settings.clickCount)",
                        value: $settings.clickCount,
                        in: AppSettings.clickCountRange
                    )
                    .help(HelpText.clickCount)
                }

                SecondsSliderRow(
                    "Cooldown",
                    value: $settings.triggerCooldownSeconds,
                    range: AppSettings.triggerCooldownRange,
                    step: 0.1,
                    helpText: HelpText.cooldown
                )

                Divider()

                HStack(spacing: 4) {
                    Toggle("Activar por esquina sin clic", isOn: $settings.hoverGestureEnabled)
                        .help(HelpText.hoverEnabled)
                    InfoHint(text: HelpText.hoverEnabled)
                    Spacer()
                }
                SecondsSliderRow(
                    value: $settings.hoverGestureTimeoutSeconds,
                    range: AppSettings.hoverGestureTimeoutRange,
                    step: 0.1,
                    helpText: HelpText.hoverTimeout
                ) {
                    Picker("Esquina", selection: $settings.hoverGestureCorner) {
                        ForEach(HoverGestureCorner.allCases) { corner in
                            Text(corner.label).tag(corner)
                        }
                    }
                    .labelsHidden()
                    .help(HelpText.hoverCorner)
                }

                Divider()

                armedModeControls
            }
            .padding(6)
        }
    }

    @ViewBuilder
    private var armedModeControls: some View {
        let active = captureManager.armedCaptureActive

        HStack {
            Text("Modo armado")
            InfoHint(text: HelpText.armedMode)
            Spacer()
            Text(active ? L10n.t("Activo") : L10n.t("Inactivo"))
                .foregroundStyle(active ? .green : .secondary)
        }

        SecondsSliderRow(
            "Espera",
            value: $settings.armedCaptureDelaySeconds,
            range: AppSettings.armedCaptureDelayRange,
            step: 1.0,
            helpText: HelpText.armedDelay,
            disabled: active
        )
        SecondsSliderRow(
            "Intervalo",
            value: $settings.armedCaptureIntervalSeconds,
            range: AppSettings.armedCaptureIntervalRange,
            step: 0.5,
            helpText: HelpText.armedInterval,
            disabled: active
        )

        HStack(spacing: 4) {
            Stepper(
                "Capturas: \(settings.armedCaptureCount)",
                value: $settings.armedCaptureCount,
                in: AppSettings.armedCaptureCountRange
            )
            .disabled(active)
            .help(HelpText.armedCount)
            InfoHint(text: HelpText.armedCount)
            Spacer()
        }

        HStack {
            Button {
                captureManager.toggleArmedBurst()
            } label: {
                Label(
                    active ? L10n.t("Cancelar") : L10n.t("Armar rafaga"),
                    systemImage: active ? "stop.circle" : "timer"
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

    private var permissionsSection: some View {
        GroupBox("Permisos") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(
                        permissions.summary,
                        systemImage: permissions.allAllowed ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(permissions.allAllowed ? .green : .orange)
                    Spacer()
                    Button {
                        permissions.refresh()
                    } label: {
                        Label("Actualizar", systemImage: "arrow.clockwise")
                    }
                }
                Divider()
                PermissionRows(controller: controller)
            }
            .padding(6)
        }
    }

    private var diagnosticsSection: some View {
        GroupBox("Diagnostico") {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Escucha", value: eventMonitor.backendDescription)
                LabeledContent(
                    "Captura",
                    value: permissions.screenCaptureAllowed ? L10n.t("OK") : L10n.t("Sin validar")
                )
                LabeledContent("Clics", value: eventMonitor.clickProgressDescription)
                LabeledContent("Esquina", value: eventMonitor.cornerHoldProgressDescription)
                LabeledContent("Ultimo evento", value: eventMonitor.lastEventDescription)
                LabeledContent("Ultimo disparo", value: eventMonitor.lastTriggerDescription)
                if !eventMonitor.lastStartError.isEmpty {
                    Text(eventMonitor.lastStartError)
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
                DiagnosticLogBox()
                HStack {
                    Button {
                        eventMonitor.simulateClickBurst()
                    } label: {
                        Label("Probar activador", systemImage: "bolt")
                    }
                    Button {
                        copyLog()
                    } label: {
                        Label("Copiar log", systemImage: "doc.on.doc")
                    }
                    Button {
                        updater.checkForUpdates()
                    } label: {
                        Label("Actualizaciones", systemImage: "arrow.down.circle")
                    }
                    .disabled(!updater.canCheckForUpdates)
                }
            }
            .font(.caption)
            .padding(6)
        }
    }

    private func copyLog() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            DiagnosticLog.recentLines(200).joined(separator: "\n"),
            forType: .string
        )
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
}

// MARK: - Vistas auxiliares

/// Aviso de que los ajustes guardados no se pudieron leer.
private struct LoadWarningBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
            Spacer()
            Button("Entendido", action: onDismiss)
                .controlSize(.small)
        }
    }
}

/// Últimas líneas del log de diagnóstico.
///
/// Se cargan fuera del hilo principal cada pocos segundos y no en `body`: la
/// ventana de ajustes se vuelve a renderizar con cada cambio publicado por los
/// activadores y leer el archivo en cada pasada bloqueaba la interfaz.
private struct DiagnosticLogBox: View {
    private static let refreshInterval: Duration = .seconds(2)
    @State private var lines: [String] = []

    var body: some View {
        ScrollView {
            Text(lines.isEmpty ? L10n.t("Sin eventos registrados.") : lines.joined(separator: "\n"))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .textSelection(.enabled)
        }
        .frame(maxHeight: 110)
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.25))
        }
        .task {
            while !Task.isCancelled {
                let loaded = await Task.detached(priority: .utility) {
                    DiagnosticLog.recentLines(30)
                }.value
                if loaded != lines {
                    lines = loaded
                }
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
    }
}
