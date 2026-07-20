import AppKit
import Foundation

struct CaptureRegion: Codable, Equatable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int
    var displayName: String
    var createdAt: Date

    var screencaptureArgument: String {
        "\(x),\(y),\(width),\(height)"
    }

    var summary: String {
        "\(width)x\(height) @ \(x),\(y)"
    }

    static func fromSelection(localRect: CGRect, on screen: NSScreen) -> CaptureRegion {
        let screenRect = screen.frame
        let virtualMaxY = NSScreen.screens.map(\.frame.maxY).max() ?? screenRect.maxY
        return fromSelection(
            localRect: localRect,
            screenFrame: screenRect,
            virtualMaxY: virtualMaxY,
            displayName: screen.localizedName
        )
    }

    static func fromSelection(
        localRect: CGRect,
        screenFrame: CGRect,
        virtualMaxY: CGFloat,
        displayName: String,
        createdAt: Date = Date()
    ) -> CaptureRegion {
        let globalRect = CGRect(
            x: screenFrame.minX + localRect.minX,
            y: screenFrame.minY + localRect.minY,
            width: localRect.width,
            height: localRect.height
        )
        let captureY = virtualMaxY - globalRect.maxY

        return CaptureRegion(
            x: Int(globalRect.minX.rounded()),
            y: Int(captureY.rounded()),
            width: max(1, Int(globalRect.width.rounded())),
            height: max(1, Int(globalRect.height.rounded())),
            displayName: displayName,
            createdAt: createdAt
        )
    }
}

enum ImageFormat: String, CaseIterable, Codable, Identifiable {
    case png
    case jpg

    var id: String { rawValue }

    var fileExtension: String {
        rawValue
    }

    var label: String {
        rawValue.uppercased()
    }
}

enum HoverGestureCorner: String, CaseIterable, Codable, Identifiable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    var id: String { rawValue }

    var label: String {
        switch self {
        case .topLeft:
            return "Arriba izquierda"
        case .topRight:
            return "Arriba derecha"
        case .bottomLeft:
            return "Abajo izquierda"
        case .bottomRight:
            return "Abajo derecha"
        }
    }
}

private struct PersistedSettings: Codable {
    var selectedRegion: CaptureRegion?
    var outputFolderPath: String
    var imageFormat: ImageFormat
    var clickCount: Int
    var clickWindowSeconds: Double
    var triggerCooldownSeconds: Double
    var triggersPaused: Bool
    var hoverGestureEnabled: Bool?
    var hoverGestureCorner: HoverGestureCorner?
    var hoverGestureTimeoutSeconds: Double?
    var armedCaptureDelaySeconds: Double?
    var armedCaptureIntervalSeconds: Double?
    var armedCaptureCount: Int?
}

@MainActor
final class AppSettings: ObservableObject {
    private let defaultsKey = "ScreeningAutomation.Settings.v1"
    private let legacyDefaultsKey = "MonitorScreening.Settings.v1"
    private let defaults: UserDefaults

    @Published var selectedRegion: CaptureRegion? {
        didSet { save() }
    }

    @Published var outputFolderPath: String {
        didSet { save() }
    }

    @Published var imageFormat: ImageFormat {
        didSet { save() }
    }

    @Published var clickCount: Int {
        didSet { save() }
    }

    @Published var clickWindowSeconds: Double {
        didSet { save() }
    }

    @Published var triggerCooldownSeconds: Double {
        didSet { save() }
    }

    @Published var triggersPaused: Bool {
        didSet { save() }
    }

    @Published var hoverGestureEnabled: Bool {
        didSet { save() }
    }

    @Published var hoverGestureCorner: HoverGestureCorner {
        didSet { save() }
    }

    @Published var hoverGestureTimeoutSeconds: Double {
        didSet { save() }
    }

    @Published var armedCaptureDelaySeconds: Double {
        didSet { save() }
    }

    @Published var armedCaptureIntervalSeconds: Double {
        didSet { save() }
    }

