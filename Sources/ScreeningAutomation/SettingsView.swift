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
                HStack {
                    Text(settings.selectedRegion?.summary ?? "Sin zona definida")
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
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
                HStack {
                    Text(settings.outputFolderPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
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

                Picker("Formato", selection: $settings.imageFormat) {
                    ForEach(ImageFormat.allCases) { format in
                        Text(format.label).tag(format)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
            }
            .padding(6)
        }
    }

    private var triggerSection: some View {
        GroupBox("Activador") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Pausar activadores", isOn: $settings.triggersPaused)

                HStack {
                    Stepper("Clics: \(settings.clickCount)", value: $settings.clickCount, in: 2...12)
                    Spacer()
                    Text("\(settings.clickWindowSeconds, specifier: "%.1f") s")
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }
                Slider(value: $settings.clickWindowSeconds, in: 0.4...5.0, step: 0.1)

                HStack {
                    Text("Cooldown")
                    Spacer()
                    Text("\(settings.triggerCooldownSeconds, specifier: "%.1f") s")
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }
                Slider(value: $settings.triggerCooldownSeconds, in: 0.2...15.0, step: 0.1)

                Divider()

                Toggle("Activar por esquina sin clic", isOn: $settings.hoverGestureEnabled)
                HStack {
                    Picker("Esquina", selection: $settings.hoverGestureCorner) {
                        ForEach(HoverGestureCorner.allCases) { corner in
                            Text(corner.label).tag(corner)
                        }
                    }
                    .labelsHidden()
                    Spacer()
                    Text("\(settings.hoverGestureTimeoutSeconds, specifier: "%.1f") s")
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }
                Slider(value: $settings.hoverGestureTimeoutSeconds, in: 0.8...5.0, step: 0.1)
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
                    title: "Activadores de raton",
                    allowed: accessibilityReady,
                    requestTitle: "Solicitar",
                    requestAction: {
                        controller.eventMonitor.requestAccessibilityPermission()
                        permissions.refresh()
                    },
                    settingsAction: controller.eventMonitor.openAccessibilitySettings
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
                    settingsAction: ScreenCapturePermission.openSettings
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
        accessibilityReady && captureReady
    }

    private var accessibilityReady: Bool {
        permissions.accessibilityAllowed || eventMonitor.isRunning
    }

    private var captureReady: Bool {
        permissions.screenCaptureAllowed || captureManager.lastCaptureSucceeded
    }
}

private struct PermissionRow: View {
    var title: String
    var allowed: Bool
    var requestTitle: String
    var requestAction: () -> Void
    var settingsAction: () -> Void

    var body: some View {
        HStack {
            Label(title, systemImage: allowed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(allowed ? .green : .orange)
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
