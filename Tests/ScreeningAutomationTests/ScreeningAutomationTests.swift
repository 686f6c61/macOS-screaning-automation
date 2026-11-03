import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import XCTest
@testable import ScreeningAutomation

final class CaptureRegionTests: XCTestCase {
    func testConvertsSelectionToCaptureCoordinates() {
        let createdAt = Date(timeIntervalSince1970: 123)
        let region = CaptureRegion.fromSelection(
            localRect: CGRect(x: 100, y: 200, width: 500, height: 300),
            screenFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
            primaryScreenMaxY: 1200,
            displayName: "External",
            createdAt: createdAt
        )

        XCTAssertEqual(region.x, -1820)
        XCTAssertEqual(region.y, 700)
        XCTAssertEqual(region.width, 500)
        XCTAssertEqual(region.height, 300)
        XCTAssertEqual(region.displayName, "External")
        XCTAssertEqual(region.createdAt, createdAt)
    }

    func testRoundsAndClampsSmallSelections() {
        let region = CaptureRegion.fromSelection(
            localRect: CGRect(x: 1.6, y: 2.4, width: 0.2, height: 0.4),
            screenFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            primaryScreenMaxY: 100,
            displayName: "Test"
        )

        XCTAssertEqual(region.x, 2)
        XCTAssertEqual(region.y, 97)
        XCTAssertEqual(region.width, 1)
        XCTAssertEqual(region.height, 1)
    }

    func testConvertsSelectionOnDisplayBelowPrimaryScreen() {
        let region = CaptureRegion.fromSelection(
            localRect: CGRect(x: 40, y: 100, width: 600, height: 250),
            screenFrame: CGRect(x: 0, y: -1080, width: 1920, height: 1080),
            primaryScreenMaxY: 1080,
            displayName: "Below"
        )

        XCTAssertEqual(region.x, 40)
        XCTAssertEqual(region.y, 1810)
        XCTAssertEqual(region.width, 600)
        XCTAssertEqual(region.height, 250)
    }

    /// Monitor de 2560x1440 colocado encima de un portátil de 1920x1080. En
    /// Quartz, todo lo que está por encima de la pantalla principal tiene Y
    /// negativa; tomar el `maxY` de todas las pantallas daba Y = 100.
    func testConvertsSelectionOnDisplayAbovePrimaryScreen() {
        let region = CaptureRegion.fromSelection(
            localRect: CGRect(x: 0, y: 1240, width: 300, height: 100),
            screenFrame: CGRect(x: 0, y: 1080, width: 2560, height: 1440),
            primaryScreenMaxY: 1080,
            displayName: "Above"
        )

        XCTAssertEqual(region.y, -1340)
    }

    func testCornerDetectionUsesEachPhysicalScreen() {
        // Pantalla secundaria más baja y desplazada: la esquina superior derecha
        // del rectángulo envolvente (3840, 1080) no existe en ninguna pantalla.
        let screens = [
            CGRect(x: 0, y: 0, width: 1920, height: 1080),
            CGRect(x: 1920, y: -400, width: 1920, height: 1080)
        ]
        XCTAssertTrue(ScreenGeometry.isInCorner(CGPoint(x: 3830, y: 670), corner: .topRight, screens: screens))
        XCTAssertTrue(ScreenGeometry.isInCorner(CGPoint(x: 1910, y: 1070), corner: .topRight, screens: screens))
        XCTAssertFalse(ScreenGeometry.isInCorner(CGPoint(x: 960, y: 540), corner: .topRight, screens: screens))
    }
}

final class ClickBurstDetectorTests: XCTestCase {
    func testTriggersAtTargetWithinWindow() {
        var detector = ClickBurstDetector()
        let start = Date(timeIntervalSince1970: 1_000)

        XCTAssertEqual(register(&detector, at: start), .progress)
        XCTAssertEqual(register(&detector, at: start.addingTimeInterval(0.1)), .progress)
        XCTAssertEqual(register(&detector, at: start.addingTimeInterval(0.2)), .triggered)
        XCTAssertEqual(detector.progressCount, 0)
    }

