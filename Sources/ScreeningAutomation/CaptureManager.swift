import AppKit
import ImageIO
import Foundation
import UniformTypeIdentifiers

struct CaptureRequest {
    var region: CaptureRegion
    var outputFolderPath: String
    var imageFormat: ImageFormat
}

enum CaptureError: Error, LocalizedError {
    case missingRegion
    case processFailed(Int32, String)
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
        case .coreGraphicsFailed:
            return "No se pudo crear imagen de la zona."
        }
    }
}

@MainActor
final class CaptureManager: ObservableObject {
    @Published private(set) var isCapturing = false
    @Published private(set) var lastCaptureURL: URL?
    @Published private(set) var lastMessage = "Listo"
    @Published private(set) var lastCaptureSucceeded = false

    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
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
        lastMessage = "Capturando..."
        DiagnosticLog.write("capture started source=\(source) region=\(request.region.screencaptureArgument) output=\(request.outputFolderPath)")

        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.performCapture(request: request)
            DispatchQueue.main.async {
                self.isCapturing = false
                switch result {
                case .success(let url):
                    self.lastCaptureURL = url
                    self.lastCaptureSucceeded = true
                    self.lastMessage = "Guardado: \(url.lastPathComponent)"
                    DiagnosticLog.write("capture succeeded file=\(url.path)")
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

    nonisolated private static func performCapture(request: CaptureRequest) -> Result<URL, Error> {
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
            try process.run()
            process.waitUntilExit()

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
                DiagnosticLog.write("screencapture failed status=\(process.terminationStatus) details=\(details)")
                if captureWithCoreGraphics(request: request, fileURL: fileURL) {
                    DiagnosticLog.write("core graphics fallback succeeded file=\(fileURL.path)")
                    return .success(fileURL)
                }
                DiagnosticLog.write("core graphics fallback failed")
                return .failure(CaptureError.processFailed(process.terminationStatus, details))
            }
            return .success(fileURL)
        } catch {
            return .failure(error)
        }
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
        guard !isLikelyBlank(image) else {
            try? FileManager.default.removeItem(at: fileURL)
            DiagnosticLog.write("core graphics fallback produced blank image")
            return false
        }
        let type = request.imageFormat == .jpg ? UTType.jpeg.identifier as CFString : UTType.png.identifier as CFString
        guard let destination = CGImageDestinationCreateWithURL(fileURL as CFURL, type, 1, nil) else {
            return false
        }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }

    nonisolated private static func isLikelyBlank(_ image: CGImage) -> Bool {
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

        var minValue = UInt8.max
        var maxValue = UInt8.min
        var brightPixels = 0
        for index in stride(from: 0, to: pixels.count, by: bytesPerPixel) {
            let red = pixels[index]
            let green = pixels[index + 1]
            let blue = pixels[index + 2]
            minValue = min(minValue, red, green, blue)
            maxValue = max(maxValue, red, green, blue)
            if Int(red) + Int(green) + Int(blue) > 18 {
                brightPixels += 1
            }
        }

        return maxValue <= 8 || (maxValue - minValue <= 3 && brightPixels < 4)
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
