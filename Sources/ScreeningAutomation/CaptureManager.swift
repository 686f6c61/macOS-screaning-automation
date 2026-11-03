import AppKit
import Darwin
import ImageIO
import Foundation
import ScreenCaptureKit
import UniformTypeIdentifiers

struct CaptureRequest {
    var region: CaptureRegion
    var outputFolderPath: String
    var imageFormat: ImageFormat
}

enum CaptureError: Error, LocalizedError {
    case missingRegion
    case processFailed(Int32, String)
    case processTimedOut
    case invalidImage
    case coreGraphicsFailed
    /// TCC deniega Grabación de pantalla. No se recurre a `screencapture`
    /// porque sin permiso guarda solo el fondo de escritorio.
    case screenRecordingDenied

    var errorDescription: String? {
        switch self {
        case .screenRecordingDenied:
            return L10n.t("Falta el permiso de Grabacion de pantalla. Activalo en Ajustes y reinicia la app.")
        case .missingRegion:
            return L10n.t("No hay una zona definida.")
        case .processFailed(let status, let details):
            if details.isEmpty {
                return L10n.format("screencapture termino con codigo %d.", status)
            }
            return L10n.format("screencapture termino con codigo %d: %@", status, details)
        case .processTimedOut:
            return L10n.t("La captura ha superado el tiempo de espera.")
        case .invalidImage:
            return L10n.t("La captura no produjo una imagen valida.")
        case .coreGraphicsFailed:
            return L10n.t("No se pudo crear imagen de la zona.")
        }
    }
}

@MainActor
final class CaptureManager: ObservableObject {
    typealias CaptureExecutor = @Sendable (CaptureRequest) -> Result<URL, Error>

    @Published private(set) var isCapturing = false
    @Published private(set) var lastCaptureURL: URL?
    @Published private(set) var lastMessage = L10n.t("Listo")
    @Published private(set) var lastCaptureSucceeded = false
    @Published private(set) var armedCaptureActive = false
    @Published private(set) var armedCaptureMessage = L10n.t("Modo armado inactivo")

    var prepareForCapture: (() -> Void)?

    private let settings: AppSettings
    private let captureExecutor: CaptureExecutor
    private let captureSettleDelay: TimeInterval
    private var activeCaptureOperationID: UUID?
    private var armedCaptureTimer: DispatchSourceTimer?
    private var armedCaptureActivity: NSObjectProtocol?
    private var armedCaptureRequest: CaptureRequest?
    private var armedCaptureSessionID: UUID?
    private var armedCaptureRemaining = 0
    private var armedCaptureTotal = 0
    private var armedCaptureInFlight = false
    private var didAutoRequestScreenPermission = false

    init(
        settings: AppSettings,
        captureSettleDelay: TimeInterval = 0.22,
        captureExecutor: CaptureExecutor? = nil
    ) {
        self.settings = settings
        self.captureSettleDelay = captureSettleDelay
        self.captureExecutor = captureExecutor ?? Self.performCapture
    }

    func captureNow(source: String) {
        guard !isCapturing else {
            return
        }
        guard let request = settings.captureRequest() else {
            lastMessage = CaptureError.missingRegion.localizedDescription
            lastCaptureSucceeded = false
            DiagnosticLog.write("capture skipped source=\(source) reason=missing-region")
            NSSound.beep()
            return
        }

        isCapturing = true
        let operationID = UUID()
        activeCaptureOperationID = operationID
        lastMessage = L10n.t("Capturando...")
        prepareForCapture?()
        DiagnosticLog.write("capture started source=\(source) size=\(request.region.width)x\(request.region.height)")
        let captureExecutor = captureExecutor

        DispatchQueue.main.asyncAfter(deadline: .now() + captureSettleDelay) {
            DispatchQueue.global(qos: .userInitiated).async {
                let result = captureExecutor(request)
                DispatchQueue.main.async {
                    guard self.activeCaptureOperationID == operationID else {
                        DiagnosticLog.write("capture completion ignored reason=stale-operation")
                        return
                    }
                    self.activeCaptureOperationID = nil
                    self.isCapturing = false
                    switch result {
                    case .success(let url):
                        self.lastCaptureURL = url
                        self.lastCaptureSucceeded = true
                        self.lastMessage = L10n.format("Guardado: %@", url.lastPathComponent)
                        DiagnosticLog.write("capture succeeded file=\(url.lastPathComponent)")
                    case .failure(let error):
                        self.lastCaptureSucceeded = false
                        self.lastMessage = error.localizedDescription
                        DiagnosticLog.write("capture failed error=\(error.localizedDescription)")
                        if case CaptureError.screenRecordingDenied = error, !self.didAutoRequestScreenPermission {
                            // Solo una vez por ejecución: si TCC ya tiene una
                            // decisión, `request()` no muestra nada y abrimos Ajustes.
                            self.didAutoRequestScreenPermission = true
                            if !ScreenCapturePermission.request() {
                                ScreenCapturePermission.openSettings()
                            }
                        }
                        NSSound.beep()
                    }
                }
            }
        }
    }

