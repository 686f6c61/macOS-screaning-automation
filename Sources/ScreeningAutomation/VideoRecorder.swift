// Grabación de vídeo de la zona seleccionada.
//
// El flujo tiene tres piezas:
// - `VideoRegionResolver` traduce la zona (coordenadas Quartz globales) a una
//   pantalla concreta y a un rectángulo local de esa pantalla.
// - `VideoWriterSession` encapsula `AVAssetWriter` y solo se toca desde su cola
//   serie, que es también la cola donde ScreenCaptureKit entrega los fotogramas.
// - `VideoRecorder` (MainActor) orquesta el ciclo de vida con una máquina de
//   estados explícita para que detener durante el arranque no deje un
//   `SCStream` huérfano.

import AppKit
import AVFoundation
import Combine
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

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

/// Fallos posibles al escribir el archivo de vídeo.
enum VideoWriterError: Error, Equatable, LocalizedError {
    /// No se pudo crear el `AVAssetWriter` (ruta no escribible, archivo existente...).
    case cannotCreate(String)
    /// El códec no acepta la configuración solicitada.
    case unsupportedSettings
    /// Se detuvo la grabación sin recibir ningún fotograma completo.
    case noFrames
    /// `AVAssetWriter` falló durante la escritura o el cierre.
    case writerFailed(String)

    var errorDescription: String? {
        switch self {
        case .cannotCreate(let reason):
            return L10n.format("No se pudo preparar el archivo de video: %@", reason)
        case .unsupportedSettings:
            return L10n.t("El codificador no admite el tamano de la zona.")
        case .noFrames:
            return L10n.t("No se recibio ningun fotograma de la pantalla.")
        case .writerFailed(let reason):
            return L10n.format("La grabacion no se pudo guardar: %@", reason)
        }
    }
}

/// Envoltorio de `AVAssetWriter` para una grabación H.264 en MP4.
///
/// Contrato de hilos: `append(_:)` y el cuerpo de `finish(completion:)` se
/// ejecutan siempre en `queue`. Por eso la clase es `@unchecked Sendable`: todo
/// el estado mutable se serializa en esa cola.
final class VideoWriterSession: @unchecked Sendable {
    /// Lado máximo que aceptan los codificadores H.264 de Apple.
    static let maxEncoderDimension = 4096

    let queue = DispatchQueue(label: "tech.686f6c61.screening-automation.video-writer")

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private var startedSession = false
    private var droppedFrames = 0
    private var appendFailure: String?

