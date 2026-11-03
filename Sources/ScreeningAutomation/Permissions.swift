// Estado de los permisos de privacidad (TCC) que necesita la app.
//
// - Monitorización de entrada (`ListenEvent`): para los event taps de clics.
// - Grabación de pantalla (`ScreenCapture`): para ScreenCaptureKit y screencapture.
//
// TCC identifica la app por su requisito designado (bundle ID + certificado de
// firma). Si la app se vuelve a firmar con otro certificado, el interruptor de
// Ajustes sigue encendido pero corresponde a la identidad antigua y TCC deniega.
// Ver `scripts/build_app.sh`.
//
// Sobre la detección de Grabación de pantalla: `CGPreflightScreenCaptureAccess`
// puede devolver `false` aunque el permiso esté concedido hasta que se relanza
// la app. Para cubrir ese caso se consulta ScreenCaptureKit, pero con cuidado:
// cada consulta sin permiso válido muestra un aviso del sistema. Por eso se hace
// una sola vez al arrancar y después solo cuando el usuario lo pide; nunca en
// un bucle de fondo.

import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Estado observable de los permisos, refrescado cada segundo con consultas
/// baratas que no muestran avisos.
@MainActor
final class PermissionStatus: ObservableObject {
    typealias PermissionProbe = @Sendable () -> Bool
    typealias AccessProbe = @Sendable () -> ScreenCaptureAccess

    @Published private(set) var inputMonitoringAllowed: Bool
    @Published private(set) var screenCaptureAllowed: Bool

    private let inputMonitoringProbe: PermissionProbe
    private let screenCapturePreflightProbe: PermissionProbe
    private let screenCaptureAccessProbe: AccessProbe
    private var refreshTimer: Timer?
    private var lastLoggedState: (input: Bool, screen: Bool)?
    /// Resultado de la última consulta a ScreenCaptureKit. Solo `.granted`
    /// corrige un preflight negativo; `.unknown` (timeout, pantalla bloqueada)
    /// no se interpreta como denegación.
    private var screenCaptureAccess: ScreenCaptureAccess = .unknown
    /// Último resultado de `CGPreflightScreenCaptureAccess`. Sirve para detectar
    /// el paso de concedido a denegado (permiso retirado en Ajustes) y olvidar
    /// entonces la confirmación de ScreenCaptureKit.
    private var lastPreflight = false
    private var accessCheckInFlight = false
    private var didRunLaunchAccessCheck = false

    /// Número de consultas a ScreenCaptureKit realizadas; útil en tests para
    /// garantizar que no hay sondeo en bucle.
    private(set) var accessCheckCount = 0

    init(
        inputMonitoringProbe: @escaping PermissionProbe = { InputMonitoringPermission.allowed },
        screenCapturePreflightProbe: @escaping PermissionProbe = { ScreenCapturePermission.allowed },
        screenCaptureAccessProbe: @escaping AccessProbe = { ScreenCapturePermission.checkAccess() }
    ) {
        self.inputMonitoringProbe = inputMonitoringProbe
        self.screenCapturePreflightProbe = screenCapturePreflightProbe
        self.screenCaptureAccessProbe = screenCaptureAccessProbe
        inputMonitoringAllowed = inputMonitoringProbe()
        screenCaptureAllowed = screenCapturePreflightProbe()
    }

    /// `true` cuando están concedidos los dos permisos.
    var allAllowed: Bool {
        inputMonitoringAllowed && screenCaptureAllowed
    }

    /// Texto corto para el menú y la ventana de ajustes.
    var summary: String {
        allAllowed ? L10n.t("Permisos OK") : L10n.t("Permisos pendientes")
    }

