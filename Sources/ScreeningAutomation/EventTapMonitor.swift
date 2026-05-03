import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

private func eventMask(_ type: CGEventType) -> CGEventMask {
    CGEventMask(1) << CGEventMask(type.rawValue)
}

private func monitorEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else {
        return Unmanaged.passUnretained(event)
    }

    let monitor = Unmanaged<EventTapMonitor>.fromOpaque(refcon).takeUnretainedValue()
    let location = event.location
    DispatchQueue.main.async {
        monitor.handle(type: type, location: location)
    }
    return Unmanaged.passUnretained(event)
}

@MainActor
final class EventTapMonitor: ObservableObject {
    private weak var settings: AppSettings?
    private let onTrigger: (String) -> Void

    @Published private(set) var isRunning = false
    @Published private(set) var backendDescription = "Inactivo"
    @Published private(set) var lastEventDescription = "Sin eventos"
    @Published private(set) var clickProgressDescription = "0/0"
    @Published private(set) var cornerHoldProgressDescription = "Inactivo"
    @Published private(set) var lastTriggerDescription = "Sin disparos"
    @Published private(set) var lastStartError = ""
    @Published private(set) var accessibilityTrusted = AXIsProcessTrusted()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var globalMouseMonitor: Any?
    private var permissionRetryTimer: Timer?
    private var cornerHoldTimer: Timer?
    private var cornerHoldStartedAt: Date?
    private var cornerHoldDidTrigger = false
    private var clickTimes: [Date] = []
    private var lastAcceptedClickDate = Date.distantPast
    private var lastTriggerDate = Date.distantPast

    init(settings: AppSettings, onTrigger: @escaping (String) -> Void) {
        self.settings = settings
        self.onTrigger = onTrigger
    }

