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

enum ClickBurstOutcome: Equatable {
    case duplicate
    case coolingDown
    case progress
    case triggered
}

struct ClickBurstDetector {
    private(set) var progressCount = 0
    private(set) var lastTriggerDate = Date.distantPast
    private var clickTimes: [Date] = []
    private var lastAcceptedClickDate = Date.distantPast

    mutating func registerClick(
        at now: Date,
        targetCount: Int,
        windowSeconds: TimeInterval,
        cooldownSeconds: TimeInterval
    ) -> ClickBurstOutcome {
        guard now.timeIntervalSince(lastAcceptedClickDate) >= 0.045 else {
            return .duplicate
        }
        lastAcceptedClickDate = now

        guard now.timeIntervalSince(lastTriggerDate) >= cooldownSeconds else {
            return .coolingDown
        }

        clickTimes = clickTimes.filter { now.timeIntervalSince($0) <= windowSeconds }
        clickTimes.append(now)
        progressCount = clickTimes.count

        guard clickTimes.count >= targetCount else {
            return .progress
        }

        clickTimes.removeAll()
        progressCount = 0
        lastTriggerDate = now
        return .triggered
    }

    mutating func recordExternalTrigger(at date: Date) {
        lastTriggerDate = date
    }

    mutating func reset() {
        clickTimes.removeAll()
        progressCount = 0
        lastAcceptedClickDate = .distantPast
        lastTriggerDate = .distantPast
    }
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
    @Published private(set) var inputMonitoringAllowed = InputMonitoringPermission.allowed

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var globalMouseMonitor: Any?
    private var permissionRetryTimer: Timer?
    private var cornerHoldTimer: Timer?
    private var activatorActivity: NSObjectProtocol?
    private var cornerHoldStartedAt: Date?
    private var cornerHoldDidTrigger = false
    private var clickBurstDetector = ClickBurstDetector()

    init(settings: AppSettings, onTrigger: @escaping (String) -> Void) {
        self.settings = settings
        self.onTrigger = onTrigger
    }

