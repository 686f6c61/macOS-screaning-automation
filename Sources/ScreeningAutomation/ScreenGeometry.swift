// Utilidades de geometría de pantallas y de nombres de archivo compartidas por
// la captura de imagen, la grabación de vídeo y los activadores.
//
// macOS usa dos sistemas de coordenadas globales:
// - AppKit (`NSScreen.frame`, `NSEvent.mouseLocation`): origen abajo a la
//   izquierda de la pantalla principal, Y crece hacia arriba.
// - Quartz (`CGDisplayBounds`, `CGEvent.location`, ScreenCaptureKit,
//   `screencapture -R`): origen arriba a la izquierda de la pantalla
//   principal, Y crece hacia abajo.
// La referencia de ambos es siempre la pantalla principal (la que tiene la
// barra de menús y origen AppKit en 0,0), no el rectángulo que envuelve a
// todas las pantallas.

import AppKit
import CoreGraphics
import Foundation

/// Conversión entre coordenadas AppKit y Quartz, y consultas sobre pantallas.
enum ScreenGeometry {
    /// Lado, en puntos, del cuadrado que se considera «esquina» de una pantalla.
    static let cornerSize: CGFloat = 72

    /// Identificador Quartz de una pantalla AppKit.
    @MainActor
    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }

    /// Altura de referencia para convertir entre AppKit y Quartz: el `maxY` de
    /// la pantalla principal. `NSScreen.screens.first` es siempre la principal.
    @MainActor
    static var primaryScreenMaxY: CGFloat {
        NSScreen.screens.first?.frame.maxY ?? CGDisplayBounds(CGMainDisplayID()).height
    }

    /// Convierte una coordenada Y global entre AppKit y Quartz. La operación es
    /// su propia inversa, así que sirve en los dos sentidos.
    static func flippedY(_ y: CGFloat, primaryScreenMaxY: CGFloat) -> CGFloat {
        primaryScreenMaxY - y
    }

    /// Convierte un punto Quartz global (por ejemplo, `CGEvent.location`) a AppKit.
    @MainActor
    static func appKitLocation(fromQuartz location: CGPoint) -> CGPoint {
        CGPoint(x: location.x, y: flippedY(location.y, primaryScreenMaxY: primaryScreenMaxY))
    }

    /// Indica si `point` (AppKit) está en la esquina `corner` de alguna pantalla.
    ///
    /// Se evalúa pantalla a pantalla: con monitores desalineados, la esquina del
    /// rectángulo que las envuelve a todas puede no existir físicamente.
    static func isInCorner(_ point: CGPoint, corner: HoverGestureCorner, screens: [CGRect]) -> Bool {
        screens.contains { frame in
            guard frame.insetBy(dx: -0.5, dy: -0.5).contains(point) else {
                return false
            }
            switch corner {
            case .topLeft:
                return point.x <= frame.minX + cornerSize && point.y >= frame.maxY - cornerSize
            case .topRight:
                return point.x >= frame.maxX - cornerSize && point.y >= frame.maxY - cornerSize
            case .bottomLeft:
                return point.x <= frame.minX + cornerSize && point.y <= frame.minY + cornerSize
            case .bottomRight:
                return point.x >= frame.maxX - cornerSize && point.y <= frame.minY + cornerSize
            }
        }
    }
}

/// Nombres y rutas de los archivos generados (capturas y vídeos).
enum CaptureFileNaming {
    // `DateFormatter` es `Sendable` y seguro entre hilos; se comparte para no
    // crear uno por captura.
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        return formatter
    }()

    /// Nombre con marca de tiempo al milisegundo, p. ej. `SA_2026-11-03_16-39-01-123.png`.
    static func fileName(fileExtension: String, date: Date = Date()) -> String {
        "SA_\(formatter.string(from: date)).\(fileExtension)"
    }

    /// Crea la carpeta de salida si no existe y devuelve la URL del nuevo archivo.
    ///
    /// - Throws: el error de `FileManager` si la carpeta no se puede crear.
    static func makeURL(in folderPath: String, fileExtension: String) throws -> URL {
        let folderURL = URL(fileURLWithPath: folderPath, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        return folderURL.appendingPathComponent(fileName(fileExtension: fileExtension), isDirectory: false)
    }
}
