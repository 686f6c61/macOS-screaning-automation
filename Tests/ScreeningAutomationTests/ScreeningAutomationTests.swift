import CoreGraphics
import Foundation
import XCTest
@testable import ScreeningAutomation

final class CaptureRegionTests: XCTestCase {
    func testConvertsSelectionToCaptureCoordinates() {
        let createdAt = Date(timeIntervalSince1970: 123)
        let region = CaptureRegion.fromSelection(
            localRect: CGRect(x: 100, y: 200, width: 500, height: 300),
            screenFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
            virtualMaxY: 1200,
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
            virtualMaxY: 100,
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
            virtualMaxY: 1080,
            displayName: "Below"
        )

        XCTAssertEqual(region.x, 40)
        XCTAssertEqual(region.y, 1810)
        XCTAssertEqual(region.width, 600)
        XCTAssertEqual(region.height, 250)
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
            screenCaptureAccessProbe: { true }
        )
        let missingInput = PermissionStatus(
            inputMonitoringProbe: { false },
            screenCapturePreflightProbe: { true },
            screenCaptureAccessProbe: { true }
        )
        let missingCapture = PermissionStatus(
            inputMonitoringProbe: { true },
            screenCapturePreflightProbe: { false },
            screenCaptureAccessProbe: { false }
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
