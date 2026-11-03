// Grabación de vídeo de la zona seleccionada.
//
// Piezas:
// - `VideoRegionResolver` traduce la zona (coordenadas Quartz globales) a una
//   pantalla concreta y a un rectángulo local de esa pantalla.
// - `VideoWriterSession` encapsula `AVAssetWriter` y solo se toca desde su cola
//   serie, que es también la cola donde ScreenCaptureKit entrega los fotogramas.
// - `VideoCaptureSource` / `VideoCaptureHandle` abstraen ScreenCaptureKit para
//   que la máquina de estados de `VideoRecorder` se pueda probar sin pantalla
//   ni permisos. La implementación real es `ScreenCaptureVideoSource`.
// - `VideoRecorder` (MainActor) orquesta el ciclo de vida con una máquina de
//   estados explícita.

import AppKit
import AVFoundation
import Combine
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

// MARK: - Resolución de la zona

/// Describe una pantalla física en coordenadas Quartz globales.
struct VideoRegionDescriptor {
    var displayID: CGDirectDisplayID
    var quartzBounds: CGRect
    var scale: CGFloat
}

/// Localiza la pantalla que contiene una zona de captura.
enum VideoRegionResolver {
    /// Devuelve la pantalla cuyo rectángulo contiene el centro de la zona, junto
    /// con la zona expresada en coordenadas locales de esa pantalla.
    ///
    /// - Returns: `nil` si el centro de la zona no cae en ninguna pantalla.
    static func resolve(
        region: CaptureRegion,
        descriptors: [VideoRegionDescriptor]
    ) -> (displayID: CGDirectDisplayID, localRect: CGRect, scale: CGFloat)? {
        let center = CGPoint(
            x: CGFloat(region.x) + CGFloat(region.width) / 2,
            y: CGFloat(region.y) + CGFloat(region.height) / 2
        )
        for descriptor in descriptors where descriptor.quartzBounds.contains(center) {
            let localRect = CGRect(
                x: CGFloat(region.x) - descriptor.quartzBounds.minX,
                y: CGFloat(region.y) - descriptor.quartzBounds.minY,
                width: CGFloat(region.width),
                height: CGFloat(region.height)
            )
            return (descriptor.displayID, localRect, descriptor.scale)
        }
        return nil
    }
}

// MARK: - Escritura del archivo

/// Fallos posibles al escribir el archivo de vídeo.
enum VideoWriterError: Error, Equatable, LocalizedError {
    /// No se pudo crear el `AVAssetWriter` (ruta no escribible, archivo existente...).
    case cannotCreate(String)
    /// El códec no acepta la configuración solicitada.
    case unsupportedSettings
    /// Se detuvo la grabación sin recibir ningún fotograma completo.
    case noFrames
    /// El escritor falló antes de escribir el primer fotograma.
    case couldNotStart(String)
    /// `AVAssetWriter` falló durante la escritura o el cierre.
    case writerFailed(String)
    /// El cierre no terminó dentro del tope; puede completarse más tarde.
    case timedOut

    var errorDescription: String? {
        switch self {
        case .cannotCreate(let reason):
            return L10n.format("No se pudo preparar el archivo de video: %@", reason)
        case .unsupportedSettings:
            return L10n.t("El codificador no admite el tamano de la zona.")
        case .noFrames:
            return L10n.t("No se recibio ningun fotograma de la pantalla.")
        case .couldNotStart(let reason):
            return L10n.format("No se pudo iniciar la escritura del video: %@", reason)
        case .writerFailed(let reason):
            return L10n.format("La grabacion no se pudo guardar: %@", reason)
        case .timedOut:
            return L10n.t("El cierre del video esta tardando mas de lo normal.")
        }
    }

    /// `true` si el error implica que no hay nada útil en disco. Un MP4 sin
    /// cerrar no se puede reproducir; solo se conserva si el cierre venció el
    /// tope, porque aún puede completarse.
    var leavesNoFile: Bool {
        switch self {
        case .cannotCreate, .unsupportedSettings, .noFrames, .couldNotStart, .writerFailed:
            return true
        case .timedOut:
            return false
        }
    }
}

/// Envoltorio de `AVAssetWriter` para una grabación H.264 en MP4.
///
/// Contrato de hilos: `append(_:)` y los cuerpos de `finish(completion:)` y
/// `discard(completion:)` se ejecutan siempre en `queue`. Por eso la clase es
/// `@unchecked Sendable`: todo el estado mutable se serializa en esa cola.
final class VideoWriterSession: @unchecked Sendable {
    /// Lado máximo que aceptan los codificadores H.264 de Apple.
    static let maxEncoderDimension = 4096