    func testRejectsDuplicatesAndClicksDuringCooldown() {
        var detector = ClickBurstDetector()
        let start = Date(timeIntervalSince1970: 2_000)

        XCTAssertEqual(register(&detector, at: start), .progress)
        XCTAssertEqual(register(&detector, at: start.addingTimeInterval(0.01)), .duplicate)
        XCTAssertEqual(register(&detector, at: start.addingTimeInterval(0.1)), .progress)
        XCTAssertEqual(register(&detector, at: start.addingTimeInterval(0.2)), .triggered)
        XCTAssertEqual(register(&detector, at: start.addingTimeInterval(0.4)), .coolingDown)
        XCTAssertEqual(detector.progressCount, 0)
        XCTAssertEqual(register(&detector, at: start.addingTimeInterval(1.3)), .progress)
    }

    func testDropsClicksOutsideWindow() {
        var detector = ClickBurstDetector()
        let start = Date(timeIntervalSince1970: 3_000)

        XCTAssertEqual(register(&detector, at: start), .progress)
        XCTAssertEqual(register(&detector, at: start.addingTimeInterval(0.1)), .progress)
        XCTAssertEqual(register(&detector, at: start.addingTimeInterval(1.2)), .progress)
        XCTAssertEqual(detector.progressCount, 1)
    }

    private func register(_ detector: inout ClickBurstDetector, at date: Date) -> ClickBurstOutcome {
        detector.registerClick(
            at: date,
            targetCount: 3,
            windowSeconds: 1,
            cooldownSeconds: 1
        )
    }
}

final class CaptureImageInspectorTests: XCTestCase {
    func testRejectsOpaqueBlackImage() throws {
        let image = try makeImage(red: 0, green: 0, blue: 0, alpha: 1)
        XCTAssertTrue(CaptureImageInspector.isLikelyBlank(image))
    }

    func testAcceptsVisibleNearBlackImage() throws {
        let image = try makeImage(red: 0.02, green: 0.02, blue: 0.02, alpha: 1)
        XCTAssertFalse(CaptureImageInspector.isLikelyBlank(image))
    }

    func testRejectsTransparentImage() throws {
        let image = try makeImage(red: 1, green: 1, blue: 1, alpha: 0)
        XCTAssertTrue(CaptureImageInspector.isLikelyBlank(image))
    }

    private func makeImage(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) throws -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: 64,
            height: 64,
            bitsPerComponent: 8,
            bytesPerRow: 64 * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw TestError.imageCreationFailed
        }
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: alpha))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        guard let image = context.makeImage() else {
            throw TestError.imageCreationFailed
        }
        return image
    }
}

final class LocalPrivacyTests: XCTestCase {
    func testDiagnosticMessagesRedactPersonalPaths() {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        let message = "home=\(homePath)/Documents/capture.png volume=/Volumes/Shared/capture.png url=file:///tmp/capture.png"
        let sanitized = DiagnosticLog.sanitizedMessage(message)

        XCTAssertFalse(sanitized.contains(homePath))
        XCTAssertFalse(sanitized.contains("/Volumes/"))
        XCTAssertFalse(sanitized.contains("file://"))
        XCTAssertTrue(sanitized.contains("<home>"))
        XCTAssertTrue(sanitized.contains("<path>"))
    }

    func testCaptureFilesArePrivate() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreeningAutomationTests-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try Data([0]).write(to: fileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
        CaptureManager.hardenCaptureFile(at: fileURL)

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o600))
    }
}

@MainActor
final class AppSettingsTests: XCTestCase {
    func testPersistedValuesAreClampedWhenLoaded() throws {
        let suiteName = "ScreeningAutomationTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw TestError.defaultsCreationFailed
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        settings.clickCount = 99
        settings.clickWindowSeconds = -1
        settings.triggerCooldownSeconds = 99
        settings.hoverGestureTimeoutSeconds = 0
        settings.armedCaptureDelaySeconds = 1
        settings.armedCaptureIntervalSeconds = 99
        settings.armedCaptureCount = 999

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.clickCount, 12)
        XCTAssertEqual(reloaded.clickWindowSeconds, 0.4)
        XCTAssertEqual(reloaded.triggerCooldownSeconds, 15)
        XCTAssertEqual(reloaded.hoverGestureTimeoutSeconds, 0.8)
        XCTAssertEqual(reloaded.armedCaptureDelaySeconds, 2)
        XCTAssertEqual(reloaded.armedCaptureIntervalSeconds, 30)
        XCTAssertEqual(reloaded.armedCaptureCount, 120)
    }
}

