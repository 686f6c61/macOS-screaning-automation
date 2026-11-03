// Componentes de SwiftUI compartidos por Ajustes y la bienvenida (onboarding).

import SwiftUI

/// Las dos filas de permisos (Monitorización de entrada y Grabación de
/// pantalla) con su estado y sus acciones. Ajustes y la bienvenida usan esta
/// misma vista para que el flujo de permisos, el más delicado en macOS, viva en
/// un solo sitio.
struct PermissionRows: View {
    @ObservedObject private var permissions: PermissionStatus
    private let controller: AppController

    init(controller: AppController) {
        self.controller = controller
        _permissions = ObservedObject(wrappedValue: controller.permissions)
    }

    var body: some View {
        PermissionRow(
            title: L10n.t("Monitorizacion de entrada"),
            allowed: permissions.inputMonitoringAllowed,
            requestAction: controller.requestInputMonitoring,
            settingsAction: InputMonitoringPermission.openSettings,
            helpText: HelpText.inputMonitoring
        )
        PermissionRow(
            title: L10n.t("Captura de pantalla"),
            allowed: permissions.screenCaptureAllowed,
            requestAction: controller.requestScreenCapture,
            settingsAction: ScreenCapturePermission.openSettings,
            helpText: HelpText.screenCapture
        )
    }
}

/// Una fila de permiso: estado, botón para solicitarlo y acceso a Ajustes.
struct PermissionRow: View {
    /// Título ya localizado.
    var title: String
    var allowed: Bool
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
            Text(allowed ? L10n.t("OK") : L10n.t("Pendiente"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(allowed ? .green : .orange)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background((allowed ? Color.green : Color.orange).opacity(0.12))
                .clipShape(Capsule())
            Button(L10n.t("Solicitar"), action: requestAction)
                .disabled(allowed)
            Button(action: settingsAction) {
                Label("Ajustes", systemImage: "gearshape")
            }
        }
    }
}

/// Título con ayuda, valor en segundos a la derecha y deslizador debajo.
///
/// El rango debe venir de `AppSettings` (`...Range`) para que la interfaz y el
/// acotado al cargar los ajustes no se desincronicen.
struct SecondsSliderRow<Leading: View>: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let helpText: String
    var disabled = false
    @ViewBuilder let leading: () -> Leading

    var body: some View {
        HStack(spacing: 4) {
            leading()
            InfoHint(text: helpText)
            Spacer()
            Text("\(value, specifier: "%.1f") s")
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
                .help(helpText)
        }
        Slider(value: $value, in: range, step: step)
            .disabled(disabled)
            .help(helpText)
    }
}

extension SecondsSliderRow where Leading == Text {
    /// Variante con un título de texto (clave de localización).
    init(
        _ title: LocalizedStringKey,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        helpText: String,
        disabled: Bool = false
    ) {
        self.init(value: value, range: range, step: step, helpText: helpText, disabled: disabled) {
            Text(title)
        }
    }
}

/// Icono de información con el texto de ayuda como tooltip.
struct InfoHint: View {
    let text: String

    var body: some View {
        Image(systemName: "info.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(text)
    }
}

/// Textos de ayuda (tooltips) de cada opción, ya localizados.
enum HelpText {
    static let zone = L10n.t("Region fija de la pantalla que se captura en cada disparo. Redefinela con Definir.")
    static let outputFolder = L10n.t("Carpeta del disco donde se guardan las capturas.")
    static let imageFormat = L10n.t("Formato de archivo de las capturas: PNG sin perdidas, JPG mas ligero, PDF o TIFF.")
    static let triggersPaused = L10n.t("Detiene los activadores de clics y de esquina sin cerrar la app. Las capturas manuales del menu siguen funcionando.")
    static let clickCount = L10n.t("Numero de clics necesario para disparar una captura dentro de la ventana de tiempo.")
    static let clickWindow = L10n.t("Segundos maximos en los que deben caer los clics para contar como una rafaga.")
    static let cooldown = L10n.t("Tiempo minimo entre dos disparos automaticos; evita capturas encadenadas.")
    static let hoverEnabled = L10n.t("Dispara una captura al mantener el puntero en la esquina elegida, sin hacer clic.")
    static let hoverCorner = L10n.t("Esquina de la pantalla que activa la captura.")
    static let hoverTimeout = L10n.t("Tiempo que el puntero debe permanecer en la esquina antes de disparar.")
    static let armedMode = L10n.t("Programa una serie de capturas automaticas tras una espera inicial. Util antes de entrar en apps que no entregan eventos globales.")
    static let armedDelay = L10n.t("Segundos de espera antes de comenzar la serie de capturas.")
    static let armedInterval = L10n.t("Separacion en segundos entre las capturas de la serie.")
    static let armedCount = L10n.t("Numero total de capturas de la serie.")
    static let inputMonitoring = L10n.t("Permiso de macOS para escuchar los clics globales con un event tap pasivo.")
    static let screenCapture = L10n.t("Permiso de macOS para capturar el contenido visible de la pantalla.")
}