    let queue = DispatchQueue(label: "tech.686f6c61.screening-automation.video-writer")

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let onFailure: (@Sendable (String) -> Void)?
    private var startedSession = false
    /// Tras `finish` o `discard` se ignoran los fotogramas que aún lleguen,
    /// para que ninguno arranque el escritor y recree el archivo.
    private var isClosed = false
    private var droppedFrames = 0
    private var failureReason: String?

    /// Prepara el escritor. No crea el archivo hasta recibir el primer fotograma.
    ///
    /// - Parameter onFailure: se llama una sola vez, desde `queue`, si el
    ///   escritor falla durante la grabación, para poder detenerla y avisar en
    ///   vez de seguir «grabando» sin escribir nada.
    /// - Throws: `VideoWriterError.cannotCreate` o `.unsupportedSettings`.
    init(
        url: URL,
        pixelWidth: Int,
        pixelHeight: Int,
        onFailure: (@Sendable (String) -> Void)? = nil
    ) throws {
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        } catch {
            throw VideoWriterError.cannotCreate(error.localizedDescription)
        }
        // No se usa `movieFragmentInterval`: con las marcas de tiempo del reloj
        // del sistema que entrega ScreenCaptureKit, el escritor MP4 fragmentado
        // falla al escribir la cabecera (`MovieHeaderMaker` err -16341) a los
        // pocos segundos. Lo cubre `testRecordingWithHostClockTimestamps`.

        let outputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: pixelWidth,
            AVVideoHeightKey: pixelHeight
        ]
        guard writer.canApply(outputSettings: outputSettings, forMediaType: .video) else {
            throw VideoWriterError.unsupportedSettings
        }
        input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw VideoWriterError.unsupportedSettings
        }
        writer.add(input)
        self.onFailure = onFailure
    }

    /// Ajusta un tamaño en píxeles a lo que admite H.264: lados pares y el lado
    /// mayor limitado a `maxEncoderDimension`, conservando la proporción.
    static func encoderSize(width: Int, height: Int) -> (width: Int, height: Int) {
        let longest = max(width, height, 1)
        let factor = min(1, Double(maxEncoderDimension) / Double(longest))
        func even(_ value: Int) -> Int {
            max(2, Int((Double(value) * factor).rounded(.down)) & ~1)
        }
        return (even(width), even(height))
    }

    /// Añade un fotograma. Debe llamarse en `queue`.
    ///
    /// El primer fotograma arranca el escritor; hasta entonces su estado es
    /// `.unknown`. Los fotogramas que llegan cuando el codificador va saturado se
    /// descartan y se cuentan para el diagnóstico.
    func append(_ sampleBuffer: CMSampleBuffer) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isClosed else {
            return
        }
        if writer.status == .unknown {
            guard writer.startWriting() else {
                recordFailure("startWriting: \(writer.error?.localizedDescription ?? "unknown")")
                return
            }
        }
        guard writer.status == .writing else {
            return
        }
        if !startedSession {
            writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
            startedSession = true
        }
        guard input.isReadyForMoreMediaData else {
            droppedFrames += 1
            return
        }
        if !input.append(sampleBuffer) {
            recordFailure("append: \(writer.error?.localizedDescription ?? "unknown")")
        }
    }

    /// Cierra el archivo y notifica el resultado desde una cola arbitraria.
    func finish(completion: @escaping @Sendable (Result<Void, VideoWriterError>) -> Void) {
        queue.async {
            self.isClosed = true
            if self.droppedFrames > 0 {
                DiagnosticLog.write("video writer dropped frames count=\(self.droppedFrames)")
            }
            guard self.startedSession else {
                self.cancelIfWriting()
                completion(.failure(self.failureReason.map(VideoWriterError.couldNotStart) ?? .noFrames))
                return
            }
            // `finishWriting` sobre un escritor `.failed` lanza una excepción de
            // Objective-C que tumba la app.
            guard self.writer.status == .writing else {
                let reason = self.failureReason
                    ?? self.writer.error?.localizedDescription
                    ?? "status=\(self.writer.status.rawValue)"
                completion(.failure(.writerFailed(reason)))
                return
            }
            self.input.markAsFinished()
            self.writer.finishWriting {
                if self.writer.status == .completed {
                    completion(.success(()))
                } else {
                    let reason = self.writer.error?.localizedDescription ?? "status=\(self.writer.status.rawValue)"
                    completion(.failure(.writerFailed(reason)))
                }
            }
        }
    }

    /// Abandona la grabación sin cerrar el archivo. Después de que la cola haya
    /// procesado los fotogramas pendientes, llama a `completion`.
    func discard(completion: @escaping @Sendable () -> Void) {
        queue.async {
            self.isClosed = true
            self.cancelIfWriting()
            completion()
        }
    }

    private func cancelIfWriting() {
        if writer.status == .writing {
            writer.cancelWriting()
        }
    }

    private func recordFailure(_ reason: String) {
        // Solo se registra la primera causa: las siguientes suelen ser eco de ella.
        guard failureReason == nil else {
            return
        }
        failureReason = reason
        DiagnosticLog.write("video writer failed \(reason)")
        onFailure?(reason)
    }
}