    func start() {
        guard eventTap == nil else {
            beginActivatorActivity()
            startCornerHoldTimer()
            refreshState()
            return
        }

        inputMonitoringAllowed = InputMonitoringPermission.allowed
        DiagnosticLog.write("event monitor start requested inputAllowed=\(inputMonitoringAllowed)")

        let mask = eventMask(.leftMouseDown)

        let createdTap = createEventTap(location: .cghidEventTap, mask: mask)
            ?? createEventTap(location: .cgSessionEventTap, mask: mask)

        guard let createdTap else {
            lastStartError = "CGEventTap no disponible; usando AppKit global."
            DiagnosticLog.write("all event tap create attempts failed; using AppKit global only")
            startGlobalMouseMonitor(backend: "AppKit global")
            startCornerHoldTimer()
            requestInputMonitoringPermission()
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
        backendDescription = "\(createdTap.name) + AppKit + CG polling"
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
        endActivatorActivity()
        backendDescription = "Inactivo"
        permissionRetryTimer?.invalidate()
        permissionRetryTimer = nil
        clickBurstDetector.reset()
        resetCornerHold()
    }

    func requestInputMonitoringPermission() {
        _ = InputMonitoringPermission.request()
        inputMonitoringAllowed = InputMonitoringPermission.allowed
        DiagnosticLog.write("input monitoring permission requested allowed=\(inputMonitoringAllowed)")
        schedulePermissionRetry()
    }

    func openInputMonitoringSettings() {
        InputMonitoringPermission.openSettings()
    }

    func handle(type: CGEventType, location: CGPoint) {
        refreshPermissionStatus()
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
        let start = Date()
        for index in 0..<settings.clickCount {
            handleClick(
                location: NSEvent.mouseLocation,
                backend: "simulacion",
                now: start.addingTimeInterval(Double(index) * 0.06)
            )
        }
    }

    func refreshState() {
        refreshPermissionStatus()
        if eventTap != nil {
            isRunning = true
            backendDescription = "CGEventTap + CG polling"
        } else if globalMouseMonitor != nil {
            isRunning = true
            backendDescription = "AppKit global + CG polling"
        } else if cornerHoldTimer != nil {
            isRunning = true
            backendDescription = "CG polling"
        } else {
            isRunning = false
            backendDescription = "Inactivo"
        }
        updateClickProgress()
        updateCornerHoldTick()
    }

    private func handleClick(location: CGPoint, backend: String, now: Date = Date()) {
        guard let settings else {
            return
        }

        let outcome = clickBurstDetector.registerClick(
            at: now,
            targetCount: settings.clickCount,
            windowSeconds: settings.clickWindowSeconds,
            cooldownSeconds: settings.triggerCooldownSeconds
        )
        if outcome == .duplicate {
            DiagnosticLog.write("click ignored as duplicate backend=\(backend)")
            return
        }

        lastEventDescription = "Clic visto por \(backend) @ \(Int(location.x)),\(Int(location.y))"
        DiagnosticLog.write("click seen backend=\(backend)")
        updateClickProgress()

        guard outcome != .coolingDown else {
            return
        }
        guard outcome == .triggered else {
            return
        }

        lastTriggerDescription = "Disparo por \(backend)"
        DiagnosticLog.write("trigger fired backend=\(backend)")
        onTrigger("clicks")
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
        beginActivatorActivity()

        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateCornerHoldTick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        cornerHoldTimer = timer
        DiagnosticLog.write("corner hold polling timer running source=CoreGraphics")
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
                guard InputMonitoringPermission.allowed else {
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

    private func refreshPermissionStatus() {
        let next = InputMonitoringPermission.allowed
        if inputMonitoringAllowed != next {
            inputMonitoringAllowed = next
            DiagnosticLog.write("input monitoring permission changed allowed=\(next)")
        }
    }

    private func updateClickProgress() {
        let target = settings?.clickCount ?? 0
        clickProgressDescription = "\(min(clickBurstDetector.progressCount, target))/\(target)"
    }

    private func updateCornerHoldTick() {
        guard let settings, settings.hoverGestureEnabled, !settings.triggersPaused else {
            resetCornerHold()
            cornerHoldProgressDescription = "Inactivo"
            return
        }

        let location = currentMouseLocation()
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
            lastEventDescription = "Puntero en \(settings.hoverGestureCorner.label) por CG polling"
            DiagnosticLog.write("corner hold started corner=\(settings.hoverGestureCorner.rawValue)")
        }

        let elapsed = now.timeIntervalSince(cornerHoldStartedAt ?? now)
        let target = settings.hoverGestureTimeoutSeconds
        cornerHoldProgressDescription = "\(min(elapsed, target).formatted(.number.precision(.fractionLength(1))))/\(target.formatted(.number.precision(.fractionLength(1)))) s"

        guard !cornerHoldDidTrigger,
              elapsed >= target,
              now.timeIntervalSince(clickBurstDetector.lastTriggerDate) >= settings.triggerCooldownSeconds else {
            return
        }

        cornerHoldDidTrigger = true
        clickBurstDetector.recordExternalTrigger(at: now)
        lastTriggerDescription = "Disparo por esquina"
        cornerHoldProgressDescription = "Disparado"
        DiagnosticLog.write("corner hold trigger fired corner=\(settings.hoverGestureCorner.rawValue)")
        onTrigger("corner-hold")
    }

    private func currentMouseLocation() -> CGPoint {
        guard let event = CGEvent(source: nil) else {
            return NSEvent.mouseLocation
        }
        return Self.appKitLocation(fromQuartzLocation: event.location)
    }

    private static func appKitLocation(fromQuartzLocation location: CGPoint) -> CGPoint {
        for screen in NSScreen.screens {
            guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                continue
            }

            let displayID = CGDirectDisplayID(screenNumber.uint32Value)
            let quartzBounds = CGDisplayBounds(displayID)
            guard quartzBounds.contains(location) else {
                continue
            }

            return CGPoint(
                x: location.x,
                y: screen.frame.maxY - (location.y - quartzBounds.minY)
            )
        }

        let virtualMaxY = NSScreen.screens.map(\.frame.maxY).max() ?? NSEvent.mouseLocation.y
        return CGPoint(x: location.x, y: virtualMaxY - location.y)
    }

    private func beginActivatorActivity() {
        guard activatorActivity == nil else {
            return
        }
        activatorActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Screening Automation activators"
        )
        DiagnosticLog.write("activator activity started")
    }

    private func endActivatorActivity() {
        guard let activatorActivity else {
            return
        }
        ProcessInfo.processInfo.endActivity(activatorActivity)
        self.activatorActivity = nil
        DiagnosticLog.write("activator activity ended")
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
