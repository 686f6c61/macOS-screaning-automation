// Captura de imagen de una zona de pantalla, sin estado ni interfaz.
//
// Estrategia:
// 1. ScreenCaptureKit (`SCScreenshotManager`, macOS 15.2+).
// 2. `/usr/sbin/screencapture` como respaldo ante fallos transitorios o en
//    sistemas anteriores, pero solo con el permiso confirmado: sin permiso,
//    `screencapture` guarda el fondo de escritorio y parece una captura válida.
//
// Todo se ejecuta fuera del hilo principal; las esperas son síncronas con
// tope de tiempo porque el llamador ya está en una cola de fondo.

import AppKit
import Darwin
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Lo necesario para una captura: zona, carpeta y formato.
struct CaptureRequest {
    var region: CaptureRegion
    var outputFolderPath: String
    var imageFormat: ImageFormat
}

/// Errores de captura con mensaje para el usuario.
enum CaptureError: Error, LocalizedError {
    case missingRegion
    case processFailed(Int32, String)
    case processTimedOut
    case invalidImage
    case coreGraphicsFailed
    /// TCC deniega Grabación de pantalla. No se recurre a `screencapture`
    /// porque sin permiso guarda solo el fondo de escritorio.
    case screenRecordingDenied
    /// No se pudo confirmar el permiso (timeout, pantalla bloqueada). No se
    /// trata como denegación: suele resolverse reintentando.
    case permissionUnconfirmed

