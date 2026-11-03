// Aserción de actividad del sistema mientras hay trabajo sensible a la latencia.

import Foundation

/// Mientras está activa, pide a macOS que no aplique App Nap ni reduzca la
/// prioridad de los temporizadores. La usan el modo armado (capturas a
/// intervalos fijos) y la detección de esquina (sondeo cada 0,1 s).
///
/// `begin()` y `end()` son idempotentes.
@MainActor
final class ActivityAssertion {
    private let reason: String
    private let logName: String
    private var token: NSObjectProtocol?

    /// - Parameters:
    ///   - reason: motivo que muestra el sistema (p. ej., en `pmset -g assertions`).
    ///   - logName: identificador corto para el log de diagnóstico.
    init(reason: String, logName: String) {
        self.reason = reason
        self.logName = logName
    }

    var isActive: Bool {
        token != nil
    }

    func begin() {
        guard token == nil else {
            return
        }
        token = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: reason
        )
        DiagnosticLog.write("\(logName) activity started")
    }

    func end() {
        guard let token else {
            return
        }
        ProcessInfo.processInfo.endActivity(token)
        self.token = nil
        DiagnosticLog.write("\(logName) activity ended")
    }
}
