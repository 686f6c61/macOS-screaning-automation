import AppKit
import SwiftUI

@main
struct ScreeningAutomationApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = AppController.shared

    var body: some Scene {
        MenuBarExtra("SA") {
            MenuContent(controller: controller)
        }
        .menuBarExtraStyle(.menu)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        AppController.shared.start()
        AppController.shared.showOnboardingIfNeeded()
        if CommandLine.arguments.contains("--settings") {
            AppController.shared.openSettingsWindow()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let videoRecorder = AppController.shared.videoRecorder
        guard videoRecorder.isRecording else {
            return .terminateNow
        }
        Task { @MainActor in
            videoRecorder.stop()
            try? await Task.sleep(for: .seconds(2))
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@MainActor
final class AppController: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = AppController()
    static let onboardingCompletedKey = "ScreeningAutomation.Onboarding.Completed.v1"

    let settings: AppSettings
    let captureManager: CaptureManager
    let eventMonitor: EventTapMonitor
    let permissions: PermissionStatus
    let updater: AppUpdater
    let videoRecorder: VideoRecorder

    private let regionSelectionCoordinator = RegionSelectionCoordinator()
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?

    private override init() {
        let settings = AppSettings()
        self.settings = settings
        permissions = PermissionStatus()
        captureManager = CaptureManager(settings: settings)
        updater = AppUpdater()
        videoRecorder = VideoRecorder(settings: settings)
        eventMonitor = EventTapMonitor(settings: settings) { [weak captureManager] source in
            captureManager?.captureNow(source: source)
        }
        super.init()
        captureManager.prepareForCapture = { [weak self] in
            self?.prepareForCapture()
        }
    }

    func start() {
        DiagnosticLog.prepare()
        permissions.startMonitoring()
        eventMonitor.start()
    }

    func captureNow(source: String) {
        captureManager.captureNow(source: source)
    }

    func defineRegion() {
        regionSelectionCoordinator.begin { [weak settings] region in
            settings?.selectedRegion = region
        }
    }

    func openSettingsWindow() {
        if let settingsWindow {
            show(settingsWindow)
            return
        }

        let hostingController = NSHostingController(rootView: SettingsView(controller: self))
        let visibleFrame = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 620, height: 760)
        let windowWidth = min(CGFloat(580), visibleFrame.width - 40)
        let windowHeight = min(CGFloat(680), visibleFrame.height - 60)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Screening Automation"
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.minSize = CGSize(width: min(CGFloat(540), windowWidth), height: min(CGFloat(560), windowHeight))
        window.collectionBehavior = [.moveToActiveSpace]
        window.center()
        settingsWindow = window
        show(window)
    }

    private func show(_ window: NSWindow) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func showOnboardingIfNeeded() {
        guard !settings.hadPersistedSettings,
              !UserDefaults.standard.bool(forKey: Self.onboardingCompletedKey) else {
            return
        }
        showOnboarding()
    }

    func showOnboarding() {
        if let onboardingWindow {
            show(onboardingWindow)
            return
        }

        let hostingController = NSHostingController(rootView: OnboardingView(controller: self) { [weak self] in
            self?.completeOnboarding()
        })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Screening Automation"
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        onboardingWindow = window
        show(window)
    }

    func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: Self.onboardingCompletedKey)
        onboardingWindow?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === onboardingWindow {
            UserDefaults.standard.set(true, forKey: Self.onboardingCompletedKey)
        }
    }

    private func prepareForCapture() {
        if settingsWindow?.isVisible == true {
            settingsWindow?.orderOut(nil)
            DiagnosticLog.write("settings window hidden before capture")
        }
    }
}

private struct MenuContent: View {
    @ObservedObject private var settings: AppSettings
    @ObservedObject private var captureManager: CaptureManager
    @ObservedObject private var permissions: PermissionStatus
    @ObservedObject private var eventMonitor: EventTapMonitor
    @ObservedObject private var updater: AppUpdater
    @ObservedObject private var videoRecorder: VideoRecorder
    private let controller: AppController

    init(controller: AppController) {
        self.controller = controller
        _settings = ObservedObject(wrappedValue: controller.settings)
        _captureManager = ObservedObject(wrappedValue: controller.captureManager)
        _permissions = ObservedObject(wrappedValue: controller.permissions)
        _eventMonitor = ObservedObject(wrappedValue: controller.eventMonitor)
        _updater = ObservedObject(wrappedValue: controller.updater)
        _videoRecorder = ObservedObject(wrappedValue: controller.videoRecorder)
    }

    var body: some View {
        Button {
            controller.captureNow(source: "menu")
        } label: {
            Label("Capturar ahora", systemImage: "camera")
        }
        .disabled(settings.selectedRegion == nil || captureManager.isCapturing)

        Button {
            if captureManager.armedCaptureActive {
                captureManager.cancelArmedBurst()
            } else {
                captureManager.startArmedBurst()
            }
        } label: {
            Label(
                captureManager.armedCaptureActive ? L10n.t("Cancelar modo armado") : L10n.t("Armar rafaga"),
                systemImage: captureManager.armedCaptureActive ? "stop.circle" : "timer"
            )
        }
        .disabled(settings.selectedRegion == nil)

        Button {
            controller.videoRecorder.toggle()
        } label: {
            Label(
                videoRecorder.isRecording ? L10n.t("Detener grabacion") : L10n.t("Grabar video de la zona"),
                systemImage: videoRecorder.isRecording ? "stop.rectangle" : "video"
            )
        }
        .disabled(settings.selectedRegion == nil)

        Button {
            controller.defineRegion()
        } label: {
            Label("Definir zona", systemImage: "viewfinder")
        }

        Divider()

        Button {
            settings.triggersPaused.toggle()
        } label: {
            Label(
                settings.triggersPaused ? L10n.t("Reanudar activadores") : L10n.t("Pausar activadores"),
                systemImage: settings.triggersPaused ? "play.circle" : "pause.circle"
            )
        }

        Button {
            settings.revealOutputFolder()
        } label: {
            Label("Abrir carpeta", systemImage: "folder")
        }

        Button {
            controller.openSettingsWindow()
        } label: {
            Label("Ajustes", systemImage: "gearshape")
        }

        Button {
            updater.checkForUpdates()
        } label: {
            Label("Buscar actualizaciones...", systemImage: "arrow.down.circle")
        }
        .disabled(!updater.canCheckForUpdates)

        Divider()

        if let region = settings.selectedRegion {
            Text(region.summary)
        } else {
            Text("Sin zona")
        }
        Label(
            permissionsReady ? L10n.t("Permisos OK") : L10n.t("Permisos pendientes"),
            systemImage: permissionsReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        )
        Text(captureManager.lastMessage)
        if captureManager.armedCaptureActive {
            Text(captureManager.armedCaptureMessage)
        }
        if videoRecorder.isRecording {
            Label(
                L10n.format("Grabando %@", videoRecorder.elapsedDescription),
                systemImage: "record.circle"
            )
        }

        Divider()

        Button {
            NSApplication.shared.terminate(nil)
        } label: {
            Label("Salir", systemImage: "power")
        }
    }

    private var permissionsReady: Bool {
        permissions.screenCaptureAllowed && permissions.inputMonitoringAllowed
    }
}
