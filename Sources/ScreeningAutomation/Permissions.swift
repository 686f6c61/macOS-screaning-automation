import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

@MainActor
final class PermissionStatus: ObservableObject {
    @Published private(set) var accessibilityAllowed = AXIsProcessTrusted()
    @Published private(set) var screenCaptureAllowed = ScreenCapturePermission.allowed

    private var refreshTimer: Timer?
    private var lastLoggedAccessibilityAllowed: Bool?
    private var lastLoggedScreenCaptureAllowed: Bool?
    private var screenCaptureProbeAllowed = false
    private var screenCaptureProbeInFlight = false
    private var lastScreenCaptureProbeDate = Date.distantPast

    var allAllowed: Bool {
        accessibilityAllowed && screenCaptureAllowed
    }

    var summary: String {
        allAllowed ? "Permisos OK" : "Permisos pendientes"
    }

    func startMonitoring() {
        refresh()
        guard refreshTimer == nil else {
            return
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.refresh()
            }
        }
    }

    func stopMonitoring() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func refresh() {
        let nextAccessibilityAllowed = AXIsProcessTrusted()
        let preflightScreenCaptureAllowed = ScreenCapturePermission.allowed
        let nextScreenCaptureAllowed = preflightScreenCaptureAllowed || screenCaptureProbeAllowed
        if lastLoggedAccessibilityAllowed != nextAccessibilityAllowed ||
            lastLoggedScreenCaptureAllowed != nextScreenCaptureAllowed {
            DiagnosticLog.write("permissions refresh ax=\(nextAccessibilityAllowed) screen=\(nextScreenCaptureAllowed) preflight=\(preflightScreenCaptureAllowed) probe=\(screenCaptureProbeAllowed)")
            lastLoggedAccessibilityAllowed = nextAccessibilityAllowed
            lastLoggedScreenCaptureAllowed = nextScreenCaptureAllowed
        }

        if accessibilityAllowed != nextAccessibilityAllowed {
            accessibilityAllowed = nextAccessibilityAllowed
        }
        if screenCaptureAllowed != nextScreenCaptureAllowed {
            screenCaptureAllowed = nextScreenCaptureAllowed
        }
        if preflightScreenCaptureAllowed {
            screenCaptureProbeAllowed = true
        } else {
            scheduleScreenCaptureProbe()
        }
    }

    private func scheduleScreenCaptureProbe() {
        guard !screenCaptureProbeInFlight else {
            return
        }
        let now = Date()
        guard now.timeIntervalSince(lastScreenCaptureProbeDate) >= 5 else {
            return
        }

        screenCaptureProbeInFlight = true
        lastScreenCaptureProbeDate = now
        DispatchQueue.global(qos: .utility).async {
            let allowed = ScreenCapturePermission.probeAccess()
            DispatchQueue.main.async {
                self.screenCaptureProbeInFlight = false
                if self.screenCaptureProbeAllowed != allowed {
                    self.screenCaptureProbeAllowed = allowed
                    DiagnosticLog.write("screen capture probe changed allowed=\(allowed)")
                }
                self.refresh()
            }
        }
    }
}

enum ScreenCapturePermission {
    static var allowed: Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    static func request() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func openSettings() {
        openPrivacyPane(anchor: "Privacy_ScreenCapture")
    }

    static func probeAccess() -> Bool {
        if allowed {
            return true
        }
        guard #available(macOS 12.3, *) else {
            return false
        }

        guard shareableContentIsAvailable() else {
            return false
        }
        guard #available(macOS 15.2, *) else {
            return true
        }

        let semaphore = DispatchSemaphore(value: 0)
        let result = ScreenCaptureKitImageResult()
        SCScreenshotManager.captureImage(in: CGRect(x: 0, y: 0, width: 1, height: 1)) { image, error in
            result.set(image: image, error: error)
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + 5) == .success else {
            DiagnosticLog.write("screen capture permission probe timed out")
            return false
        }
        if let errorDescription = result.errorDescription {
            DiagnosticLog.write("screen capture permission probe error=\(errorDescription)")
        }
        guard let image = result.image else {
            return false
        }
        return !CaptureImageInspector.isLikelyBlank(image)
    }

    @available(macOS 12.3, *)
    private static func shareableContentIsAvailable() -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        let result = ScreenCaptureKitContentResult()
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
            result.set(
                hasContent: (content?.displays.isEmpty == false || content?.windows.isEmpty == false),
                error: error
            )
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + 5) == .success else {
            DiagnosticLog.write("screen capture content probe timed out")
            return false
        }
        if let errorDescription = result.errorDescription {
            DiagnosticLog.write("screen capture content probe error=\(errorDescription)")
        }
        return result.hasContent
    }
}

final class ScreenCaptureKitContentResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storedHasContent = false
    private var storedErrorDescription: String?

    var hasContent: Bool {
        lock.withLock { storedHasContent }
    }

    var errorDescription: String? {
        lock.withLock { storedErrorDescription }
    }

    func set(hasContent: Bool, error: Error?) {
        lock.withLock {
            storedHasContent = hasContent
            storedErrorDescription = error?.localizedDescription
        }
    }
}