@MainActor
final class PermissionStatusTests: XCTestCase {
    func testReportsReadyOnlyWhenBothPermissionsAreAllowed() {
        let ready = PermissionStatus(
            inputMonitoringProbe: { true },
            screenCapturePreflightProbe: { true },
            screenCaptureAccessProbe: { .granted }
        )
        let missingInput = PermissionStatus(
            inputMonitoringProbe: { false },
            screenCapturePreflightProbe: { true },
            screenCaptureAccessProbe: { .granted }
        )
        let missingCapture = PermissionStatus(
            inputMonitoringProbe: { true },
            screenCapturePreflightProbe: { false },
            screenCaptureAccessProbe: { .denied }
        )

        XCTAssertTrue(ready.allAllowed)
        XCTAssertEqual(ready.summary, "Permisos OK")
        XCTAssertFalse(missingInput.allAllowed)
        XCTAssertEqual(missingInput.summary, "Permisos pendientes")
        XCTAssertFalse(missingCapture.allAllowed)
        XCTAssertEqual(missingCapture.summary, "Permisos pendientes")
    }
}

@MainActor
final class EventTapMonitorTests: XCTestCase {
    func testSimulatedClickBurstTriggersCaptureCallback() throws {
        let suiteName = "ScreeningAutomationTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw TestError.defaultsCreationFailed
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        settings.clickCount = 3
        settings.clickWindowSeconds = 1
        settings.triggerCooldownSeconds = 1
        settings.triggersPaused = false

        var triggerSources: [String] = []
        let monitor = EventTapMonitor(settings: settings) { source in
            triggerSources.append(source)
        }

        monitor.simulateClickBurst()

        XCTAssertEqual(triggerSources, ["clicks"])
        XCTAssertEqual(monitor.clickProgressDescription, "0/3")
        XCTAssertEqual(monitor.lastTriggerDescription, "Disparo por simulacion")
    }
}

@MainActor
final class ArmedCaptureTests: XCTestCase {
    func testCancelledCompletionCannotFinishNewSession() async throws {
        let suiteName = "ScreeningAutomationTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw TestError.defaultsCreationFailed
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        settings.selectedRegion = CaptureRegion(
            x: 0,
            y: 0,
            width: 100,
            height: 100,
            displayName: "Test",
            createdAt: Date()
        )
        settings.armedCaptureDelaySeconds = 2
        settings.armedCaptureIntervalSeconds = 0.5
        settings.armedCaptureCount = 1

        let executor = SequencedCaptureExecutor()
        let manager = CaptureManager(
            settings: settings,
            captureSettleDelay: 0,
            captureExecutor: executor.capture
        )

        manager.startArmedBurst()
        let firstCaptureStarted = await waitUntil { executor.startedCount == 1 }
        XCTAssertTrue(firstCaptureStarted)

        manager.cancelArmedBurst()
        manager.startArmedBurst()
        executor.releaseCapture(number: 1)

        let cancelledCaptureFinished = await waitUntil { !manager.isCapturing }
        XCTAssertTrue(cancelledCaptureFinished)
        XCTAssertTrue(manager.armedCaptureActive)

        let secondCaptureStarted = await waitUntil(timeout: 3.5) { executor.startedCount == 2 }
        XCTAssertTrue(secondCaptureStarted)
        executor.releaseCapture(number: 2)

        let secondSessionFinished = await waitUntil { !manager.armedCaptureActive }
        XCTAssertTrue(secondSessionFinished)
        XCTAssertEqual(manager.lastCaptureURL?.lastPathComponent, "capture-2.png")
        XCTAssertTrue(manager.lastCaptureSucceeded)
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }
}

final class ImageFormatTests: XCTestCase {
    func testExtensionsAndScreencaptureTokens() {
        XCTAssertEqual(ImageFormat.png.fileExtension, "png")
        XCTAssertEqual(ImageFormat.jpg.fileExtension, "jpg")
        XCTAssertEqual(ImageFormat.pdf.fileExtension, "pdf")
        XCTAssertEqual(ImageFormat.tiff.fileExtension, "tiff")
        XCTAssertEqual(ImageFormat.png.screencaptureToken, "png")
        XCTAssertEqual(ImageFormat.tiff.screencaptureToken, "tif")
        XCTAssertEqual(ImageFormat.allCases.count, 4)
    }
}

