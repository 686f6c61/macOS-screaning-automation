import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

@MainActor
final class PermissionStatus: ObservableObject {
    typealias PermissionProbe = @Sendable () -> Bool

    @Published private(set) var inputMonitoringAllowed: Bool
    @Published private(set) var screenCaptureAllowed: Bool

    private let inputMonitoringProbe: PermissionProbe
    private let screenCapturePreflightProbe: PermissionProbe
    private let screenCaptureAccessProbe: PermissionProbe
    private var refreshTimer: Timer?
    private var lastLoggedInputMonitoringAllowed: Bool?
    private var lastLoggedScreenCaptureAllowed: Bool?
    private var screenCaptureProbeAllowed = false
    private var screenCaptureProbeInFlight = false
    private var lastScreenCaptureProbeDate = Date.distantPast

    init(
        inputMonitoringProbe: @escaping PermissionProbe = { InputMonitoringPermission.allowed },
        screenCapturePreflightProbe: @escaping PermissionProbe = { ScreenCapturePermission.allowed },
        screenCaptureAccessProbe: @escaping PermissionProbe = { ScreenCapturePermission.probeAccess() }
    ) {
        self.inputMonitoringProbe = inputMonitoringProbe
        self.screenCapturePreflightProbe = screenCapturePreflightProbe
        self.screenCaptureAccessProbe = screenCaptureAccessProbe
        inputMonitoringAllowed = inputMonitoringProbe()
        screenCaptureAllowed = screenCapturePreflightProbe()
    }

    var allAllowed: Bool {
        inputMonitoringAllowed && screenCaptureAllowed
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
        let nextInputMonitoringAllowed = inputMonitoringProbe()
        let preflightScreenCaptureAllowed = screenCapturePreflightProbe()
        let nextScreenCaptureAllowed = preflightScreenCaptureAllowed || screenCaptureProbeAllowed
        if lastLoggedInputMonitoringAllowed != nextInputMonitoringAllowed ||
            lastLoggedScreenCaptureAllowed != nextScreenCaptureAllowed {
            DiagnosticLog.write("permissions refresh input=\(nextInputMonitoringAllowed) screen=\(nextScreenCaptureAllowed) preflight=\(preflightScreenCaptureAllowed) probe=\(screenCaptureProbeAllowed)")
            lastLoggedInputMonitoringAllowed = nextInputMonitoringAllowed
            lastLoggedScreenCaptureAllowed = nextScreenCaptureAllowed
        }

        if inputMonitoringAllowed != nextInputMonitoringAllowed {
            inputMonitoringAllowed = nextInputMonitoringAllowed
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
        let screenCaptureAccessProbe = screenCaptureAccessProbe
        DispatchQueue.global(qos: .utility).async {
            let allowed = screenCaptureAccessProbe()
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

enum InputMonitoringPermission {
    static var allowed: Bool {
        CGPreflightListenEventAccess()
    }

    @discardableResult
    static func request() -> Bool {
        CGRequestListenEventAccess()
    }

    static func openSettings() {
        openPrivacyPane(anchor: "Privacy_ListenEvent")
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

        return shareableContentIsAvailable()
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
