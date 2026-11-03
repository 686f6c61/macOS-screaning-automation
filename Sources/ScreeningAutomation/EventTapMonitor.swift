// Activadores de captura: ráfaga de clics y puntero mantenido en una esquina.
//
// Los clics se escuchan por tres vías a la vez, de más a menos fiable:
// 1. `CGEventTap` pasivo (HID o sesión), que requiere Monitorización de entrada.
// 2. Monitor global de AppKit (`NSEvent.addGlobalMonitorForEvents`).
// 3. Para la esquina, sondeo de la posición del puntero cada 0,1 s.
// Un mismo clic puede llegar por las dos primeras vías; `ClickBurstDetector`
// descarta como duplicado lo que llega con menos de 45 ms de diferencia.

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

private func eventMask(_ type: CGEventType) -> CGEventMask {
    CGEventMask(1) << CGEventMask(type.rawValue)
}

/// Callback C del event tap. Se ejecuta en el run loop principal; reenvía el
/// evento al monitor. `refcon` es un puntero no retenido al `EventTapMonitor`,
/// que vive tanto como la app y libera el tap en su `deinit`.
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

/// Resultado de registrar un clic.
enum ClickBurstOutcome: Equatable {
    /// El mismo clic llegado por otra vía (menos de 45 ms).
    case duplicate
    /// Dentro del tiempo de espera tras el último disparo.
    case coolingDown
    /// Cuenta para la ráfaga, pero aún no llega al objetivo.
    case progress
    /// Se ha completado la ráfaga.
    case triggered
}

/// Detecta N clics dentro de una ventana de tiempo. Lógica pura, sin reloj
/// propio: las fechas las pasa el llamador, lo que permite probarla.
struct ClickBurstDetector {
    /// Clics más próximos que esto se consideran el mismo evento duplicado.
    static let duplicateThreshold: TimeInterval = 0.045

    private(set) var progressCount = 0
    private(set) var lastTriggerDate = Date.distantPast
    private var clickTimes: [Date] = []
    private var lastAcceptedClickDate = Date.distantPast