    /// Prepara el escritor. No crea el archivo hasta recibir el primer fotograma.
    ///
    /// - Throws: `VideoWriterError.cannotCreate` o `.unsupportedSettings`.
    init(url: URL, pixelWidth: Int, pixelHeight: Int) throws {
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        } catch {
            throw VideoWriterError.cannotCreate(error.localizedDescription)
        }
        // Fragmentar el MP4 permite recuperar lo grabado si la app termina de
        // forma abrupta antes de escribir el átomo `moov` final.
        writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)

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
            if self.droppedFrames > 0 {
                DiagnosticLog.write("video writer dropped frames count=\(self.droppedFrames)")
            }
            guard self.startedSession else {
                if self.writer.status == .writing {
                    self.writer.cancelWriting()
                }
                completion(.failure(self.appendFailure.map(VideoWriterError.writerFailed) ?? .noFrames))
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

    private func recordFailure(_ reason: String) {
        // Solo se registra la primera causa: las siguientes suelen ser eco de ella.
        guard appendFailure == nil else {
            return
        }
        appendFailure = reason
        DiagnosticLog.write("video writer failed \(reason)")
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

/// Orquesta la grabación de vídeo de la zona seleccionada.
///
/// Estados: `idle` → `starting` → `recording` → `stopping` → `idle`. Cada
/// arranque lleva un identificador; si el usuario detiene mientras
/// ScreenCaptureKit aún está arrancando, el arranque detecta que su identificador
/// ya no es el vigente y libera el stream en vez de adoptarlo.
@MainActor
final class VideoRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var lastMessage = ""
    @Published private(set) var elapsedDescription = "0:00"

    private struct ActiveRecording {
        let id: UUID
        let stream: SCStream
        let forwarder: FrameForwarder
        let session: VideoWriterSession
        let fileURL: URL
        let startedAt: Date
    }

    private enum State {
        case idle
        case starting(UUID)
        case recording(ActiveRecording)
        case stopping
    }

    private let settings: AppSettings
    private let maxDuration: TimeInterval
    private var state: State = .idle {
        didSet {
            switch state {
            case .starting, .recording:
                isRecording = true
            case .idle, .stopping:
                isRecording = false
            }
        }
    }
    private var timer: Timer?

    /// - Parameter maxDuration: duración máxima en segundos; al alcanzarla la
    ///   grabación se detiene y se guarda sola.
    init(settings: AppSettings, maxDuration: TimeInterval = 600) {
        self.settings = settings
        self.maxDuration = maxDuration
    }

    /// Inicia o detiene la grabación según el estado actual.
    func toggle() {
        if isRecording {
            Task { await stop() }
        } else {
            start()
        }
    }

    /// Arranca una grabación de la zona configurada. No hace nada si ya hay una
    /// en curso o guardándose.
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
        elapsedDescription = "0:00"
        Task {
            await startSession(request: request, id: id)
        }
    }

    /// Detiene la grabación y espera a que el archivo quede cerrado.
    ///
    /// - Returns: `true` si se guardó un archivo.
    @discardableResult
    func stop(reason: String? = nil) async -> Bool {
        switch state {
        case .idle, .stopping:
            return false
        case .starting:
            state = .idle
            lastMessage = L10n.t("Grabacion cancelada.")
            DiagnosticLog.write("video recording cancelled while starting")
            return false
        case .recording(let active):
            state = .stopping
            stopTimer()
            lastMessage = L10n.t("Guardando grabacion...")
            DiagnosticLog.write("video recording stop requested")
            do {
                try await active.stream.stopCapture()
            } catch {
                // Tras `didStopWithError` el stream ya está parado y esto falla;
                // no impide cerrar el archivo.
                DiagnosticLog.write("video stream stopCapture error=\(error.localizedDescription)")
            }
            return await finalize(active, reason: reason)
        }
    }

    /// Tiempo máximo para cerrar el MP4 antes de darlo por fallido.
    private static let finalizeTimeout: TimeInterval = 15

    private func finalize(_ active: ActiveRecording, reason: String?) async -> Bool {
        let result = await withCheckedContinuation { continuation in
            // Gana quien llegue antes: el cierre real o el tope de tiempo.
            let resumed = LockedBox(false)
            let resumeOnce: @Sendable (Result<Void, VideoWriterError>) -> Void = { result in
                if !resumed.exchange(true) {
                    continuation.resume(returning: result)
                }
            }
            active.session.finish(completion: resumeOnce)
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.finalizeTimeout) {
                resumeOnce(.failure(.writerFailed("timeout")))
            }
        }
        state = .idle
        elapsedDescription = "0:00"
        switch result {
        case .success:
            CaptureManager.hardenCaptureFile(at: active.fileURL)
            let saved = L10n.format("Guardado: %@", active.fileURL.lastPathComponent)
            lastMessage = reason.map { "\($0) \(saved)" } ?? saved
            DiagnosticLog.write("video recording saved file=\(active.fileURL.lastPathComponent)")
            return true
        case .failure(let error):
            try? FileManager.default.removeItem(at: active.fileURL)
            DiagnosticLog.write("video recording failed to finalize error=\(error.localizedDescription)")
            fail(error.localizedDescription)
            return false
        }
    }

    private func startSession(request: CaptureRequest, id: UUID) async {
        guard let resolved = VideoRegionResolver.resolve(
            region: request.region,
            descriptors: Self.screenDescriptors()
        ) else {
            abortStart(id: id, message: L10n.t("La zona no esta en ninguna pantalla activa."))
            return
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            DiagnosticLog.write("video shareable content error=\(error.localizedDescription)")
            abortStart(id: id, message: ScreenCapturePermission.userFacingMessage(for: error))
            return
        }
        guard isCurrent(id) else {
            return
        }
        guard let display = content.displays.first(where: { $0.displayID == resolved.displayID }) else {
            abortStart(id: id, message: L10n.t("No se encontro la pantalla de la zona."))
            return
        }

        let size = VideoWriterSession.encoderSize(
            width: Int(resolved.localRect.width * resolved.scale),
            height: Int(resolved.localRect.height * resolved.scale)
        )
        let url: URL
        let session: VideoWriterSession
        do {
            url = try CaptureFileNaming.makeURL(in: request.outputFolderPath, fileExtension: "mp4")
            session = try VideoWriterSession(url: url, pixelWidth: size.width, pixelHeight: size.height)
        } catch {
            abortStart(id: id, message: error.localizedDescription)
            return
        }

        let configuration = SCStreamConfiguration()
        configuration.sourceRect = resolved.localRect
        configuration.width = size.width
        configuration.height = size.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 5
        configuration.showsCursor = true
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let forwarder = FrameForwarder(session: session) { [weak self] error in
            Task { @MainActor in
                await self?.handleStreamStopped(id: id, error: error)
            }
        }
        let stream = SCStream(filter: filter, configuration: configuration, delegate: forwarder)
        do {
            try stream.addStreamOutput(forwarder, type: .screen, sampleHandlerQueue: session.queue)
            try await stream.startCapture()
        } catch {
            DiagnosticLog.write("video recording failed to start error=\(error.localizedDescription)")
            abortStart(id: id, message: ScreenCapturePermission.userFacingMessage(for: error))
            return
        }

        // El usuario pudo detener mientras `startCapture` estaba pendiente (por
        // ejemplo, con el aviso de TCC en pantalla). En ese caso no adoptamos el
        // stream: lo paramos y descartamos el archivo.
        guard isCurrent(id) else {
            try? await stream.stopCapture()
            session.finish { _ in }
            try? FileManager.default.removeItem(at: url)
            DiagnosticLog.write("video stream discarded after cancelled start")
            return
        }

        state = .recording(ActiveRecording(
            id: id,
            stream: stream,
            forwarder: forwarder,
            session: session,
            fileURL: url,
            startedAt: Date()
        ))
        lastMessage = L10n.t("Grabando video de la zona")
        startTimer()
        DiagnosticLog.write("video recording started size=\(size.width)x\(size.height)")
    }

    /// El sistema detuvo el stream (permiso revocado, «Dejar de compartir» en
    /// el indicador de privacidad, pantalla desconectada...). Se guarda lo
    /// grabado hasta ese momento.
    private func handleStreamStopped(id: UUID, error: Error) async {
        DiagnosticLog.write("video stream stopped error=\(error.localizedDescription)")
        guard case .recording(let active) = state, active.id == id else {
            return
        }
        state = .stopping
        stopTimer()
        let reason = L10n.format("Grabacion interrumpida: %@", ScreenCapturePermission.userFacingMessage(for: error))
        _ = await finalize(active, reason: reason)
    }

    private func isCurrent(_ id: UUID) -> Bool {
        if case .starting(let current) = state, current == id {
            return true
        }
        return false
    }

    private func abortStart(id: UUID, message: String) {
        guard isCurrent(id) else {
            return
        }
        state = .idle
        fail(message)
    }

    private func fail(_ message: String) {
        elapsedDescription = "0:00"
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
    nonisolated static func screenDescriptors() -> [VideoRegionDescriptor] {
        MainActor.assumeIsolated {
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
    }

    /// Formatea segundos como `m:ss`, con los minutos limitados a 99.
    nonisolated static func format(elapsed: TimeInterval) -> String {
        let total = max(0, Int(elapsed))
        let minutes = min(99, total / 60)
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