final class VideoRegionResolverTests: XCTestCase {
    func testResolvesRegionToContainingDisplay() {
        let descriptors = [
            VideoRegionDescriptor(displayID: 1, quartzBounds: CGRect(x: 0, y: 0, width: 1920, height: 1080), scale: 2),
            VideoRegionDescriptor(displayID: 2, quartzBounds: CGRect(x: 1920, y: 0, width: 1920, height: 1080), scale: 1)
        ]
        let region = CaptureRegion(x: 2100, y: 100, width: 400, height: 300, displayName: "External", createdAt: Date())

        let resolved = VideoRegionResolver.resolve(region: region, descriptors: descriptors)

        XCTAssertEqual(resolved?.displayID, 2)
        XCTAssertEqual(resolved?.localRect, CGRect(x: 180, y: 100, width: 400, height: 300))
        XCTAssertEqual(resolved?.scale, 1)
    }

    func testReturnsNilWhenRegionOutsideDisplays() {
        let descriptors = [
            VideoRegionDescriptor(displayID: 1, quartzBounds: CGRect(x: 0, y: 0, width: 1920, height: 1080), scale: 2)
        ]
        let region = CaptureRegion(x: 5000, y: 100, width: 100, height: 100, displayName: "Nadie", createdAt: Date())

        XCTAssertNil(VideoRegionResolver.resolve(region: region, descriptors: descriptors))
    }
}

final class VideoWriterSessionTests: XCTestCase {
    /// Regresión de 96013dd: un escritor recién creado está en `.unknown` y
    /// la sesión debe arrancarlo con el primer fotograma, no descartarlo.
    func testWritesPlayableFileFromSyntheticFrames() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreeningAutomationTests-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }

        let session = try VideoWriterSession(url: url, pixelWidth: 64, pixelHeight: 64)
        for index in 0..<10 {
            let buffer = try SyntheticFrames.sampleBuffer(width: 64, height: 64, frameIndex: index)
            session.queue.sync { session.append(buffer) }
        }

        let result = await withCheckedContinuation { continuation in
            session.finish { continuation.resume(returning: $0) }
        }

        XCTAssertNoThrow(try result.get())
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        XCTAssertGreaterThan(size?.intValue ?? 0, 0)
    }

    /// Con el escritor fuera de `.writing` tras haber empezado la sesión (aquí,
    /// cancelado), `finish` no debe llamar a `finishWriting`: lanzaría una
    /// excepción de Objective-C que tumba la app. Es el mismo camino que sigue
    /// un escritor que falla a mitad de grabación.
    func testFinishAfterWriterLeftWritingStateDoesNotCrash() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreeningAutomationTests-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }

        let session = try VideoWriterSession(url: url, pixelWidth: 64, pixelHeight: 64)
        for index in 0..<3 {
            let buffer = try SyntheticFrames.sampleBuffer(width: 64, height: 64, frameIndex: index)
            session.queue.sync { session.append(buffer) }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.discard { continuation.resume() }
        }

        let result = await withCheckedContinuation { continuation in
            session.finish { continuation.resume(returning: $0) }
        }

        guard case .failure(.writerFailed) = result else {
            return XCTFail("Se esperaba writerFailed y llegó \(result)")
        }
    }

    func testFinishWithoutFramesReportsNoFrames() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreeningAutomationTests-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }

        let session = try VideoWriterSession(url: url, pixelWidth: 64, pixelHeight: 64)
        let result = await withCheckedContinuation { continuation in
            session.finish { continuation.resume(returning: $0) }
        }

        XCTAssertThrowsError(try result.get()) { error in
            XCTAssertEqual(error as? VideoWriterError, .noFrames)
        }
    }

    func testEncoderSizeIsEvenAndCappedPreservingAspect() {
        XCTAssertTrue(VideoWriterSession.encoderSize(width: 301, height: 101) == (300, 100))
        XCTAssertTrue(VideoWriterSession.encoderSize(width: 1, height: 1) == (2, 2))
        XCTAssertTrue(VideoWriterSession.encoderSize(width: 9000, height: 3000) == (4096, 1364))
    }
}

/// Genera `CMSampleBuffer` de vídeo sin depender de ScreenCaptureKit.
private enum SyntheticFrames {
    static func sampleBuffer(width: Int, height: Int, frameIndex: Int) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes,
            &pixelBuffer
        ) == kCVReturnSuccess, let pixelBuffer else {
            throw TestError.imageCreationFailed
        }

        var formatDescription: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard let formatDescription else {
            throw TestError.imageCreationFailed
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(value: CMTimeValue(frameIndex), timescale: 30),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard let sampleBuffer else {
            throw TestError.imageCreationFailed
        }
        return sampleBuffer
    }
}

