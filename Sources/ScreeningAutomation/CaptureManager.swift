// Orquestación de capturas: disparos sueltos y modo armado (ráfaga programada).
//
// La captura en sí la hace `CaptureEngine` en una cola de fondo; aquí solo se
// gestiona el estado visible (mensajes, captura en curso, ráfaga activa).

import AppKit
import Foundation

/// Origen de un disparo de captura. Solo se usa para el diagnóstico.
enum TriggerSource: String {
    case clicks
    case cornerHold = "corner-hold"
    case menu
    case header
    case settings
}

/// Estado observable de las capturas y del modo armado.
@MainActor
final class CaptureManager: ObservableObject {
    /// Función que realiza una captura; los tests inyectan una falsa.
    typealias CaptureExecutor = @Sendable (CaptureRequest) -> Result<URL, Error>

    @Published private(set) var isCapturing = false
    @Published private(set) var lastCaptureURL: URL?
    @Published private(set) var lastMessage = L10n.t("Listo") {
        didSet { lastMessageDate = Date() }
    }
    /// Cuándo cambió `lastMessage`; el menú muestra el mensaje más reciente
    /// entre captura y vídeo.
    private(set) var lastMessageDate = Date.distantPast
    @Published private(set) var lastCaptureSucceeded = false
    @Published private(set) var armedCaptureActive = false
    @Published private(set) var armedCaptureMessage = L10n.t("Modo armado inactivo")

    /// Se llama antes de cada captura (por ejemplo, para ocultar Ajustes).
    var prepareForCapture: (() -> Void)?
    /// Se llama cuando una captura falla por falta de permiso.
    var onScreenRecordingDenied: (() -> Void)?

    /// Una ráfaga del modo armado en curso.
    private struct ArmedBurst {
        let id = UUID()
        let request: CaptureRequest
        let total: Int
        let timer: DispatchSourceTimer
        var remaining: Int
        var inFlight = false

        /// Número (desde 1) de la próxima captura.
        var nextIndex: Int {
            total - remaining + 1
        }
    }

    private let settings: AppSettings
    private let captureExecutor: CaptureExecutor
    /// Pausa antes de capturar para que se oculte la ventana de Ajustes.
    private let captureSettleDelay: TimeInterval
    /// Identifica la captura en curso para descartar resultados que lleguen tarde.
    private var activeCaptureOperationID: UUID?
    private var armedBurst: ArmedBurst? {
        didSet {
            armedCaptureActive = armedBurst != nil
        }
    }
    private let armedActivity = ActivityAssertion(
        reason: "Screening Automation armed capture",
        logName: "armed capture"
    )
    /// `true` si `lastMessage` lo puso la ráfaga y debe actualizarse al acabar.
    private var lastMessageFromArmedBurst = false
    private var didAutoRequestScreenPermission = false

    init(
        settings: AppSettings,
        captureSettleDelay: TimeInterval = 0.22,
        captureExecutor: CaptureExecutor? = nil
    ) {
        self.settings = settings
        self.captureSettleDelay = captureSettleDelay
        self.captureExecutor = captureExecutor ?? CaptureEngine.capture
    }

    // MARK: Captura suelta

    /// Captura la zona configurada. Se ignora si ya hay una captura en curso.
    func captureNow(source: TriggerSource) {
        guard !isCapturing else {
            DiagnosticLog.write("capture skipped source=\(source.rawValue) reason=in-flight")
            return
        }
        guard let request = settings.captureRequest() else {
            reportMissingRegion(context: "capture source=\(source.rawValue)")
            return
        }

        let operationID = beginCapture()
        setMessage(L10n.t("Capturando..."), fromArmedBurst: false)
        prepareForCapture?()
        DiagnosticLog.write("capture started source=\(source.rawValue) size=\(request.region.width)x\(request.region.height)")

        let captureExecutor = captureExecutor
        DispatchQueue.main.asyncAfter(deadline: .now() + captureSettleDelay) {
            DispatchQueue.global(qos: .userInitiated).async {
                let result = captureExecutor(request)
                DispatchQueue.main.async {
                    guard self.endCapture(operationID) else {
                        DiagnosticLog.write("capture completion ignored reason=stale-operation")
                        return
                    }
                    self.apply(result, requestPermissionIfDenied: true)
                }
            }
        }
    }

    // MARK: Modo armado

    /// Arma una ráfaga con los ajustes actuales o, si ya hay una, la cancela.
    func toggleArmedBurst() {
        if armedBurst != nil {
            cancelArmedBurst()
        } else {
            startArmedBurst()
        }
    }

    /// Cancela la ráfaga en curso, si la hay.
    func cancelArmedBurst() {
        guard armedBurst != nil else {
            return
        }
        finishArmedBurst(message: L10n.t("Modo armado cancelado"))
        DiagnosticLog.write("armed burst cancelled")
    }

    private func startArmedBurst() {
        guard let request = settings.captureRequest() else {
            armedCaptureMessage = CaptureError.missingRegion.localizedDescription
            reportMissingRegion(context: "armed burst")
            return
        }

        prepareForCapture?()
        let delay = settings.armedCaptureDelaySeconds
        let interval = settings.armedCaptureIntervalSeconds
        let total = settings.armedCaptureCount

        let timer = DispatchSource.makeTimerSource(queue: .main)
        let burst = ArmedBurst(request: request, total: total, timer: timer, remaining: total)
        armedBurst = burst
        armedCaptureMessage = L10n.format("Armado: espera %@ s", delay.formatted(.number.precision(.fractionLength(1))))
        setMessage(armedCaptureMessage, fromArmedBurst: true)
        armedActivity.begin()
        DiagnosticLog.write("armed burst scheduled delay=\(delay) interval=\(interval) count=\(total)")

        let burstID = burst.id
        timer.schedule(deadline: .now() + delay, repeating: interval, leeway: .milliseconds(80))
        timer.setEventHandler { [weak self] in
            self?.runArmedCaptureTick(burstID: burstID)
        }
        timer.resume()
    }