    var errorDescription: String? {
        switch self {
        case .screenRecordingDenied:
            return L10n.t("Falta el permiso de Grabacion de pantalla. Activalo en Ajustes y reinicia la app.")
        case .permissionUnconfirmed:
            return L10n.t("No se pudo confirmar el permiso de Grabacion de pantalla; vuelve a intentarlo.")
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

/// Motor de captura de imagen.
enum CaptureEngine {
    /// Tope de espera para ScreenCaptureKit.
    static let screenCaptureKitTimeout: TimeInterval = 8
    /// Tope de espera para el proceso `screencapture`.
    static let screencaptureTimeout: TimeInterval = 12

    /// Captura la zona y la guarda en disco. Debe llamarse fuera del hilo principal.
    ///
    /// - Returns: la URL del archivo guardado, o un error; un permiso denegado
    ///   llega como `CaptureError.screenRecordingDenied`.
    static func capture(_ request: CaptureRequest) -> Result<URL, Error> {
        let fileURL: URL
        do {
            fileURL = try CaptureFiles.makeURL(
                in: request.outputFolderPath,
                fileExtension: request.imageFormat.fileExtension
            )
        } catch {
            return .failure(error)
        }

        switch captureWithScreenCaptureKit(request: request, fileURL: fileURL) {
        case .saved:
            CaptureFiles.harden(at: fileURL)
            return .success(fileURL)
        case .permissionDenied:
            return .failure(CaptureError.screenRecordingDenied)
        case .unavailable:
            break
        }

        switch ScreenCapturePermission.allowed ? .granted : ScreenCapturePermission.checkAccess() {
        case .granted:
            break
        case .denied:
            DiagnosticLog.write("screencapture fallback skipped reason=permission-denied")
            return .failure(CaptureError.screenRecordingDenied)
        case .unknown:
            DiagnosticLog.write("screencapture fallback skipped reason=permission-unconfirmed")
            return .failure(CaptureError.permissionUnconfirmed)
        }

        DiagnosticLog.write("screencapture fallback started")
        if let error = runScreenCapture(request: request, fileURL: fileURL) {
            CaptureFiles.remove(at: fileURL)
            return .failure(error)
        }
        CaptureFiles.harden(at: fileURL)
        return .success(fileURL)
    }

    // MARK: ScreenCaptureKit

    /// Resultado de intentar la captura con ScreenCaptureKit.
    private enum ScreenCaptureKitOutcome {
        case saved
        case permissionDenied
        /// Error transitorio, timeout, imagen vacía o sistema sin soporte:
        /// procede intentar con `screencapture`.
        case unavailable
    }

    private static func captureWithScreenCaptureKit(request: CaptureRequest, fileURL: URL) -> ScreenCaptureKitOutcome {
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

        guard semaphore.wait(timeout: .now() + screenCaptureKitTimeout) == .success else {
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
        guard !imageLooksLikeMissingPermission(image) else {
            DiagnosticLog.write("screen capture kit produced blank image without permission")
            return .unavailable
        }
        guard write(image: image, format: request.imageFormat, to: fileURL) else {
            DiagnosticLog.write("screen capture kit image could not be written")
            CaptureFiles.remove(at: fileURL)
            return .unavailable
        }
        return .saved
    }

    private static func write(image: CGImage, format: ImageFormat, to fileURL: URL) -> Bool {
        let type: UTType
        switch format {
        case .png:
            type = .png
        case .jpg:
            type = .jpeg
        case .pdf:
            type = .pdf
        case .tiff:
            type = .tiff
        }
        guard let destination = CGImageDestinationCreateWithURL(fileURL as CFURL, type.identifier as CFString, 1, nil) else {
            return false
        }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }

    // MARK: screencapture

    private static func runScreenCapture(request: CaptureRequest, fileURL: URL) -> CaptureError? {
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
        guard processFinished.wait(timeout: .now() + screencaptureTimeout) == .success else {
            // Primero SIGTERM; si sigue vivo, SIGKILL.
            process.terminate()
            if processFinished.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = processFinished.wait(timeout: .now() + 1)
            }
            DiagnosticLog.write("screencapture timed out")
            return .processTimedOut
        }

        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let details = [errorData, outputData]
                .map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
                .replacingOccurrences(of: request.outputFolderPath, with: "<output>")
            DiagnosticLog.write("screencapture failed status=\(process.terminationStatus) details=\(details)")
            return .processFailed(process.terminationStatus, details)
        }

        guard capturedFileIsValid(at: fileURL) else {
            DiagnosticLog.write("screencapture produced invalid or blank image")
            return .invalidImage
        }
        return nil
    }

    private static func capturedFileIsValid(at fileURL: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width > 0,
              image.height > 0 else {
            return false
        }
        return !imageLooksLikeMissingPermission(image)
    }

    /// Una imagen totalmente negra o transparente es el síntoma típico de
    /// capturar sin permiso, pero también puede ser contenido legítimo (un
    /// terminal, un vídeo oscuro). Solo se descarta si el sistema no confirma
    /// el permiso de Grabación de pantalla.
    private static func imageLooksLikeMissingPermission(_ image: CGImage) -> Bool {
        !ScreenCapturePermission.allowed && CaptureImageInspector.isLikelyBlank(image)
    }
}

/// Heurística para detectar capturas vacías.
enum CaptureImageInspector {
    /// Lado de la miniatura que se analiza; basta para detectar una imagen
    /// uniforme sin recorrer todos los píxeles.
    private static let sampleSize = 32
    /// Por debajo de este alfa un píxel se considera transparente.
    private static let minimumVisibleAlpha: UInt8 = 2
    /// Suma RGB por debajo de la cual un píxel se considera negro.
    private static let maximumBlackChannelSum = 6

    /// `true` si la imagen es completamente transparente o negra.
    static func isLikelyBlank(_ image: CGImage) -> Bool {
        let bytesPerPixel = 4
        let bytesPerRow = sampleSize * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: sampleSize * sampleSize * bytesPerPixel)
        guard let context = CGContext(
            data: &pixels,
            width: sampleSize,
            height: sampleSize,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return false
        }

        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize))

        var visiblePixels = 0
        var nonBlackPixels = 0
        for index in stride(from: 0, to: pixels.count, by: bytesPerPixel) {
            guard pixels[index + 3] > minimumVisibleAlpha else {
                continue
            }
            visiblePixels += 1
            if Int(pixels[index]) + Int(pixels[index + 1]) + Int(pixels[index + 2]) > maximumBlackChannelSum {
                nonBlackPixels += 1
            }
        }

        return visiblePixels == 0 || nonBlackPixels == 0
    }
}