@MainActor
final class VideoRecorderStateTests: XCTestCase {
    /// Detener mientras la captura aún arranca (por ejemplo, con el aviso de TCC
    /// abierto) debe descartar la captura cuando por fin arranque.
    func testStopWhileStartingDiscardsCaptureOnceItStarts() async throws {
        let source = FakeVideoSource()
        source.holdStart = true
        let recorder = VideoRecorder(settings: try makeSettings(), source: source)

        recorder.start()
        let ready1 = await waitUntil { source.startCount == 1 }
        XCTAssertTrue(ready1)
        let saved = await recorder.stop()
        source.releaseStart()

        XCTAssertFalse(saved)
        let ready2 = await waitUntil { source.handle.discarded }
        XCTAssertTrue(ready2)
        XCTAssertFalse(recorder.isRecording)
        XCTAssertFalse(recorder.isBusy)
        XCTAssertFalse(source.handle.finished)
    }

    func testInterruptionSavesWhatWasRecorded() async throws {
        let source = FakeVideoSource()
        let recorder = VideoRecorder(settings: try makeSettings(), source: source)

        recorder.start()
        let ready3 = await waitUntil { recorder.isRecording && source.startCount == 1 && !recorder.lastMessage.contains("...") }
        XCTAssertTrue(ready3)
        source.interrupt("permiso retirado")

        let ready4 = await waitUntil { !recorder.isBusy }
        XCTAssertTrue(ready4)
        XCTAssertTrue(source.handle.finished)
        XCTAssertTrue(recorder.lastMessage.contains("permiso retirado"))
    }

    /// Una segunda llamada a `stop()` (p. ej., al salir de la app) durante el
    /// cierre espera a ese mismo cierre en vez de devolver al instante.
    func testConcurrentStopWaitsForTheSameFinalization() async throws {
        let source = FakeVideoSource()
        source.handle.holdFinish = true
        let recorder = VideoRecorder(settings: try makeSettings(), source: source)

        recorder.start()
        let ready5 = await waitUntil { recorder.isRecording && source.startCount == 1 && !recorder.lastMessage.contains("...") }
        XCTAssertTrue(ready5)
        async let first = recorder.stop()
        let ready6 = await waitUntil { source.handle.finishCalls == 1 }
        XCTAssertTrue(ready6)
        async let second = recorder.stop()
        XCTAssertTrue(recorder.isBusy)
        source.handle.releaseFinish()

        let results = await (first, second)
        XCTAssertTrue(results.0)
        XCTAssertTrue(results.1)
        XCTAssertEqual(source.handle.finishCalls, 1)
        XCTAssertFalse(recorder.isBusy)
    }

    func testFinalizeFailureKeepsFileAndReportsIt() async throws {
        let source = FakeVideoSource()
        source.handle.finishResult = .failure(.writerFailed("disco lleno"))
        let recorder = VideoRecorder(settings: try makeSettings(), source: source)

        recorder.start()
        let ready7 = await waitUntil { recorder.isRecording && source.startCount == 1 && !recorder.lastMessage.contains("...") }
        XCTAssertTrue(ready7)
        let saved = await recorder.stop()

        XCTAssertFalse(saved)
        XCTAssertTrue(recorder.lastMessage.contains(source.handle.fileURL.lastPathComponent))
    }

    private func makeSettings() throws -> AppSettings {
        let suiteName = "ScreeningAutomationTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw TestError.defaultsCreationFailed
        }
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        settings.selectedRegion = CaptureRegion(x: 0, y: 0, width: 100, height: 100, displayName: "Test", createdAt: Date())
        settings.outputFolderPath = FileManager.default.temporaryDirectory.path
        return settings
    }
}

@MainActor
private final class FakeVideoSource: VideoCaptureSource {
    let handle = FakeVideoHandle()
    var holdStart = false
    private(set) var startCount = 0
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var onInterrupted: (@Sendable (String) -> Void)?

    func start(
        request: CaptureRequest,
        onInterrupted: @escaping @Sendable (String) -> Void
    ) async throws -> VideoCaptureHandle {
        startCount += 1
        self.onInterrupted = onInterrupted
        if holdStart {
            await withCheckedContinuation { startContinuation = $0 }
        }
        return handle
    }

    func releaseStart() {
        startContinuation?.resume()
        startContinuation = nil
    }

    func interrupt(_ message: String) {
        onInterrupted?(message)
    }
}