    @Published var armedCaptureCount: Int {
        didSet { save() }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: defaultsKey) ?? defaults.data(forKey: legacyDefaultsKey),
           let persisted = try? JSONDecoder().decode(PersistedSettings.self, from: data) {
            selectedRegion = persisted.selectedRegion
            outputFolderPath = persisted.outputFolderPath
            imageFormat = persisted.imageFormat
            clickCount = Self.clampClickCount(persisted.clickCount)
            clickWindowSeconds = Self.clampClickWindowSeconds(persisted.clickWindowSeconds)
            triggerCooldownSeconds = Self.clampTriggerCooldownSeconds(persisted.triggerCooldownSeconds)
            triggersPaused = persisted.triggersPaused
            hoverGestureEnabled = persisted.hoverGestureEnabled ?? true
            hoverGestureCorner = persisted.hoverGestureCorner ?? .topLeft
            hoverGestureTimeoutSeconds = Self.clampHoverGestureTimeoutSeconds(persisted.hoverGestureTimeoutSeconds ?? 2.2)
            armedCaptureDelaySeconds = Self.clampArmedCaptureDelaySeconds(persisted.armedCaptureDelaySeconds ?? 5.0)
            armedCaptureIntervalSeconds = Self.clampArmedCaptureIntervalSeconds(persisted.armedCaptureIntervalSeconds ?? 2.0)
            armedCaptureCount = Self.clampArmedCaptureCount(persisted.armedCaptureCount ?? 6)
        } else {
            selectedRegion = nil
            outputFolderPath = Self.defaultOutputFolder.path
            imageFormat = .png
            clickCount = 5
            clickWindowSeconds = 1.4
            triggerCooldownSeconds = 2.0
            triggersPaused = false
            hoverGestureEnabled = true
            hoverGestureCorner = .topLeft
            hoverGestureTimeoutSeconds = 2.2
            armedCaptureDelaySeconds = 5.0
            armedCaptureIntervalSeconds = 2.0
            armedCaptureCount = 6
        }
    }

    static var defaultOutputFolder: URL {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        return (pictures ?? FileManager.default.homeDirectoryForCurrentUser)
            .appendingPathComponent("Screening Automation", isDirectory: true)
    }

    static func clampClickCount(_ value: Int) -> Int {
        min(max(value, 2), 12)
    }

    static func clampClickWindowSeconds(_ value: Double) -> Double {
        min(max(value, 0.4), 5.0)
    }

    static func clampTriggerCooldownSeconds(_ value: Double) -> Double {
        min(max(value, 0.2), 15.0)
    }

    static func clampHoverGestureTimeoutSeconds(_ value: Double) -> Double {
        min(max(value, 0.8), 5.0)
    }

    static func clampArmedCaptureDelaySeconds(_ value: Double) -> Double {
        min(max(value, 2.0), 60.0)
    }

    static func clampArmedCaptureIntervalSeconds(_ value: Double) -> Double {
        min(max(value, 0.5), 30.0)
    }

    static func clampArmedCaptureCount(_ value: Int) -> Int {
        min(max(value, 1), 120)
    }

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: outputFolderPath, isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url {
            outputFolderPath = url.path
        }
    }

    func revealOutputFolder() {
        let url = URL(fileURLWithPath: outputFolderPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    func captureRequest() -> CaptureRequest? {
        guard let selectedRegion else {
            return nil
        }
        return CaptureRequest(
            region: selectedRegion,
            outputFolderPath: outputFolderPath,
            imageFormat: imageFormat
        )
    }

    private func save() {
        let persisted = PersistedSettings(
            selectedRegion: selectedRegion,
            outputFolderPath: outputFolderPath,
            imageFormat: imageFormat,
            clickCount: clickCount,
            clickWindowSeconds: clickWindowSeconds,
            triggerCooldownSeconds: triggerCooldownSeconds,
            triggersPaused: triggersPaused,
            hoverGestureEnabled: hoverGestureEnabled,
            hoverGestureCorner: hoverGestureCorner,
            hoverGestureTimeoutSeconds: hoverGestureTimeoutSeconds,
            armedCaptureDelaySeconds: armedCaptureDelaySeconds,
            armedCaptureIntervalSeconds: armedCaptureIntervalSeconds,
            armedCaptureCount: armedCaptureCount
        )
        guard let data = try? JSONEncoder().encode(persisted) else {
            return
        }
        defaults.set(data, forKey: defaultsKey)
    }
}
