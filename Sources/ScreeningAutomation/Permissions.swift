import AppKit
import CoreGraphics
import Foundation

@MainActor
final class PermissionStatus: ObservableObject {
    @Published private(set) var accessibilityAllowed = AXIsProcessTrusted()
    @Published private(set) var screenCaptureAllowed = ScreenCapturePermission.allowed

    private var refreshTimer: Timer?
    private var lastLoggedAccessibilityAllowed: Bool?
    private var lastLoggedScreenCaptureAllowed: Bool?

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
        let nextScreenCaptureAllowed = ScreenCapturePermission.allowed
        if lastLoggedAccessibilityAllowed != nextAccessibilityAllowed ||
            lastLoggedScreenCaptureAllowed != nextScreenCaptureAllowed {
            DiagnosticLog.write("permissions refresh ax=\(nextAccessibilityAllowed) screen=\(nextScreenCaptureAllowed)")
            lastLoggedAccessibilityAllowed = nextAccessibilityAllowed
            lastLoggedScreenCaptureAllowed = nextScreenCaptureAllowed
        }

        if accessibilityAllowed != nextAccessibilityAllowed {
            accessibilityAllowed = nextAccessibilityAllowed
        }
        if screenCaptureAllowed != nextScreenCaptureAllowed {
            screenCaptureAllowed = nextScreenCaptureAllowed
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
}
