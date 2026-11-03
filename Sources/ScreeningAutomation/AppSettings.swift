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

    /// Convierte una selección hecha sobre `screen` en una zona Quartz global.
    @MainActor
    static func fromSelection(localRect: CGRect, on screen: NSScreen) -> CaptureRegion {
        fromSelection(
            localRect: localRect,
            screenFrame: screen.frame,
            primaryScreenMaxY: ScreenGeometry.primaryScreenMaxY,
            displayName: screen.localizedName
        )
    }

    /// Variante pura, testeable sin `NSScreen`.
    ///
    /// - Parameters:
    ///   - localRect: selección en coordenadas AppKit locales de la pantalla.
    ///   - screenFrame: `frame` AppKit de la pantalla donde se seleccionó.
    ///   - primaryScreenMaxY: `maxY` de la pantalla principal, que es la
    ///     referencia del eje Y en Quartz. No vale el máximo de todas las
    ///     pantallas: con un monitor colocado encima de la principal, eso
    ///     desplazaría todas las capturas.
    static func fromSelection(
        localRect: CGRect,
        screenFrame: CGRect,
        primaryScreenMaxY: CGFloat,
        displayName: String,
        createdAt: Date = Date()
    ) -> CaptureRegion {
        let globalRect = CGRect(
            x: screenFrame.minX + localRect.minX,
            y: screenFrame.minY + localRect.minY,
            width: localRect.width,
            height: localRect.height
        )
        let captureY = ScreenGeometry.flippedY(globalRect.maxY, primaryScreenMaxY: primaryScreenMaxY)

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
    case pdf
    case tiff

    var id: String { rawValue }

    var fileExtension: String {
        rawValue
    }

    var screencaptureToken: String {
        self == .tiff ? "tif" : rawValue
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
            return L10n.t("Arriba izquierda")
        case .topRight:
            return L10n.t("Arriba derecha")
        case .bottomLeft:
            return L10n.t("Abajo izquierda")
        case .bottomRight:
            return L10n.t("Abajo derecha")
        }
    }
}

/// Forma serializada de los ajustes en `UserDefaults` (JSON). Los campos
/// opcionales se añadieron en versiones posteriores y toman su valor por
/// defecto al leer datos antiguos.
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

/// Ajustes de usuario observables y persistidos.
///
/// Cada cambio se guarda al instante en `UserDefaults`. Los valores numéricos se
/// acotan a sus rangos (`...Range`) al cargar, por si el JSON se editó a mano o
/// viene de una versión con otros límites; la interfaz usa esos mismos rangos.
@MainActor
final class AppSettings: ObservableObject {
    // MARK: Rangos y valores por defecto (fuente única para modelo e interfaz)

    static let clickCountRange = 2...12
    static let clickWindowRange = 0.4...5.0
    static let triggerCooldownRange = 0.2...15.0
    static let hoverGestureTimeoutRange = 0.8...5.0
    static let armedCaptureDelayRange = 2.0...60.0
    static let armedCaptureIntervalRange = 0.5...30.0
    static let armedCaptureCountRange = 1...120

    static let defaultClickCount = 5
    static let defaultClickWindowSeconds = 1.4
    static let defaultTriggerCooldownSeconds = 2.0
    static let defaultHoverGestureTimeoutSeconds = 2.2
    static let defaultArmedCaptureDelaySeconds = 5.0
    static let defaultArmedCaptureIntervalSeconds = 2.0
    static let defaultArmedCaptureCount = 6

    private let defaultsKey = "ScreeningAutomation.Settings.v1"
    /// Clave de la app cuando se llamaba «Monitor Screening»; solo se lee.
    private let legacyDefaultsKey = "MonitorScreening.Settings.v1"
    private let defaults: UserDefaults
    private(set) var hadPersistedSettings = false
    /// Aviso para el usuario si los ajustes guardados no se pudieron leer.
    @Published private(set) var loadWarning: String?

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