// MARK: - Fuente de captura

/// Una captura en marcha: el stream de fotogramas y el archivo donde se escribe.
@MainActor
protocol VideoCaptureHandle: AnyObject {
    /// Archivo de salida.
    var fileURL: URL { get }
    /// Detiene la entrega de fotogramas.
    func stopCapture() async throws
    /// Cierra el archivo. Debe llamarse después de `stopCapture()`.
    func finish() async -> Result<Void, VideoWriterError>
    /// Detiene todo y borra el archivo; para arranques cancelados.
    func discard() async
}

/// Arranca capturas de vídeo de una zona.
@MainActor
protocol VideoCaptureSource {
    /// Prepara el archivo y arranca la captura de `request`.
    ///
    /// - Parameter onInterrupted: se llama si la captura se detiene sola (error
    ///   del stream o del escritor) con un mensaje para el usuario.
    /// - Throws: un error con descripción apta para mostrar al usuario.
    func start(
        request: CaptureRequest,
        onInterrupted: @escaping @Sendable (String) -> Void
    ) async throws -> VideoCaptureHandle
}

/// Error de arranque con mensaje ya preparado para el usuario.
struct VideoStartError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Implementación con ScreenCaptureKit.
@MainActor
struct ScreenCaptureVideoSource: VideoCaptureSource {
    func start(
        request: CaptureRequest,
        onInterrupted: @escaping @Sendable (String) -> Void
    ) async throws -> VideoCaptureHandle {
        guard let resolved = VideoRegionResolver.resolve(
            region: request.region,
            descriptors: VideoRecorder.screenDescriptors()
        ) else {
            throw VideoStartError(message: L10n.t("La zona no esta en ninguna pantalla activa."))
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            DiagnosticLog.write("video shareable content error=\(error.localizedDescription)")
            throw VideoStartError(message: ScreenCapturePermission.userFacingMessage(for: error))
        }
        guard let display = content.displays.first(where: { $0.displayID == resolved.displayID }) else {
            throw VideoStartError(message: L10n.t("No se encontro la pantalla de la zona."))
        }

        let size = VideoWriterSession.encoderSize(
            width: Int(resolved.localRect.width * resolved.scale),
            height: Int(resolved.localRect.height * resolved.scale)
        )
        let url = try CaptureFiles.makeURL(in: request.outputFolderPath, fileExtension: "mp4")
        let session = try VideoWriterSession(url: url, pixelWidth: size.width, pixelHeight: size.height) { reason in
            onInterrupted(VideoWriterError.writerFailed(reason).localizedDescription)
        }

        let configuration = SCStreamConfiguration()
        configuration.sourceRect = resolved.localRect
        configuration.width = size.width
        configuration.height = size.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 5
        configuration.showsCursor = true
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

        let forwarder = FrameForwarder(session: session) { error in
            DiagnosticLog.write("video stream stopped error=\(error.localizedDescription)")
            onInterrupted(ScreenCapturePermission.userFacingMessage(for: error))
        }
        let stream = SCStream(
            filter: SCContentFilter(display: display, excludingWindows: []),
            configuration: configuration,
            delegate: forwarder
        )
        do {
            try stream.addStreamOutput(forwarder, type: .screen, sampleHandlerQueue: session.queue)
            try await stream.startCapture()
        } catch {
            DiagnosticLog.write("video recording failed to start error=\(error.localizedDescription)")
            throw VideoStartError(message: ScreenCapturePermission.userFacingMessage(for: error))
        }
        DiagnosticLog.write("video recording started size=\(size.width)x\(size.height)")
        return ScreenCaptureVideoHandle(stream: stream, forwarder: forwarder, session: session, fileURL: url)
    }
}