@MainActor
private final class FakeVideoHandle: VideoCaptureHandle {
    let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("SA_fake.mp4")
    var holdFinish = false
    var finishResult: Result<Void, VideoWriterError> = .success(())
    private(set) var finishCalls = 0
    private(set) var finished = false
    private(set) var discarded = false
    private var finishContinuation: CheckedContinuation<Void, Never>?

    func stopCapture() async throws {}

    func finish() async -> Result<Void, VideoWriterError> {
        finishCalls += 1
        if holdFinish {
            await withCheckedContinuation { finishContinuation = $0 }
        }
        finished = true
        return finishResult
    }

    func discard() async {
        discarded = true
    }

    func releaseFinish() {
        finishContinuation?.resume()
        finishContinuation = nil
    }
}

/// Espera activa con tope para condiciones que dependen de tareas asíncronas.
@MainActor
private func waitUntil(
    timeout: TimeInterval = 3,
    condition: @escaping @MainActor () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

final class VideoTimeFormatTests: XCTestCase {
    func testFormatsMinutesAndSeconds() {
        XCTAssertEqual(VideoRecorder.format(elapsed: 0), "0:00")
        XCTAssertEqual(VideoRecorder.format(elapsed: 65), "1:05")
        XCTAssertEqual(VideoRecorder.format(elapsed: 600), "10:00")
        XCTAssertEqual(VideoRecorder.format(elapsed: -5), "0:00")
    }
}

@MainActor
final class PermissionAccessCheckTests: XCTestCase {
    /// Cada consulta a ScreenCaptureKit sin permiso válido muestra un aviso del
    /// sistema; el refresco periódico no debe volver a lanzarla.
    func testAccessCheckRunsOnceAtLaunchAndNotOnRefresh() async {
        let calls = LockedBox(0)
        let status = PermissionStatus(
            inputMonitoringProbe: { true },
            screenCapturePreflightProbe: { false },
            screenCaptureAccessProbe: {
                calls.set(calls.get() + 1)
                return .denied
            }
        )

        status.startMonitoring()
        defer { status.stopMonitoring() }
        for _ in 0..<20 {
            status.refresh()
        }
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(calls.get(), 1)
        XCTAssertEqual(status.accessCheckCount, 1)
        XCTAssertFalse(status.screenCaptureAllowed)
    }

    func testGrantedAccessCheckOverridesStalePreflight() async {
        let status = PermissionStatus(
            inputMonitoringProbe: { true },
            screenCapturePreflightProbe: { false },
            screenCaptureAccessProbe: { .granted }
        )

        status.verifyScreenCaptureAccess()
        let deadline = Date().addingTimeInterval(2)
        while !status.screenCaptureAllowed, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertTrue(status.screenCaptureAllowed)
    }

    func testUnknownAccessIsNotReportedAsGranted() async {
        let status = PermissionStatus(
            inputMonitoringProbe: { true },
            screenCapturePreflightProbe: { false },
            screenCaptureAccessProbe: { .unknown }
        )

        status.verifyScreenCaptureAccess()
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertFalse(status.screenCaptureAllowed)
    }
}

final class RecentLogLinesTests: XCTestCase {
    func testRecentLinesReadsTailFromGivenFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreeningAutomationTests-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }
        try (0..<50).map { "linea-\($0)" }.joined(separator: "\n")
            .write(to: url, atomically: true, encoding: .utf8)

        let lines = DiagnosticLog.recentLines(10, from: url)

        XCTAssertEqual(lines.count, 10)
        XCTAssertEqual(lines.first, "linea-40")
        XCTAssertEqual(lines.last, "linea-49")
    }
}

private final class SequencedCaptureExecutor: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let firstRelease = DispatchSemaphore(value: 0)
    private let secondRelease = DispatchSemaphore(value: 0)

    var startedCount: Int {
        lock.withLock { count }
    }

    func capture(_ request: CaptureRequest) -> Result<URL, Error> {
        let number = lock.withLock {
            count += 1
            return count
        }
        if number == 1 {
            firstRelease.wait()
        } else if number == 2 {
            secondRelease.wait()
        }
        return .success(URL(fileURLWithPath: "/tmp/capture-\(number).png"))
    }

    func releaseCapture(number: Int) {
        if number == 1 {
            firstRelease.signal()
        } else if number == 2 {
            secondRelease.signal()
        }
    }
}

private enum TestError: Error {
    case defaultsCreationFailed
    case imageCreationFailed
}
