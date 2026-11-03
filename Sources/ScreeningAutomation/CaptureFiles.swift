// Archivos generados por la app (capturas y vídeos): nombre, permisos y borrado.

import Foundation

/// Operaciones sobre los archivos de salida, compartidas por captura y vídeo.
enum CaptureFiles {
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

    /// Deja el archivo legible solo por el usuario (0600). Si falla, se
    /// registra pero no se interrumpe: el archivo ya está guardado.
    static func harden(at fileURL: URL) {
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            DiagnosticLog.write("file harden failed file=\(fileURL.lastPathComponent) error=\(error.localizedDescription)")
        }
    }

    /// Borra un archivo. Que no exista no es un error; cualquier otro fallo se
    /// registra para que no pase desapercibido.
    static func remove(at fileURL: URL) {
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        } catch {
            DiagnosticLog.write("file remove failed file=\(fileURL.lastPathComponent) error=\(error.localizedDescription)")
        }
    }
}