    /// Carga los ajustes guardados o, si no hay, los valores por defecto.
    ///
    /// Si existen datos pero no se pueden decodificar, se conserva una copia en
    /// otra clave antes de que el primer cambio los sobrescriba, y se publica
    /// `loadWarning` para avisar al usuario.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let data = defaults.data(forKey: defaultsKey) ?? defaults.data(forKey: legacyDefaultsKey)
        var persisted: PersistedSettings?
        if let data {
            do {
                persisted = try JSONDecoder().decode(PersistedSettings.self, from: data)
            } catch {
                let backupKey = "\(defaultsKey).unreadable-\(Int(Date().timeIntervalSince1970))"
                defaults.set(data, forKey: backupKey)
                DiagnosticLog.write("settings decode failed backupKey=\(backupKey) error=\(error.localizedDescription)")
                loadWarning = L10n.t("No se pudieron leer los ajustes guardados; se han restaurado los valores por defecto.")
            }
        }

        hadPersistedSettings = persisted != nil
        selectedRegion = persisted?.selectedRegion
        outputFolderPath = persisted?.outputFolderPath ?? Self.defaultOutputFolder.path
        imageFormat = persisted?.imageFormat ?? .png
        clickCount = Self.clampClickCount(persisted?.clickCount ?? Self.defaultClickCount)
        clickWindowSeconds = Self.clampClickWindowSeconds(persisted?.clickWindowSeconds ?? Self.defaultClickWindowSeconds)
        triggerCooldownSeconds = Self.clampTriggerCooldownSeconds(
            persisted?.triggerCooldownSeconds ?? Self.defaultTriggerCooldownSeconds
        )
        triggersPaused = persisted?.triggersPaused ?? false
        hoverGestureEnabled = persisted?.hoverGestureEnabled ?? true
        hoverGestureCorner = persisted?.hoverGestureCorner ?? .topLeft
        hoverGestureTimeoutSeconds = Self.clampHoverGestureTimeoutSeconds(
            persisted?.hoverGestureTimeoutSeconds ?? Self.defaultHoverGestureTimeoutSeconds
        )
        armedCaptureDelaySeconds = Self.clampArmedCaptureDelaySeconds(
            persisted?.armedCaptureDelaySeconds ?? Self.defaultArmedCaptureDelaySeconds
        )
        armedCaptureIntervalSeconds = Self.clampArmedCaptureIntervalSeconds(
            persisted?.armedCaptureIntervalSeconds ?? Self.defaultArmedCaptureIntervalSeconds
        )
        armedCaptureCount = Self.clampArmedCaptureCount(persisted?.armedCaptureCount ?? Self.defaultArmedCaptureCount)
    }

    static var defaultOutputFolder: URL {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        return (pictures ?? FileManager.default.homeDirectoryForCurrentUser)
            .appendingPathComponent("Screening Automation", isDirectory: true)
    }

    static func clampClickCount(_ value: Int) -> Int {
        clamp(value, to: clickCountRange)
    }

    static func clampClickWindowSeconds(_ value: Double) -> Double {
        clamp(value, to: clickWindowRange)
    }

    static func clampTriggerCooldownSeconds(_ value: Double) -> Double {
        clamp(value, to: triggerCooldownRange)
    }

    static func clampHoverGestureTimeoutSeconds(_ value: Double) -> Double {
        clamp(value, to: hoverGestureTimeoutRange)
    }

    static func clampArmedCaptureDelaySeconds(_ value: Double) -> Double {
        clamp(value, to: armedCaptureDelayRange)
    }

    static func clampArmedCaptureIntervalSeconds(_ value: Double) -> Double {
        clamp(value, to: armedCaptureIntervalRange)
    }

    static func clampArmedCaptureCount(_ value: Int) -> Int {
        clamp(value, to: armedCaptureCountRange)
    }

    private static func clamp<Value: Comparable>(_ value: Value, to range: ClosedRange<Value>) -> Value {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// Descarta el aviso de ajustes ilegibles una vez mostrado.
    func dismissLoadWarning() {
        loadWarning = nil
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

    /// Abre la carpeta de salida en Finder, creándola si no existe.
    func revealOutputFolder() {
        let url = URL(fileURLWithPath: outputFolderPath, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            DiagnosticLog.write("output folder create failed error=\(error.localizedDescription)")
        }
        if !NSWorkspace.shared.open(url) {
            DiagnosticLog.write("output folder could not be opened")
            NSSound.beep()
        }
    }

    /// Petición de captura con la configuración actual, o `nil` sin zona.
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
        do {
            defaults.set(try JSONEncoder().encode(persisted), forKey: defaultsKey)
        } catch {
            DiagnosticLog.write("settings encode failed error=\(error.localizedDescription)")
        }
    }
}