    func startArmedBurst() {
        guard !armedCaptureActive else {
            cancelArmedBurst()
            return
        }
        guard let request = settings.captureRequest() else {
            lastMessage = CaptureError.missingRegion.localizedDescription
            lastCaptureSucceeded = false
            armedCaptureMessage = CaptureError.missingRegion.localizedDescription
            DiagnosticLog.write("armed burst skipped reason=missing-region")
            NSSound.beep()
            return
        }

        prepareForCapture?()
        let delay = settings.armedCaptureDelaySeconds
        let interval = settings.armedCaptureIntervalSeconds
        let total = settings.armedCaptureCount

        armedCaptureRequest = request
        let sessionID = UUID()
        armedCaptureSessionID = sessionID
        armedCaptureRemaining = total
        armedCaptureTotal = total
        armedCaptureInFlight = false
        armedCaptureActive = true
        armedCaptureMessage = L10n.format("Armado: espera %@ s", delay.formatted(.number.precision(.fractionLength(1))))
        lastMessage = armedCaptureMessage
        beginArmedCaptureActivity()
        DiagnosticLog.write("armed burst scheduled delay=\(delay) interval=\(interval) count=\(total)")

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + delay,
            repeating: interval,
            leeway: .milliseconds(80)
        )
        timer.setEventHandler { [weak self] in
            self?.runArmedCaptureTick(sessionID: sessionID)
        }
        armedCaptureTimer = timer
        timer.resume()
    }

    func cancelArmedBurst() {
        guard let sessionID = armedCaptureSessionID else {
            return
        }
        finishArmedBurst(sessionID: sessionID, message: L10n.t("Modo armado cancelado"))
        DiagnosticLog.write("armed burst cancelled")
    }

    private func runArmedCaptureTick(sessionID: UUID) {
        guard armedCaptureActive, armedCaptureSessionID == sessionID else {
            return
        }
        guard !armedCaptureInFlight, !isCapturing else {
            DiagnosticLog.write("armed burst tick skipped reason=capture-in-flight")
            return
        }
        guard let request = armedCaptureRequest else {
            finishArmedBurst(sessionID: sessionID, message: L10n.t("Modo armado sin zona"))
            return
        }
        guard armedCaptureRemaining > 0 else {
            finishArmedBurst(sessionID: sessionID, message: L10n.t("Modo armado finalizado"))
            return
        }

        let index = armedCaptureTotal - armedCaptureRemaining + 1
        armedCaptureRemaining -= 1
        armedCaptureInFlight = true
        isCapturing = true
        let operationID = UUID()
        activeCaptureOperationID = operationID
        armedCaptureMessage = L10n.format("Armado: captura %d/%d", index, armedCaptureTotal)
        lastMessage = armedCaptureMessage
        DiagnosticLog.write("armed burst capture started index=\(index) remaining=\(armedCaptureRemaining)")

        let captureExecutor = captureExecutor
        DispatchQueue.global(qos: .userInitiated).async {
            let result = captureExecutor(request)
            DispatchQueue.main.async {
                if self.activeCaptureOperationID == operationID {
                    self.activeCaptureOperationID = nil
                    self.isCapturing = false
                }
                guard self.armedCaptureSessionID == sessionID else {
                    DiagnosticLog.write("armed burst completion ignored reason=stale-session")
                    return
                }
                self.armedCaptureInFlight = false
                switch result {
                case .success(let url):
                    self.lastCaptureURL = url
                    self.lastCaptureSucceeded = true
                    self.lastMessage = L10n.format("Guardado: %@", url.lastPathComponent)
                    self.armedCaptureMessage = L10n.format("Armado: guardada %d/%d", index, self.armedCaptureTotal)
                    DiagnosticLog.write("armed burst capture succeeded index=\(index) file=\(url.lastPathComponent)")
                case .failure(let error):
                    self.lastCaptureSucceeded = false
                    self.lastMessage = error.localizedDescription
                    self.armedCaptureMessage = L10n.format("Armado: error %d/%d", index, self.armedCaptureTotal)
                    DiagnosticLog.write("armed burst capture failed index=\(index) error=\(error.localizedDescription)")
                    NSSound.beep()
                }

                if self.armedCaptureRemaining <= 0 {
                    self.finishArmedBurst(sessionID: sessionID, message: L10n.t("Modo armado finalizado"))
                }
            }
        }
    }

    private func finishArmedBurst(sessionID: UUID, message: String) {
        guard armedCaptureSessionID == sessionID else {
            return
        }
        armedCaptureTimer?.cancel()
        armedCaptureTimer = nil
        armedCaptureRequest = nil
        armedCaptureSessionID = nil
        armedCaptureRemaining = 0
        armedCaptureTotal = 0
        armedCaptureInFlight = false
        armedCaptureActive = false
        armedCaptureMessage = message
        if lastMessage.hasPrefix(L10n.t("Armado:")) {
            lastMessage = message
        }
        endArmedCaptureActivity()
    }

    private func beginArmedCaptureActivity() {
        guard armedCaptureActivity == nil else {
            return
        }
        armedCaptureActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Screening Automation armed capture"
        )
        DiagnosticLog.write("armed capture activity started")
    }

    private func endArmedCaptureActivity() {
        guard let armedCaptureActivity else {
            return
        }
        ProcessInfo.processInfo.endActivity(armedCaptureActivity)
        self.armedCaptureActivity = nil
        DiagnosticLog.write("armed capture activity ended")
    }

    /// Captura la zona y la guarda en disco. Se ejecuta fuera del hilo principal.
    ///
    /// Usa ScreenCaptureKit (macOS 15.2+) y recurre a `/usr/sbin/screencapture`
    /// solo ante fallos transitorios o en sistemas anteriores. Un permiso
    /// denegado se devuelve como `CaptureError.screenRecordingDenied`.
    nonisolated static func performCapture(request: CaptureRequest) -> Result<URL, Error> {
        do {
            let fileURL = try CaptureFileNaming.makeURL(
                in: request.outputFolderPath,
                fileExtension: request.imageFormat.fileExtension
            )

            switch captureWithScreenCaptureKit(request: request, fileURL: fileURL) {
            case .saved:
                hardenCaptureFile(at: fileURL)
                return .success(fileURL)
            case .permissionDenied:
                try? FileManager.default.removeItem(at: fileURL)
                return .failure(CaptureError.screenRecordingDenied)
            case .unavailable:
                break
            }

            DiagnosticLog.write("screencapture fallback started")
            if let error = runScreenCapture(request: request, fileURL: fileURL) {
                try? FileManager.default.removeItem(at: fileURL)
                return .failure(error)
            }
            hardenCaptureFile(at: fileURL)
            return .success(fileURL)
        } catch {
            return .failure(error)
        }
    }

    nonisolated private static func runScreenCapture(request: CaptureRequest, fileURL: URL) -> CaptureError? {
        let process = Process()
        let errorPipe = Pipe()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = [
            "-x",
            "-t",
            request.imageFormat.screencaptureToken,
            "-R",
            request.region.screencaptureArgument,
            fileURL.path
        ]
        process.standardError = errorPipe
        process.standardOutput = outputPipe
        let processFinished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            processFinished.signal()
        }
        do {
            try process.run()
        } catch {
            return .processFailed(1, error.localizedDescription)
        }
        guard processFinished.wait(timeout: .now() + 12) == .success else {
            process.terminate()
            if processFinished.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = processFinished.wait(timeout: .now() + 1)
            }
            try? FileManager.default.removeItem(at: fileURL)
            DiagnosticLog.write("screencapture timed out")
            return .processTimedOut
        }

        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let details = [
                String(data: errorData, encoding: .utf8),
                String(data: outputData, encoding: .utf8)
            ]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
                .replacingOccurrences(of: request.outputFolderPath, with: "<output>")
            DiagnosticLog.write("screencapture failed status=\(process.terminationStatus) details=\(details)")
            return .processFailed(process.terminationStatus, details)
        }

        guard capturedFileIsValid(at: fileURL) else {
            try? FileManager.default.removeItem(at: fileURL)
            DiagnosticLog.write("screencapture produced invalid or blank image")
            return .invalidImage
        }
        return nil
    }

    nonisolated private static func capturedFileIsValid(at fileURL: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width > 0,
              image.height > 0 else {
            return false
        }
        return !CaptureImageInspector.isLikelyBlank(image)
    }

    nonisolated static func hardenCaptureFile(at fileURL: URL) {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    /// Resultado de intentar la captura con ScreenCaptureKit.
    private enum ScreenCaptureKitOutcome {
        case saved
        case permissionDenied
        /// Error transitorio, timeout, imagen vacía o sistema sin soporte:
        /// procede intentar con `screencapture`.
        case unavailable
    }

    nonisolated private static func captureWithScreenCaptureKit(
        request: CaptureRequest,
        fileURL: URL
    ) -> ScreenCaptureKitOutcome {
        guard #available(macOS 15.2, *) else {
            return .unavailable
        }
        let rect = CGRect(
            x: request.region.x,
            y: request.region.y,
            width: request.region.width,
            height: request.region.height
        )
        let semaphore = DispatchSemaphore(value: 0)
        let result = LockedBox<(image: CGImage?, error: Error?)>((nil, nil))

        SCScreenshotManager.captureImage(in: rect) { image, error in
            result.set((image, error))
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + 8) == .success else {
            DiagnosticLog.write("screen capture kit timed out")
            return .unavailable
        }
        let (image, error) = result.get()
        if let error {
            DiagnosticLog.write("screen capture kit error=\(error.localizedDescription)")
            if ScreenCapturePermission.isPermissionDenied(error) {
                return .permissionDenied
            }
        }
        guard let image else {
            return .unavailable
        }
        guard !CaptureImageInspector.isLikelyBlank(image) else {
            try? FileManager.default.removeItem(at: fileURL)
            DiagnosticLog.write("screen capture kit produced blank image")
            return .unavailable
        }
        return write(image: image, format: request.imageFormat, to: fileURL) ? .saved : .unavailable
    }

    nonisolated private static func write(image: CGImage, format: ImageFormat, to fileURL: URL) -> Bool {
        let type: CFString
        switch format {
        case .png:
            type = UTType.png.identifier as CFString
        case .jpg:
            type = UTType.jpeg.identifier as CFString
        case .pdf:
            type = UTType.pdf.identifier as CFString
        case .tiff:
            type = UTType.tiff.identifier as CFString
        }
        guard let destination = CGImageDestinationCreateWithURL(fileURL as CFURL, type, 1, nil) else {
            return false
        }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }

    func revealLastCapture() {
        guard let lastCaptureURL else {
            settings.revealOutputFolder()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([lastCaptureURL])
    }
}

enum CaptureImageInspector {
    static func isLikelyBlank(_ image: CGImage) -> Bool {
        let width = 32
        let height = 32
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return false
        }

        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var visiblePixels = 0
        var nonBlackPixels = 0
        for index in stride(from: 0, to: pixels.count, by: bytesPerPixel) {
            let red = pixels[index]
            let green = pixels[index + 1]
            let blue = pixels[index + 2]
            let alpha = pixels[index + 3]
            guard alpha > 2 else {
                continue
            }
            visiblePixels += 1
            if Int(red) + Int(green) + Int(blue) > 6 {
                nonBlackPixels += 1
            }
        }

        return visiblePixels == 0 || nonBlackPixels == 0
    }
}