/// Captura en marcha con ScreenCaptureKit.
@MainActor
private final class ScreenCaptureVideoHandle: VideoCaptureHandle {
    let fileURL: URL
    private let stream: SCStream
    /// Solo se guarda para retenerlo: `SCStream` no garantiza retener a su
    /// delegado ni a sus salidas.
    private let forwarder: FrameForwarder
    private let session: VideoWriterSession

    init(stream: SCStream, forwarder: FrameForwarder, session: VideoWriterSession, fileURL: URL) {
        self.stream = stream
        self.forwarder = forwarder
        self.session = session
        self.fileURL = fileURL
    }

    func stopCapture() async throws {
        try await stream.stopCapture()
    }

    func finish() async -> Result<Void, VideoWriterError> {
        await withCheckedContinuation { continuation in
            session.finish { continuation.resume(returning: $0) }
        }
    }

    func discard() async {
        do {
            try await stream.stopCapture()
        } catch {
            DiagnosticLog.write("video discard stopCapture error=\(error.localizedDescription)")
        }
        let url = fileURL
        // El borrado va en el callback: así ocurre después de los fotogramas
        // que aún estuvieran en la cola y que podrían recrear el archivo.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.discard {
                CaptureFiles.remove(at: url)
                continuation.resume()
            }
        }
    }
}

/// Recibe los fotogramas de ScreenCaptureKit y los reenvía al escritor.
private final class FrameForwarder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let session: VideoWriterSession
    private let onStop: @Sendable (Error) -> Void

    init(session: VideoWriterSession, onStop: @escaping @Sendable (Error) -> Void) {
        self.session = session
        self.onStop = onStop
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, Self.isCompleteFrame(sampleBuffer) else {
            return
        }
        session.append(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop(error)
    }

    /// ScreenCaptureKit también entrega muestras `.idle` o `.blank` sin imagen;
    /// pasarlas a `AVAssetWriter` lo deja en estado `.failed`.
    static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard CMSampleBufferGetImageBuffer(sampleBuffer) != nil else {
            return false
        }
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
            let rawStatus = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: rawStatus)
        else {
            // Sin metadatos de ScreenCaptureKit, basta con que haya imagen.
            return true
        }
        return status == .complete
    }
}

// MARK: - Orquestación

/// Orquesta la grabación de vídeo de la zona seleccionada.
///
/// Estados: `idle` → `starting` → `recording` → `stopping` → `idle`.
/// - Cada arranque lleva un identificador: si el usuario detiene mientras la
///   captura aún arranca (por ejemplo, con el aviso de TCC en pantalla), el
///   arranque detecta que ya no es el vigente y descarta la captura.
/// - En `stopping` se guarda la tarea de cierre, de modo que cualquier otra
///   llamada a `stop()` (incluida la de salir de la app) espera a ese mismo
///   cierre en lugar de cortar la escritura del archivo.
@MainActor
final class VideoRecorder: ObservableObject {
    /// `true` mientras se prepara o se graba; controla el botón del menú.
    @Published private(set) var isRecording = false
    @Published private(set) var lastMessage = ""
    @Published private(set) var elapsedDescription = "0:00"

    /// Tiempo máximo para cerrar el MP4 antes de darlo por fallido.
    static let finalizeTimeout: TimeInterval = 15

    private struct ActiveRecording {
        let id: UUID
        let handle: VideoCaptureHandle
        let startedAt: Date
    }

    private enum State {
        case idle
        case starting(UUID)
        case recording(ActiveRecording)
        case stopping(Task<Bool, Never>)
    }

    private let settings: AppSettings
    private let source: VideoCaptureSource
    /// Interrupción llegada mientras la captura aún arrancaba; se atiende en
    /// cuanto pasa a `recording`.
    private var pendingInterruption: (id: UUID, message: String)?
    /// Mensaje mostrado al vencer el tope de cierre. Un resultado tardío solo
    /// lo corrige si sigue siendo el visible, para no tapar un aviso posterior.
    private var timeoutMessage: (fileURL: URL, message: String)?
    private let maxDuration: TimeInterval
    private var timer: Timer?
    private var state: State = .idle {
        didSet {
            switch state {
            case .starting, .recording:
                isRecording = true
            case .idle:
                isRecording = false
                elapsedDescription = "0:00"
            case .stopping:
                isRecording = false
            }
        }
    }