    /// Registra un clic en `now` y devuelve en qué estado queda la ráfaga.
    mutating func registerClick(
        at now: Date,
        targetCount: Int,
        windowSeconds: TimeInterval,
        cooldownSeconds: TimeInterval
    ) -> ClickBurstOutcome {
        guard now.timeIntervalSince(lastAcceptedClickDate) >= Self.duplicateThreshold else {
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

    /// Anota un disparo de otro activador (la esquina) para compartir el cooldown.
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

/// Resultado de un tick de la detección de esquina.
enum CornerHoldOutcome: Equatable {
    /// El puntero no está en la esquina. `wasHolding` indica si acaba de salir.
    case outside(wasHolding: Bool)
    /// El puntero sigue en la esquina desde hace `elapsed` segundos.
    case holding(elapsed: TimeInterval, justStarted: Bool)
    /// Se ha cumplido el tiempo: hay que disparar (una sola vez por estancia).
    case triggered
}

/// Detecta que el puntero permanece en una esquina durante un tiempo. Lógica
/// pura: el llamador aporta la fecha, si el puntero está en la esquina y si
/// ya pasó el cooldown.
struct CornerHoldDetector {
    private(set) var startedAt: Date?
    private var didTrigger = false

    mutating func tick(
        at now: Date,
        inCorner: Bool,
        holdSeconds: TimeInterval,
        cooldownElapsed: Bool
    ) -> CornerHoldOutcome {
        guard inCorner else {
            let wasHolding = startedAt != nil
            reset()
            return .outside(wasHolding: wasHolding)
        }
        let justStarted = startedAt == nil
        let startedAt = self.startedAt ?? now
        self.startedAt = startedAt
        let elapsed = now.timeIntervalSince(startedAt)
        if !didTrigger, elapsed >= holdSeconds, cooldownElapsed {
            didTrigger = true
            return .triggered
        }
        return .holding(elapsed: elapsed, justStarted: justStarted)
    }

    mutating func reset() {
        startedAt = nil
        didTrigger = false
    }
}

/// Escucha clics y la posición del puntero y llama a `onTrigger` cuando se
/// cumple un activador. Publica su estado para la sección de diagnóstico.
@MainActor
final class EventTapMonitor: ObservableObject {
    /// Intervalo del sondeo de la esquina.
    private static let cornerPollInterval: TimeInterval = 0.1
    /// Intervalo de reintento del event tap mientras falta el permiso.
    private static let permissionRetryInterval: TimeInterval = 2.0

    private weak var settings: AppSettings?
    private let onTrigger: (TriggerSource) -> Void

    @Published private(set) var isRunning = false
    @Published private(set) var backendDescription = L10n.t("Inactivo")
    @Published private(set) var lastEventDescription = L10n.t("Sin eventos")
    @Published private(set) var clickProgressDescription = "0/0"
    @Published private(set) var cornerHoldProgressDescription = L10n.t("Inactivo")
    @Published private(set) var lastTriggerDescription = L10n.t("Sin disparos")
    @Published private(set) var lastStartError = ""
    @Published private(set) var inputMonitoringAllowed = InputMonitoringPermission.allowed

    private var eventTap: CFMachPort?
    private var eventTapName: String?
    private var runLoopSource: CFRunLoopSource?
    private var globalMouseMonitor: Any?
    private var permissionRetryTimer: Timer?
    private var cornerHoldTimer: Timer?
    private var clickBurstDetector = ClickBurstDetector()
    private var cornerHoldDetector = CornerHoldDetector()
    private let activatorActivity = ActivityAssertion(
        reason: "Screening Automation activators",
        logName: "activator"
    )

    /// - Parameter onTrigger: se llama en el hilo principal con el origen del disparo.
    init(settings: AppSettings, onTrigger: @escaping (TriggerSource) -> Void) {
        self.settings = settings
        self.onTrigger = onTrigger
    }

    isolated deinit {
        releaseEventTap()
    }

    // MARK: Ciclo de vida

    /// Arranca todas las vías de escucha disponibles. Si el event tap no se
    /// puede crear (falta Monitorización de entrada), sigue con AppKit y
    /// reintenta el tap periódicamente.
    func start() {
        guard eventTap == nil else {
            startCornerHoldTimer()
            refreshState()
            return
        }

        inputMonitoringAllowed = InputMonitoringPermission.allowed
        DiagnosticLog.write("event monitor start requested inputAllowed=\(inputMonitoringAllowed)")
        startGlobalMouseMonitor()
        startCornerHoldTimer()

        let mask = eventMask(.leftMouseDown)
        guard let createdTap = createEventTap(location: .cghidEventTap, mask: mask)
            ?? createEventTap(location: .cgSessionEventTap, mask: mask) else {
            lastStartError = L10n.t("CGEventTap no disponible; usando AppKit global.")
            DiagnosticLog.write("all event tap create attempts failed; using AppKit global only")
            requestInputMonitoringPermission()
            refreshState()
            return
        }

        stopPermissionRetryTimer()
        eventTap = createdTap.tap
        eventTapName = createdTap.name
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, createdTap.tap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: createdTap.tap, enable: true)
        lastStartError = ""
        DiagnosticLog.write("event tap running backend=\(createdTap.name)")
        refreshState()
    }

    /// Detiene todas las vías de escucha y reinicia el estado de los detectores.
    func stop() {
        releaseEventTap()
        stopGlobalMouseMonitor()
        stopCornerHoldTimer()
        stopPermissionRetryTimer()
        activatorActivity.end()
        clickBurstDetector.reset()
        cornerHoldDetector.reset()
        refreshState()
    }

    /// Pide Monitorización de entrada y reintenta crear el tap hasta conseguirlo.
    func requestInputMonitoringPermission() {
        InputMonitoringPermission.request()
        inputMonitoringAllowed = InputMonitoringPermission.allowed
        DiagnosticLog.write("input monitoring permission requested allowed=\(inputMonitoringAllowed)")
        schedulePermissionRetry()
    }

    /// Recalcula `isRunning` y `backendDescription` a partir de las vías activas.
    func refreshState() {
        refreshPermissionStatus()
        let backends = [
            eventTapName,
            globalMouseMonitor != nil ? "AppKit global" : nil,
            cornerHoldTimer != nil ? "CG polling" : nil
        ].compactMap { $0 }
        isRunning = !backends.isEmpty
        backendDescription = backends.isEmpty ? L10n.t("Inactivo") : backends.joined(separator: " + ")
        updateClickProgress()
        updateCornerHoldTick()
    }

    /// Simula una ráfaga completa de clics para probar el activador desde Ajustes.
    func simulateClickBurst() {
        guard let settings else {
            return
        }
        DiagnosticLog.write("simulated click burst count=\(settings.clickCount)")
        let start = Date()
        for index in 0..<settings.clickCount {
            handleClick(
                location: NSEvent.mouseLocation,
                backend: L10n.t("simulacion"),
                now: start.addingTimeInterval(Double(index) * 0.06)
            )
        }
    }

    // MARK: Event tap

    /// Entrada desde el callback del event tap.
    func handle(type: CGEventType, location: CGPoint) {
        refreshPermissionStatus()
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            reenableEventTap(after: type)
            return
        }
        guard type == .leftMouseDown, let settings, !settings.triggersPaused else {
            return
        }
        handleClick(location: location, backend: eventTapName ?? "CGEventTap")
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

    /// macOS desactiva el tap si el callback tarda o si cambia el permiso. Se
    /// reactiva y se comprueba: si sigue desactivado (permiso revocado), se
    /// libera y se queda solo el monitor global de AppKit hasta que el permiso
    /// vuelva, en lugar de anunciar un backend que no recibe eventos.
    private func reenableEventTap(after type: CGEventType) {
        guard let eventTap else {
            return
        }
        CGEvent.tapEnable(tap: eventTap, enable: true)
        if CGEvent.tapIsEnabled(tap: eventTap) {
            DiagnosticLog.write("event tap re-enabled type=\(type.rawValue)")
            return
        }
        DiagnosticLog.write("event tap could not be re-enabled type=\(type.rawValue); falling back to AppKit global")
        releaseEventTap()
        lastStartError = L10n.t("CGEventTap no disponible; usando AppKit global.")
        refreshState()
        schedulePermissionRetry()
    }

    /// Desactiva y libera el tap y su fuente del run loop.
    private func releaseEventTap() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        runLoopSource = nil
        eventTap = nil
        eventTapName = nil
    }

    private func schedulePermissionRetry() {
        guard permissionRetryTimer == nil else {
            return
        }
        permissionRetryTimer = Timer.scheduledTimer(
            withTimeInterval: Self.permissionRetryInterval,
            repeats: true
        ) { [weak self] _ in
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

    // MARK: AppKit

    private func startGlobalMouseMonitor() {
        guard globalMouseMonitor == nil else {
            return
        }
        // La máscara solo incluye `leftMouseDown`, así que no hace falta filtrar.
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, let settings = self.settings, !settings.triggersPaused else {
                    return
                }
                self.handleClick(location: NSEvent.mouseLocation, backend: "AppKit global")
            }
        }
        DiagnosticLog.write(globalMouseMonitor != nil ? "AppKit global monitor running" : "AppKit global monitor failed")
    }

    private func stopGlobalMouseMonitor() {
        guard let globalMouseMonitor else {
            return
        }
        NSEvent.removeMonitor(globalMouseMonitor)
        self.globalMouseMonitor = nil
    }

    // MARK: Ráfaga de clics

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

        lastEventDescription = L10n.format("Clic visto por %@ @ %d,%d", backend, Int(location.x), Int(location.y))
        DiagnosticLog.write("click seen backend=\(backend)")
        updateClickProgress()

        guard outcome == .triggered else {
            return
        }
        lastTriggerDescription = L10n.format("Disparo por %@", backend)
        DiagnosticLog.write("trigger fired backend=\(backend)")
        onTrigger(.clicks)
    }