    private func runArmedCaptureTick(burstID: UUID) {
        guard var burst = armedBurst, burst.id == burstID else {
            return
        }
        guard !burst.inFlight, !isCapturing else {
            DiagnosticLog.write("armed burst tick skipped reason=capture-in-flight")
            return
        }
        guard burst.remaining > 0 else {
            finishArmedBurst(message: L10n.t("Modo armado finalizado"))
            return
        }

        let index = burst.nextIndex
        burst.remaining -= 1
        burst.inFlight = true
        armedBurst = burst
        let operationID = beginCapture()
        armedCaptureMessage = L10n.format("Armado: captura %d/%d", index, burst.total)
        setMessage(armedCaptureMessage, fromArmedBurst: true)
        DiagnosticLog.write("armed burst capture started index=\(index) remaining=\(burst.remaining)")

        let captureExecutor = captureExecutor
        let request = burst.request
        DispatchQueue.global(qos: .userInitiated).async {
            let result = captureExecutor(request)
            DispatchQueue.main.async {
                _ = self.endCapture(operationID)
                self.completeArmedCapture(result, burstID: burstID, index: index)
            }
        }
    }

    private func completeArmedCapture(_ result: Result<URL, Error>, burstID: UUID, index: Int) {
        guard var burst = armedBurst, burst.id == burstID else {
            DiagnosticLog.write("armed burst completion ignored reason=stale-session")
            return
        }
        burst.inFlight = false
        armedBurst = burst

        // El resultado no se marca como mensaje de la ráfaga: debe seguir
        // visible cuando la ráfaga termine. Tampoco se abre el aviso de
        // permiso, que robaría el foco a la app que el usuario está usando.
        let saved = apply(result, requestPermissionIfDenied: false)
        armedCaptureMessage = saved
            ? L10n.format("Armado: guardada %d/%d", index, burst.total)
            : L10n.format("Armado: error %d/%d", index, burst.total)
        DiagnosticLog.write("armed burst capture finished index=\(index) saved=\(saved)")

        // Sin permiso, el resto de capturas fallarían igual: se aborta la
        // ráfaga en lugar de repetir el error y el pitido.
        if case .failure(CaptureError.screenRecordingDenied) = result {
            finishArmedBurst(message: CaptureError.screenRecordingDenied.localizedDescription)
        } else if burst.remaining <= 0 {
            finishArmedBurst(message: L10n.t("Modo armado finalizado"))
        }
    }

    private func finishArmedBurst(message: String) {
        armedBurst?.timer.cancel()
        armedBurst = nil
        armedCaptureMessage = message
        if lastMessageFromArmedBurst {
            setMessage(message, fromArmedBurst: false)
        }
        armedActivity.end()
    }

    // MARK: Estado compartido

    private func beginCapture() -> UUID {
        let operationID = UUID()
        activeCaptureOperationID = operationID
        isCapturing = true
        return operationID
    }

    /// Cierra la captura `operationID` si sigue siendo la vigente.
    private func endCapture(_ operationID: UUID) -> Bool {
        guard activeCaptureOperationID == operationID else {
            return false
        }
        activeCaptureOperationID = nil
        isCapturing = false
        return true
    }

    /// Refleja el resultado de una captura en el estado publicado.
    ///
    /// - Parameter requestPermissionIfDenied: si la captura falla por falta de
    ///   permiso, muestra el aviso del sistema o abre Ajustes (una vez por
    ///   ejecución). Solo para disparos inmediatos del usuario.
    /// - Returns: `true` si se guardó la captura.
    @discardableResult
    private func apply(_ result: Result<URL, Error>, requestPermissionIfDenied: Bool) -> Bool {
        switch result {
        case .success(let url):
            lastCaptureURL = url
            lastCaptureSucceeded = true
            setMessage(L10n.format("Guardado: %@", url.lastPathComponent), fromArmedBurst: false)
            DiagnosticLog.write("capture saved file=\(url.lastPathComponent)")
            return true
        case .failure(let error):
            lastCaptureSucceeded = false
            setMessage(error.localizedDescription, fromArmedBurst: false)
            DiagnosticLog.write("capture failed error=\(error.localizedDescription)")
            NSSound.beep()
            if case CaptureError.screenRecordingDenied = error {
                onScreenRecordingDenied?()
                if requestPermissionIfDenied, !didAutoRequestScreenPermission {
                    didAutoRequestScreenPermission = true
                    ScreenCapturePermission.requestOrOpenSettings()
                }
            }
            return false
        }
    }

    private func setMessage(_ message: String, fromArmedBurst: Bool) {
        lastMessage = message
        lastMessageFromArmedBurst = fromArmedBurst
    }

    private func reportMissingRegion(context: String) {
        lastCaptureSucceeded = false
        setMessage(CaptureError.missingRegion.localizedDescription, fromArmedBurst: false)
        DiagnosticLog.write("\(context) skipped reason=missing-region")
        NSSound.beep()
    }

    /// Muestra en Finder la última captura o, si no hay, la carpeta de salida.
    func revealLastCapture() {
        guard let lastCaptureURL else {
            settings.revealOutputFolder()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([lastCaptureURL])
    }
}