    /// `true` mientras hay algo que no se debe interrumpir: arranque,
    /// grabación o cierre del archivo.
    var isBusy: Bool {
        if case .idle = state {
            return false
        }
        return true
    }

    /// - Parameters:
    ///   - source: origen de la captura; los tests inyectan uno falso.
    ///   - maxDuration: duración máxima en segundos; al alcanzarla la grabación
    ///     se detiene y se guarda sola.
    init(
        settings: AppSettings,
        source: VideoCaptureSource = ScreenCaptureVideoSource(),
        maxDuration: TimeInterval = 600
    ) {
        self.settings = settings
        self.source = source
        self.maxDuration = maxDuration
    }

    /// Inicia o detiene la grabación según el estado actual.
    func toggle() {
        switch state {
        case .idle:
            start()
        case .starting, .recording:
            Task { await stop() }
        case .stopping:
            // Aún se está guardando la grabación anterior.
            NSSound.beep()
        }
    }

    /// Arranca una grabación de la zona configurada. Solo actúa en `idle`.
    func start() {
        guard case .idle = state else {
            return
        }
        guard let request = settings.captureRequest() else {
            fail(CaptureError.missingRegion.localizedDescription)
            DiagnosticLog.write("video skipped reason=missing-region")
            return
        }

        let id = UUID()
        state = .starting(id)
        lastMessage = L10n.t("Preparando grabacion...")
        Task {
            await begin(request: request, id: id)
        }
    }

    /// Detiene la grabación y espera a que el archivo quede cerrado.
    ///
    /// - Parameter reason: texto que precede al mensaje final (por ejemplo, el
    ///   motivo de una interrupción).
    /// - Returns: `true` si se guardó un archivo.
    @discardableResult
    func stop(reason: String? = nil) async -> Bool {
        switch state {
        case .idle:
            return false
        case .starting:
            state = .idle
            lastMessage = L10n.t("Grabacion cancelada.")
            DiagnosticLog.write("video recording cancelled while starting")
            return false
        case .stopping(let finalization):
            return await finalization.value
        case .recording(let active):
            stopTimer()
            lastMessage = L10n.t("Guardando grabacion...")
            DiagnosticLog.write("video recording stop requested")
            let finalization = Task { await self.finalize(active, reason: reason) }
            state = .stopping(finalization)
            return await finalization.value
        }
    }

    private func begin(request: CaptureRequest, id: UUID) async {
        let handle: VideoCaptureHandle
        do {
            handle = try await source.start(request: request) { [weak self] message in
                Task { @MainActor in
                    await self?.handleInterruption(id: id, message: message)
                }
            }
        } catch {
            clearPendingInterruption(for: id)
            guard isCurrent(id) else {
                return
            }
            state = .idle
            fail(error.localizedDescription)
            return
        }

        guard isCurrent(id) else {
            clearPendingInterruption(for: id)
            await handle.discard()
            DiagnosticLog.write("video capture discarded after cancelled start")
            return
        }
        state = .recording(ActiveRecording(id: id, handle: handle, startedAt: Date()))
        lastMessage = L10n.t("Grabando video de la zona")
        startTimer()
        if let pending = pendingInterruption, pending.id == id {
            pendingInterruption = nil
            await handleInterruption(id: id, message: pending.message)
        }
    }

    private func finalize(_ active: ActiveRecording, reason: String?) async -> Bool {
        do {
            try await active.handle.stopCapture()
        } catch {
            // Tras una interrupción el stream ya está parado y esto falla; no
            // impide cerrar el archivo.
            DiagnosticLog.write("video stopCapture error=\(error.localizedDescription)")
        }
        let result = await finishWithTimeout(active.handle)
        state = .idle

        let fileName = active.handle.fileURL.lastPathComponent
        switch result {
        case .success:
            CaptureFiles.harden(at: active.handle.fileURL)
            let saved = L10n.format("Guardado: %@", fileName)
            lastMessage = reason.map { "\($0) \(saved)" } ?? saved
            DiagnosticLog.write("video recording saved file=\(fileName)")
            return true
        case .failure(let error) where error.leavesNoFile:
            CaptureFiles.remove(at: active.handle.fileURL)
            DiagnosticLog.write("video recording discarded error=\(error.localizedDescription)")
            fail(reason ?? error.localizedDescription)
            return false
        case .failure(let error):
            // Solo llega aquí `.timedOut`: el cierre puede terminar más tarde,
            // así que el archivo se conserva (ver `applyLateFinalization`).
            CaptureFiles.harden(at: active.handle.fileURL)
            DiagnosticLog.write("video recording finalize failed file=\(fileName) error=\(error.localizedDescription)")
            fail(L10n.format("La grabacion puede estar incompleta (%@): %@", fileName, reason ?? error.localizedDescription))
            if error == .timedOut {
                timeoutMessage = (active.handle.fileURL, lastMessage)
            }
            return false
        }
    }

