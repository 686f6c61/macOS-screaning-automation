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

    var errorDescription: String? {
        switch self {
        case .missingRegion:
            return "No hay una zona definida."
        case .processFailed(let status, let details):
            if details.isEmpty {
                return "screencapture termino con codigo \(status)."
            }
            return "screencapture termino con codigo \(status): \(details)"
        case .processTimedOut:
            return "La captura ha superado el tiempo de espera."
        case .invalidImage:
            return "La captura no produjo una imagen valida."
        case .coreGraphicsFailed:
            return "No se pudo crear imagen de la zona."
        }
    }
}

@MainActor
final class CaptureManager: ObservableObject {
    typealias CaptureExecutor = @Sendable (CaptureRequest) -> Result<URL, Error>

    @Published private(set) var isCapturing = false
    @Published private(set) var lastCaptureURL: URL?
    @Published private(set) var lastMessage = "Listo"
    @Published private(set) var lastCaptureSucceeded = false
    @Published private(set) var armedCaptureActive = false
    @Published private(set) var armedCaptureMessage = "Modo armado inactivo"

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
        lastMessage = "Capturando..."
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
                        self.lastMessage = "Guardado: \(url.lastPathComponent)"
                        DiagnosticLog.write("capture succeeded file=\(url.lastPathComponent)")
                    case .failure(let error):
                        self.lastCaptureSucceeded = false
                        self.lastMessage = error.localizedDescription
                        DiagnosticLog.write("capture failed error=\(error.localizedDescription)")
                        if !ScreenCapturePermission.allowed {
                            _ = ScreenCapturePermission.request()
                            ScreenCapturePermission.openSettings()
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
        armedCaptureMessage = "Armado: espera \(delay.formatted(.number.precision(.fractionLength(1)))) s"
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
        finishArmedBurst(sessionID: sessionID, message: "Modo armado cancelado")
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
            finishArmedBurst(sessionID: sessionID, message: "Modo armado sin zona")
            return
        }
        guard armedCaptureRemaining > 0 else {
            finishArmedBurst(sessionID: sessionID, message: "Modo armado finalizado")
            return
        }

