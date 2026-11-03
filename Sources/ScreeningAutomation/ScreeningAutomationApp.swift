// Punto de entrada: app de barra de menús (sin icono en el Dock) con su menú,
// el delegado de la aplicación y el controlador que conecta los modelos.

import AppKit
import SwiftUI

/// App de barra de menús «SA».
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

/// Arranque, bienvenida y salida ordenada (espera a cerrar el vídeo en curso).
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
        // También en `stopping`: salir mientras se cierra el MP4 lo truncaría.
        guard videoRecorder.isBusy else {
            return .terminateNow
        }
        // Se espera a que el MP4 quede cerrado. `stop()` tiene su propio tope
        // de tiempo, así que un `finishWriting` colgado no bloquea la salida.
        Task { @MainActor in
            await videoRecorder.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// Crea y conecta los modelos (ajustes, permisos, captura, vídeo,
/// activadores, actualizaciones) y gestiona las ventanas de Ajustes y de
/// bienvenida. Es un singleton porque hay un único estado de app.
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
        captureManager.onScreenRecordingDenied = { [weak permissions] in
            permissions?.markScreenCaptureDenied()
        }
    }

    /// Prepara el log y arranca la vigilancia de permisos y los activadores.
    func start() {
        DiagnosticLog.prepare()
        permissions.startMonitoring()
        eventMonitor.start()
    }

    /// Captura la zona configurada.
    func captureNow(source: TriggerSource) {
        captureManager.captureNow(source: source)
    }

    /// Pide Monitorización de entrada (aviso del sistema la primera vez) y
    /// refresca el estado.
    func requestInputMonitoring() {
        eventMonitor.requestInputMonitoringPermission()
        permissions.refresh()
    }

    /// Pide Grabación de pantalla y, al ser una acción explícita del usuario,
    /// verifica también el acceso real con ScreenCaptureKit.
    func requestScreenCapture() {
        ScreenCapturePermission.requestOrOpenSettings()
        permissions.refresh()
        if !permissions.screenCaptureAllowed {
            permissions.verifyScreenCaptureAccess()
        }
    }

    /// Abre la selección interactiva de zona y guarda la elegida.
    func defineRegion() {
        regionSelectionCoordinator.begin { [weak settings] region in
            settings?.selectedRegion = region
        }
    }

    /// Muestra la ventana de Ajustes, creándola la primera vez.
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

    /// Muestra la bienvenida si es la primera ejecución.
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

/// Contenido del menú de la barra de menús.
private struct MenuContent: View {
    @ObservedObject private var settings: AppSettings
    @ObservedObject private var captureManager: CaptureManager
    @ObservedObject private var permissions: PermissionStatus
    @ObservedObject private var videoRecorder: VideoRecorder
    private let controller: AppController

    init(controller: AppController) {
        self.controller = controller
        _settings = ObservedObject(wrappedValue: controller.settings)
        _captureManager = ObservedObject(wrappedValue: controller.captureManager)
        _permissions = ObservedObject(wrappedValue: controller.permissions)
        _videoRecorder = ObservedObject(wrappedValue: controller.videoRecorder)
    }

    var body: some View {
        Button {
            controller.captureNow(source: .menu)
        } label: {
            Label("Capturar ahora", systemImage: "camera")
        }
        .disabled(settings.selectedRegion == nil || captureManager.isCapturing)

        Button {
            controller.videoRecorder.toggle()
        } label: {
            Label(
                videoRecorder.isRecording ? L10n.t("Detener grabacion") : L10n.t("Grabar video de la zona"),
                systemImage: videoRecorder.isRecording ? "stop.circle" : "video"
            )
        }
        .disabled(settings.selectedRegion == nil)

        Button {
            captureManager.toggleArmedBurst()
        } label: {
            Label(
                captureManager.armedCaptureActive ? L10n.t("Cancelar modo armado") : L10n.t("Armar rafaga"),
                systemImage: captureManager.armedCaptureActive ? "stop.circle" : "timer"
            )
        }
        .disabled(settings.selectedRegion == nil)

        Button {
            controller.defineRegion()
        } label: {
            Label("Definir zona", systemImage: "viewfinder")
        }

        Divider()

        // Avisos: solo cuando hay algo que resolver.
        if settings.selectedRegion == nil {
            Label("Sin zona: usa Definir zona", systemImage: "exclamationmark.triangle.fill")
        }
        if !permissions.allAllowed {
            Label("Permisos pendientes: revisa Ajustes", systemImage: "exclamationmark.triangle.fill")
        }
        Text(statusLine)

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
            Label("Ajustes…", systemImage: "gearshape")
        }

        Divider()

        Button {
            NSApplication.shared.terminate(nil)
        } label: {
            Label("Salir", systemImage: "power")
        }
    }

    /// Una sola línea de estado: lo que está en curso o, si no hay nada, el
    /// mensaje más reciente entre capturas y vídeo.
    private var statusLine: String {
        if videoRecorder.isRecording {
            return L10n.format("Grabando %@", videoRecorder.elapsedDescription)
        }
        if captureManager.armedCaptureActive {
            return captureManager.armedCaptureMessage
        }
        if !videoRecorder.lastMessage.isEmpty,
           videoRecorder.lastMessageDate > captureManager.lastMessageDate {
            return videoRecorder.lastMessage
        }
        return captureManager.lastMessage
    }
}