    func start() {
        guard eventTap == nil else {
            refreshState()
            return
        }

        accessibilityTrusted = AXIsProcessTrusted()
        DiagnosticLog.write("event monitor start requested axTrusted=\(accessibilityTrusted)")

        let mask = eventMask(.leftMouseDown)
            | eventMask(.tapDisabledByTimeout)
            | eventMask(.tapDisabledByUserInput)

        let createdTap = createEventTap(location: .cghidEventTap, mask: mask)
            ?? createEventTap(location: .cgSessionEventTap, mask: mask)

        guard let createdTap else {
            lastStartError = "CGEventTap no disponible; usando AppKit global."
            DiagnosticLog.write("all event tap create attempts failed; using AppKit global only")
            startGlobalMouseMonitor(backend: "AppKit global")
            startCornerHoldTimer()
            requestAccessibilityPermission()
            schedulePermissionRetry()
            refreshState()
            return
        }

        permissionRetryTimer?.invalidate()
        permissionRetryTimer = nil
        eventTap = createdTap.tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, createdTap.tap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: createdTap.tap, enable: true)
        startGlobalMouseMonitor(backend: "AppKit global")
        startCornerHoldTimer()
        isRunning = true
        backendDescription = "\(createdTap.name) + AppKit"
        lastStartError = ""
        DiagnosticLog.write("event tap running backend=\(createdTap.name)")
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
        }
        runLoopSource = nil
        eventTap = nil
        isRunning = false
        stopGlobalMouseMonitor()
        stopCornerHoldTimer()
        backendDescription = "Inactivo"
        permissionRetryTimer?.invalidate()
        permissionRetryTimer = nil
        clickTimes.removeAll()
        resetCornerHold()
    }

    func requestAccessibilityPermission() {
        let promptKey = "AXTrustedCheckOptionPrompt"
        let options = [
            promptKey: true
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        accessibilityTrusted = AXIsProcessTrusted()
        DiagnosticLog.write("accessibility permission requested axTrusted=\(accessibilityTrusted)")
        schedulePermissionRetry()
    }

    func openAccessibilitySettings() {
        openPrivacyPane(anchor: "Privacy_Accessibility")
    }

    func handle(type: CGEventType, location: CGPoint) {
        refreshTrustStatus()
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            DiagnosticLog.write("event tap re-enabled type=\(type.rawValue)")
            return
        }

        guard let settings, !settings.triggersPaused else {
            return
        }

        switch type {
        case .leftMouseDown:
            handleClick(location: location, backend: backendDescription)
        default:
            break
        }
    }

    func simulateClickBurst() {
        guard let settings else {
            return
        }
        DiagnosticLog.write("simulated click burst count=\(settings.clickCount)")
        for _ in 0..<settings.clickCount {
            handleClick(location: NSEvent.mouseLocation, backend: "simulacion")
        }
    }

    func refreshState() {
        refreshTrustStatus()
        if eventTap != nil {
            isRunning = true
            backendDescription = "CGEventTap"
        } else if globalMouseMonitor != nil {
            isRunning = true
            backendDescription = "AppKit global"
        } else {
            isRunning = false
            backendDescription = "Inactivo"
        }
        updateClickProgress()
        updateCornerHoldTick()
    }

    private func handleClick(location: CGPoint, backend: String) {
        guard let settings else {
            return
        }
        let now = Date()
        if now.timeIntervalSince(lastAcceptedClickDate) < 0.045 {
            DiagnosticLog.write("click ignored as duplicate backend=\(backend)")
            return
        }
        lastAcceptedClickDate = now
        lastEventDescription = "Clic visto por \(backend) @ \(Int(location.x)),\(Int(location.y))"
        DiagnosticLog.write("click seen backend=\(backend)")
        guard now.timeIntervalSince(lastTriggerDate) >= settings.triggerCooldownSeconds else {
            updateClickProgress()
            return
        }

        clickTimes = clickTimes.filter { now.timeIntervalSince($0) <= settings.clickWindowSeconds }
        clickTimes.append(now)
        updateClickProgress()

        if clickTimes.count >= settings.clickCount {
            clickTimes.removeAll()
            lastTriggerDate = now
            lastTriggerDescription = "Disparo por \(backend)"
            updateClickProgress()
            DiagnosticLog.write("trigger fired backend=\(backend)")
            onTrigger("clicks")
        }
    }

    private func createEventTap(location: CGEventTapLocation, mask: CGEventMask) -> (tap: CFMachPort, name: String)? {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: location,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: monitorEventTapCallback,
            userInfo: refcon
        ) else {
            DiagnosticLog.write("event tap create failed location=\(location.rawValue)")
            return nil
        }
        let name = location == .cghidEventTap ? "HID tap" : "Session tap"
        return (tap, name)
    }

    private func startGlobalMouseMonitor(backend: String) {
        guard globalMouseMonitor == nil else {
            return
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown]
        ) { [weak self] event in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }
                let location = NSEvent.mouseLocation
                switch event.type {
                case .leftMouseDown:
                    self.handleClick(location: location, backend: backend)
                default:
                    break
                }
            }
        }
        if globalMouseMonitor != nil {
            isRunning = true
            if eventTap == nil {
                backendDescription = backend
            }
            DiagnosticLog.write("\(backend) monitor running")
        } else {
            DiagnosticLog.write("\(backend) monitor failed")
        }
    }

    private func stopGlobalMouseMonitor() {
        guard let globalMouseMonitor else {
            return
        }
        NSEvent.removeMonitor(globalMouseMonitor)
        self.globalMouseMonitor = nil
    }

    private func startCornerHoldTimer() {
        guard cornerHoldTimer == nil else {
            return
        }
        cornerHoldTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateCornerHoldTick()
            }
        }
        DiagnosticLog.write("corner hold timer running")
    }

    private func stopCornerHoldTimer() {
        cornerHoldTimer?.invalidate()
        cornerHoldTimer = nil
    }

    private func schedulePermissionRetry() {
        guard permissionRetryTimer == nil else {
            return
        }
        permissionRetryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else {
                    return
                }
                if self.eventTap != nil {
                    self.stopPermissionRetryTimer()
                    return
                }
                guard AXIsProcessTrusted() else {
                    self.refreshState()
                    return
                }
                self.stopPermissionRetryTimer()
                self.start()
            }
        }
    }

    private func stopPermissionRetryTimer() {
        permissionRetryTimer?.invalidate()
        permissionRetryTimer = nil
    }

    private func refreshTrustStatus() {
        let next = AXIsProcessTrusted()
        if accessibilityTrusted != next {
            accessibilityTrusted = next
            DiagnosticLog.write("accessibility trust changed axTrusted=\(next)")
        }
    }

    private func updateClickProgress() {
        let target = settings?.clickCount ?? 0
        clickProgressDescription = "\(min(clickTimes.count, target))/\(target)"
    }

    private func updateCornerHoldTick() {
        guard let settings, settings.hoverGestureEnabled, !settings.triggersPaused else {
            resetCornerHold()
            cornerHoldProgressDescription = "Inactivo"
            return
        }

        let location = NSEvent.mouseLocation
        let now = Date()
        guard isInCorner(location, corner: settings.hoverGestureCorner) else {
            if cornerHoldStartedAt != nil {
                DiagnosticLog.write("corner hold reset")
            }
            resetCornerHold()
            cornerHoldProgressDescription = "Fuera"
            return
        }

        if cornerHoldStartedAt == nil {
            cornerHoldStartedAt = now
            cornerHoldDidTrigger = false
            lastEventDescription = "Puntero en \(settings.hoverGestureCorner.label)"
            DiagnosticLog.write("corner hold started corner=\(settings.hoverGestureCorner.rawValue)")
        }

        let elapsed = now.timeIntervalSince(cornerHoldStartedAt ?? now)
        let target = settings.hoverGestureTimeoutSeconds
        cornerHoldProgressDescription = "\(min(elapsed, target).formatted(.number.precision(.fractionLength(1))))/\(target.formatted(.number.precision(.fractionLength(1)))) s"

        guard !cornerHoldDidTrigger,
              elapsed >= target,
              now.timeIntervalSince(lastTriggerDate) >= settings.triggerCooldownSeconds else {
            return
        }

        cornerHoldDidTrigger = true
        lastTriggerDate = now
        lastTriggerDescription = "Disparo por esquina"
        cornerHoldProgressDescription = "Disparado"
        DiagnosticLog.write("corner hold trigger fired corner=\(settings.hoverGestureCorner.rawValue)")
        onTrigger("corner-hold")
    }

    private func resetCornerHold() {
        cornerHoldStartedAt = nil
        cornerHoldDidTrigger = false
    }

    private func isInCorner(_ point: CGPoint, corner: HoverGestureCorner) -> Bool {
        let frames = NSScreen.screens.map(\.frame)
        guard let minX = frames.map(\.minX).min(),
              let maxX = frames.map(\.maxX).max(),
              let minY = frames.map(\.minY).min(),
              let maxY = frames.map(\.maxY).max() else {
            return false
        }

        let size: CGFloat = 72
        switch corner {
        case .topLeft:
            return point.x <= minX + size && point.y >= maxY - size
        case .topRight:
            return point.x >= maxX - size && point.y >= maxY - size
        case .bottomLeft:
            return point.x <= minX + size && point.y <= minY + size
        case .bottomRight:
            return point.x >= maxX - size && point.y <= minY + size
        }
    }
}

func openPrivacyPane(anchor: String) {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else {
        return
    }
    NSWorkspace.shared.open(url)
}