    /// Gana quien llegue antes: el cierre real o el tope de tiempo.
    private func finishWithTimeout(_ handle: VideoCaptureHandle) async -> Result<Void, VideoWriterError> {
        await withCheckedContinuation { continuation in
            let resumed = LockedBox(false)
            Task { @MainActor in
                let result = await handle.finish()
                if !resumed.exchange(true) {
                    continuation.resume(returning: result)
                } else {
                    // Llegó después del tope: se corrige lo que se dijo al usuario.
                    DiagnosticLog.write("video finalize late result=\(result)")
                    self.applyLateFinalization(result, fileURL: handle.fileURL)
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.finalizeTimeout) {
                if !resumed.exchange(true) {
                    continuation.resume(returning: .failure(.timedOut))
                }
            }
        }
    }

    /// Corrige el resultado mostrado cuando el cierre real llega después del
    /// tope: borra un archivo inútil o confirma que se guardó bien.
    private func applyLateFinalization(_ result: Result<Void, VideoWriterError>, fileURL: URL) {
        // Solo cuenta el aviso de tope de esta misma grabación.
        var stillShowingTimeout = false
        if let timeout = timeoutMessage, timeout.fileURL == fileURL {
            stillShowingTimeout = lastMessage == timeout.message
            timeoutMessage = nil
        }
        switch result {
        case .success:
            CaptureFiles.harden(at: fileURL)
            if stillShowingTimeout {
                lastMessage = L10n.format("Guardado: %@", fileURL.lastPathComponent)
            }
        case .failure(let error) where error.leavesNoFile:
            CaptureFiles.remove(at: fileURL)
            DiagnosticLog.write("video late finalize removed file=\(fileURL.lastPathComponent) error=\(error.localizedDescription)")
            if stillShowingTimeout {
                lastMessage = error.localizedDescription
            }
        case .failure:
            break
        }
    }

    /// La captura se detuvo sola (permiso revocado, «Dejar de compartir» en el
    /// indicador de privacidad, pantalla desconectada, escritor fallido...).
    /// Se guarda lo grabado hasta ese momento.
    private func handleInterruption(id: UUID, message: String) async {
        if case .starting(id) = state {
            pendingInterruption = (id, message)
            return
        }
        guard case .recording(let active) = state, active.id == id else {
            return
        }
        await stop(reason: L10n.format("Grabacion interrumpida: %@", message))
    }

    /// Olvida la interrupción pendiente solo si es de esta grabación: un
    /// arranque antiguo que termina tarde no debe borrar la de la actual.
    private func clearPendingInterruption(for id: UUID) {
        if pendingInterruption?.id == id {
            pendingInterruption = nil
        }
    }

    private func isCurrent(_ id: UUID) -> Bool {
        guard case .starting(id) = state else {
            return false
        }
        return true
    }

    private func fail(_ message: String) {
        lastMessage = message
        NSSound.beep()
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.updateElapsed()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func updateElapsed() async {
        guard case .recording(let active) = state else {
            return
        }
        let elapsed = Date().timeIntervalSince(active.startedAt)
        elapsedDescription = Self.format(elapsed: elapsed)
        if elapsed >= maxDuration {
            DiagnosticLog.write("video recording reached max duration")
            await stop(reason: L10n.format("Grabacion detenida al llegar a %@.", Self.format(elapsed: maxDuration)))
        }
    }

    /// Pantallas activas con su `CGDirectDisplayID`, límites Quartz y escala.
    static func screenDescriptors() -> [VideoRegionDescriptor] {
        NSScreen.screens.compactMap { screen in
            guard let displayID = ScreenGeometry.displayID(of: screen) else {
                return nil
            }
            return VideoRegionDescriptor(
                displayID: displayID,
                quartzBounds: CGDisplayBounds(displayID),
                scale: screen.backingScaleFactor
            )
        }
    }

    /// Formatea segundos como `m:ss`, con los minutos limitados a 99.
    nonisolated static func format(elapsed: TimeInterval) -> String {
        let total = max(0, Int(elapsed))
        let minutes = min(99, total / 60)
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
