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
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@MainActor
final class AppController: ObservableObject {
    static let shared = AppController()

    let settings: AppSettings
    let captureManager: CaptureManager
    let eventMonitor: EventTapMonitor
    let permissions: PermissionStatus
    let updater: AppUpdater

    private let regionSelectionCoordinator = RegionSelectionCoordinator()
    private var settingsWindow: NSWindow?

    private init() {
        let settings = AppSettings()
        self.settings = settings
        permissions = PermissionStatus()
        captureManager = CaptureManager(settings: settings)
        updater = AppUpdater()
        eventMonitor = EventTapMonitor(settings: settings) { [weak captureManager] source in
            captureManager?.captureNow(source: source)
        }
        captureManager.prepareForCapture = { [weak self] in
            self?.prepareForCapture()
        }
    }

    func start() {
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
        let visibleFrame = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 620, height: 720)
        let windowWidth = min(CGFloat(560), visibleFrame.width - 40)
        let windowHeight = min(CGFloat(620), visibleFrame.height - 60)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Screening Automation"
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.minSize = CGSize(width: min(CGFloat(500), windowWidth), height: min(CGFloat(420), windowHeight))
        window.collectionBehavior = [.moveToActiveSpace]
        window.center()
        settingsWindow = window
        show(window)
    }

    private func show(_ window: NSWindow) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
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
    private let controller: AppController

    init(controller: AppController) {
        self.controller = controller
        _settings = ObservedObject(wrappedValue: controller.settings)
        _captureManager = ObservedObject(wrappedValue: controller.captureManager)
        _permissions = ObservedObject(wrappedValue: controller.permissions)
        _eventMonitor = ObservedObject(wrappedValue: controller.eventMonitor)
        _updater = ObservedObject(wrappedValue: controller.updater)
    }

    var body: some View {
        Button {
            controller.captureNow(source: "menu")
        } label: {
            Label("Capturar ahora", systemImage: "camera")
        }
        .disabled(settings.selectedRegion == nil || captureManager.isCapturing)

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
                settings.triggersPaused ? "Reanudar activadores" : "Pausar activadores",
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
            permissionsReady ? "Permisos OK" : "Permisos pendientes",
            systemImage: permissionsReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        )
        Text(captureManager.lastMessage)

        Divider()

        Button {
            NSApplication.shared.terminate(nil)
        } label: {
            Label("Salir", systemImage: "power")
        }
    }

    private var permissionsReady: Bool {
        permissions.screenCaptureAllowed && (permissions.accessibilityAllowed || eventMonitor.isRunning)
    }
}