    private func updateClickProgress() {
        let target = settings?.clickCount ?? 0
        clickProgressDescription = "\(min(clickBurstDetector.progressCount, target))/\(target)"
    }

    // MARK: Esquina

    private func startCornerHoldTimer() {
        guard cornerHoldTimer == nil else {
            return
        }
        let timer = Timer(timeInterval: Self.cornerPollInterval, repeats: true) { [weak self] _ in
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

    private func updateCornerHoldTick() {
        guard let settings, settings.hoverGestureEnabled, !settings.triggersPaused else {
            cornerHoldDetector.reset()
            activatorActivity.end()
            publishCornerHoldProgress(L10n.t("Inactivo"))
            return
        }

        let now = Date()
        let corner = settings.hoverGestureCorner
        let outcome = cornerHoldDetector.tick(
            at: now,
            inCorner: ScreenGeometry.isInCorner(
                currentMouseLocation(),
                corner: corner,
                screens: NSScreen.screens.map(\.frame)
            ),
            holdSeconds: settings.hoverGestureTimeoutSeconds,
            cooldownElapsed: now.timeIntervalSince(clickBurstDetector.lastTriggerDate) >= settings.triggerCooldownSeconds
        )

        switch outcome {
        case .outside(let wasHolding):
            if wasHolding {
                DiagnosticLog.write("corner hold reset")
            }
            activatorActivity.end()
            publishCornerHoldProgress(L10n.t("Fuera"))
        case .holding(let elapsed, let justStarted):
            if justStarted {
                activatorActivity.begin()
                lastEventDescription = L10n.format("Puntero en %@ por CG polling", corner.label)
                DiagnosticLog.write("corner hold started corner=\(corner.rawValue)")
            }
            let target = settings.hoverGestureTimeoutSeconds
            let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(1))
            publishCornerHoldProgress("\(min(elapsed, target).formatted(format))/\(target.formatted(format)) s")
        case .triggered:
            clickBurstDetector.recordExternalTrigger(at: now)
            lastTriggerDescription = L10n.t("Disparo por esquina")
            publishCornerHoldProgress(L10n.t("Disparado"))
            DiagnosticLog.write("corner hold trigger fired corner=\(corner.rawValue)")
            onTrigger(.cornerHold)
        }
    }

    /// El tick de esquina corre cada 0,1 s; `@Published` emite aunque el valor
    /// no cambie, y eso redibujaba la ventana de ajustes diez veces por segundo.
    private func publishCornerHoldProgress(_ value: String) {
        if cornerHoldProgressDescription != value {
            cornerHoldProgressDescription = value
        }
    }

    private func currentMouseLocation() -> CGPoint {
        guard let event = CGEvent(source: nil) else {
            return NSEvent.mouseLocation
        }
        return ScreenGeometry.appKitLocation(fromQuartz: event.location)
    }
}
