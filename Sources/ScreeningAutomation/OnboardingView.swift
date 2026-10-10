import SwiftUI

struct OnboardingView: View {
    @ObservedObject private var settings: AppSettings
    @ObservedObject private var permissions: PermissionStatus
    @ObservedObject private var eventMonitor: EventTapMonitor
    private let controller: AppController
    private let onFinish: () -> Void
    @State private var step = 0

    init(controller: AppController, onFinish: @escaping () -> Void) {
        self.controller = controller
        self.onFinish = onFinish
        _settings = ObservedObject(wrappedValue: controller.settings)
        _permissions = ObservedObject(wrappedValue: controller.permissions)
        _eventMonitor = ObservedObject(wrappedValue: controller.eventMonitor)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            stepContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 460, height: 480)
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: "viewfinder")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
            Text("Bienvenido a Screening Automation")
                .font(.title2.bold())
            Text("Configura la app en tres pasos.")
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case 0:
            zoneStep
        case 1:
            permissionsStep
        default:
            triggersStep
        }
    }

    private var zoneStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepTitle(
                L10n.t("Paso 1 de 3 - Zona"),
                L10n.t("Define el rectangulo fijo que se capturara en cada disparo.")
            )
            HStack {
                Text(settings.selectedRegion?.summary ?? L10n.t("Sin zona definida"))
                    .font(.system(.body, design: .monospaced))
                Spacer()
                Button {
                    controller.defineRegion()
                } label: {
                    Label(
                        settings.selectedRegion == nil ? L10n.t("Definir zona") : L10n.t("Redefinir zona"),
                        systemImage: "viewfinder"
                    )
                }
            }
            Text("Podras cambiarla en cualquier momento desde Ajustes o el menu SA.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding()
    }

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepTitle(
                L10n.t("Paso 2 de 3 - Permisos"),
                L10n.t("macOS exige dos permisos para escuchar clics y capturar la pantalla.")
            )
            PermissionRow(
                title: "Monitorizacion de entrada",
                allowed: permissions.inputMonitoringAllowed,
                requestTitle: "Solicitar",
                requestAction: {
                    eventMonitor.requestInputMonitoringPermission()
                    permissions.refresh()
                },
                settingsAction: eventMonitor.openInputMonitoringSettings,
                helpText: HelpText.inputMonitoring
            )
            PermissionRow(
                title: "Captura de pantalla",
                allowed: permissions.screenCaptureAllowed,
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
            Text("Puedes concederlos mas tarde desde Ajustes. Al conceder Monitorizacion de entrada, macOS debe cerrar y volver a abrir la app.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding()
    }

    private var triggersStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepTitle(
                L10n.t("Paso 3 de 3 - Disparadores"),
                L10n.t("Elige como quieres lanzar las capturas de la zona.")
            )
            bullet(icon: "camera", title: L10n.t("Menu SA"), text: L10n.t("Capturar ahora, grabar video de la zona o armar una rafaga."))
            bullet(icon: "hand.tap", title: L10n.t("Rafaga de clics"), text: L10n.t("Cinco clics rapidos (configurable) disparan una captura."))
            bullet(icon: "rectangle.inset.filled", title: L10n.t("Esquina"), text: L10n.t("Mantener el puntero en la esquina elegida durante unos segundos."))
            bullet(icon: "timer", title: L10n.t("Modo armado"), text: L10n.t("Espera inicial y serie de capturas con intervalo fijo."))
            Spacer()
            Text("Todo se ajusta en Ajustes, con iconos de ayuda que explican cada opcion.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private var footer: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(index == step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }
            Spacer()
            if step > 0 {
                Button("Atras") {
                    step -= 1
                }
            }
            if step < 2 {
                Button("Continuar") {
                    step += 1
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(step == 0 && settings.selectedRegion == nil)
            } else {
                Button("Empezar") {
                    onFinish()
                }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }

    private func stepTitle(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func bullet(icon: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .frame(width: 22)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