    /// Empieza a refrescar el estado cada segundo y lanza, una sola vez, la
    /// comprobación de Grabación de pantalla si el preflight es negativo.
    func startMonitoring() {
        refresh()
        if !didRunLaunchAccessCheck {
            didRunLaunchAccessCheck = true
            if !screenCaptureAllowed {
                verifyScreenCaptureAccess()
            }
        }
        guard refreshTimer == nil else {
            return
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    /// Detiene el refresco periódico.
    func stopMonitoring() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    /// Vuelve a leer los permisos con las consultas que no muestran avisos.
    func refresh() {
        let input = inputMonitoringProbe()
        let preflight = screenCapturePreflightProbe()
        if preflight {
            screenCaptureAccess = .granted
        } else if lastPreflight {
            // El preflight pasó de concedido a denegado: el usuario lo retiró
            // en Ajustes. Se olvida la confirmación anterior.
            screenCaptureAccess = .unknown
        }
        lastPreflight = preflight
        let screen = screenCaptureAccess == .granted

        if lastLoggedState?.input != input || lastLoggedState?.screen != screen {
            DiagnosticLog.write("permissions refresh input=\(input) screen=\(screen) preflight=\(preflight) access=\(screenCaptureAccess)")
            lastLoggedState = (input, screen)
        }
        if inputMonitoringAllowed != input {
            inputMonitoringAllowed = input
        }
        if screenCaptureAllowed != screen {
            screenCaptureAllowed = screen
        }
    }

    /// Una captura falló por falta de permiso: deja de darlo por concedido
    /// aunque una consulta anterior lo confirmara.
    func markScreenCaptureDenied() {
        screenCaptureAccess = .denied
        refresh()
    }

    /// Consulta ScreenCaptureKit en segundo plano. Puede mostrar el aviso del
    /// sistema, así que solo debe llamarse al arrancar o por acción del usuario.
    func verifyScreenCaptureAccess() {
        guard !accessCheckInFlight else {
            return
        }
        accessCheckInFlight = true
        accessCheckCount += 1
        let probe = screenCaptureAccessProbe
        Task.detached(priority: .utility) {
            let access = probe()
            await MainActor.run {
                self.accessCheckInFlight = false
                self.screenCaptureAccess = access
                DiagnosticLog.write("screen capture access check result=\(access)")
                self.refresh()
            }
        }
    }
}

/// Resultado de consultar ScreenCaptureKit.
enum ScreenCaptureAccess: Sendable {
    case granted
    case denied
    /// Timeout, pantalla bloqueada u otro error que no permite concluir.
    case unknown
}

/// Permiso de Monitorización de entrada.
enum InputMonitoringPermission {
    static var allowed: Bool {
        CGPreflightListenEventAccess()
    }

    /// Muestra el aviso del sistema (solo la primera vez que TCC no tiene decisión).
    @discardableResult
    static func request() -> Bool {
        CGRequestListenEventAccess()
    }

    static func openSettings() {
        openPrivacyPane(anchor: "Privacy_ListenEvent")
    }
}

/// Permiso de Grabación de pantalla.
enum ScreenCapturePermission {
    /// Consulta sin aviso. Puede dar falsos negativos hasta relanzar la app.
    static var allowed: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Muestra el aviso del sistema (solo la primera vez que TCC no tiene decisión).
    @discardableResult
    static func request() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func openSettings() {
        openPrivacyPane(anchor: "Privacy_ScreenCapture")
    }

    /// Muestra el aviso del sistema o, si TCC ya tiene una decisión (en cuyo
    /// caso `request()` no muestra nada), abre el panel de Ajustes.
    static func requestOrOpenSettings() {
        if !request() {
            openSettings()
        }
    }

    /// Indica si un error de ScreenCaptureKit significa que falta el permiso.
    static func isPermissionDenied(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == SCStreamErrorDomain
            && nsError.code == SCStreamError.Code.userDeclined.rawValue
    }

    /// Mensaje para el usuario que explica qué hacer cuando el error es de permiso.
    static func userFacingMessage(for error: Error) -> String {
        if isPermissionDenied(error) {
            return CaptureError.screenRecordingDenied.localizedDescription
        }
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain, nsError.code == SCStreamError.Code.userStopped.rawValue {
            return L10n.t("Se dejo de compartir la pantalla desde el sistema.")
        }
        return error.localizedDescription
    }

    /// Consulta ScreenCaptureKit de forma síncrona (bloquea hasta 5 s). No
    /// llamar desde el hilo principal.
    static func checkAccess() -> ScreenCaptureAccess {
        if allowed {
            return .granted
        }
        let semaphore = DispatchSemaphore(value: 0)
        let result = LockedBox<ScreenCaptureAccess>(.unknown)
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
            if let error {
                DiagnosticLog.write("screen capture access check error=\(error.localizedDescription)")
                result.set(isPermissionDenied(error) ? .denied : .unknown)
            } else if content?.displays.isEmpty == false {
                result.set(.granted)
            }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 5) == .success else {
            DiagnosticLog.write("screen capture access check timed out")
            return .unknown
        }
        return result.get()
    }
}

/// Abre el panel de Privacidad y seguridad de Ajustes en la sección indicada.
func openPrivacyPane(anchor: String) {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"),
          NSWorkspace.shared.open(url) else {
        DiagnosticLog.write("privacy pane could not be opened anchor=\(anchor)")
        return
    }
}

/// Contenedor protegido por candado para pasar un valor entre el callback de
/// un framework (en una cola arbitraria) y el hilo que espera el resultado.
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func get() -> Value {
        lock.withLock { value }
    }

    func set(_ newValue: Value) {
        lock.withLock { value = newValue }
    }

    /// Sustituye el valor y devuelve el anterior en una sola operación atómica.
    func exchange(_ newValue: Value) -> Value {
        lock.withLock {
            let previous = value
            value = newValue
            return previous
        }
    }
}