        let index = armedCaptureTotal - armedCaptureRemaining + 1
        armedCaptureRemaining -= 1
        armedCaptureInFlight = true
        isCapturing = true
        let operationID = UUID()
        activeCaptureOperationID = operationID
        armedCaptureMessage = "Armado: captura \(index)/\(armedCaptureTotal)"
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
                    self.lastMessage = "Guardado: \(url.lastPathComponent)"
                    self.armedCaptureMessage = "Armado: guardada \(index)/\(self.armedCaptureTotal)"
                    DiagnosticLog.write("armed burst capture succeeded index=\(index) file=\(url.lastPathComponent)")
                case .failure(let error):
                    self.lastCaptureSucceeded = false
                    self.lastMessage = error.localizedDescription
                    self.armedCaptureMessage = "Armado: error \(index)/\(self.armedCaptureTotal)"
                    DiagnosticLog.write("armed burst capture failed index=\(index) error=\(error.localizedDescription)")
                    NSSound.beep()
                }

                if self.armedCaptureRemaining <= 0 {
                    self.finishArmedBurst(sessionID: sessionID, message: "Modo armado finalizado")
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
        if lastMessage.hasPrefix("Armado:") {
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

    nonisolated static func performCapture(request: CaptureRequest) -> Result<URL, Error> {
        let folderURL = URL(fileURLWithPath: request.outputFolderPath, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            let fileURL = folderURL
                .appendingPathComponent(Self.makeFileName(format: request.imageFormat), isDirectory: false)

            let process = Process()
            let errorPipe = Pipe()
            let outputPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = [
                "-x",
                "-t",
                request.imageFormat.rawValue,
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
            try process.run()
            guard processFinished.wait(timeout: .now() + 12) == .success else {
                process.terminate()
                if processFinished.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                    _ = processFinished.wait(timeout: .now() + 1)
                }
                try? FileManager.default.removeItem(at: fileURL)
                DiagnosticLog.write("screencapture timed out")
                if captureWithFallbacks(request: request, fileURL: fileURL) {
                    return .success(fileURL)
                }
                return .failure(CaptureError.processTimedOut)
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
                if captureWithFallbacks(request: request, fileURL: fileURL) {
                    return .success(fileURL)
                }
                return .failure(CaptureError.processFailed(process.terminationStatus, details))
            }

            guard capturedFileIsValid(at: fileURL) else {
                try? FileManager.default.removeItem(at: fileURL)
                DiagnosticLog.write("screencapture produced invalid or blank image")
                if captureWithFallbacks(request: request, fileURL: fileURL) {
                    return .success(fileURL)
                }
                return .failure(CaptureError.invalidImage)
            }
            hardenCaptureFile(at: fileURL)
            return .success(fileURL)
        } catch {
            return .failure(error)
        }
    }

    nonisolated private static func captureWithFallbacks(request: CaptureRequest, fileURL: URL) -> Bool {
        try? FileManager.default.removeItem(at: fileURL)
        if captureWithScreenCaptureKit(request: request, fileURL: fileURL) {
            hardenCaptureFile(at: fileURL)
            DiagnosticLog.write("screen capture kit fallback succeeded file=\(fileURL.lastPathComponent)")
            return true
        }
        DiagnosticLog.write("screen capture kit fallback failed")
        if captureWithCoreGraphics(request: request, fileURL: fileURL) {
            hardenCaptureFile(at: fileURL)
            DiagnosticLog.write("core graphics fallback succeeded file=\(fileURL.lastPathComponent)")
            return true
        }
        DiagnosticLog.write("core graphics fallback failed")
        return false
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

    nonisolated private static func captureWithScreenCaptureKit(request: CaptureRequest, fileURL: URL) -> Bool {
        guard #available(macOS 15.2, *) else {
            return false
        }

        let rect = CGRect(
            x: request.region.x,
            y: request.region.y,
            width: request.region.width,
            height: request.region.height
        )
        let semaphore = DispatchSemaphore(value: 0)
        let result = ScreenCaptureKitImageResult()

        SCScreenshotManager.captureImage(in: rect) { image, error in
            result.set(image: image, error: error)
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + 8) == .success else {
            DiagnosticLog.write("screen capture kit timed out")
            return false
        }
        if let errorDescription = result.errorDescription {
            DiagnosticLog.write("screen capture kit error=\(errorDescription)")
        }
        guard let image = result.image else {
            return false
        }
        guard !CaptureImageInspector.isLikelyBlank(image) else {
            try? FileManager.default.removeItem(at: fileURL)
            DiagnosticLog.write("screen capture kit produced blank image")
            return false
        }
        return write(image: image, format: request.imageFormat, to: fileURL)
    }

    nonisolated private static func captureWithCoreGraphics(request: CaptureRequest, fileURL: URL) -> Bool {
        let rect = CGRect(
            x: request.region.x,
            y: request.region.y,
            width: request.region.width,
            height: request.region.height
        )
        guard let image = CGWindowListCreateImage(rect, [.optionOnScreenOnly], kCGNullWindowID, [.bestResolution]) else {
            return false
        }
        guard !CaptureImageInspector.isLikelyBlank(image) else {
            try? FileManager.default.removeItem(at: fileURL)
            DiagnosticLog.write("core graphics fallback produced blank image")
            return false
        }
        return write(image: image, format: request.imageFormat, to: fileURL)
    }

    nonisolated private static func write(image: CGImage, format: ImageFormat, to fileURL: URL) -> Bool {
        let type = format == .jpg ? UTType.jpeg.identifier as CFString : UTType.png.identifier as CFString
        guard let destination = CGImageDestinationCreateWithURL(fileURL as CFURL, type, 1, nil) else {
            return false
        }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }

    nonisolated private static func makeFileName(format: ImageFormat) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        return "SA_\(formatter.string(from: Date())).\(format.fileExtension)"
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

final class ScreenCaptureKitImageResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storedImage: CGImage?
    private var storedErrorDescription: String?

    var image: CGImage? {
        lock.withLock { storedImage }
    }

    var errorDescription: String? {
        lock.withLock { storedErrorDescription }
    }

    func set(image: CGImage?, error: Error?) {
        lock.withLock {
            storedImage = image
            storedErrorDescription = error?.localizedDescription
        }
    }
}
