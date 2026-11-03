// Log de diagnóstico local de la app.
//
// Se escribe en ~/Library/Logs/ScreeningAutomation (o ScreeningAutomation-Dev en
// la variante de desarrollo; carpeta 0700, archivo 0600)
// y en el log unificado del sistema. Antes de escribir se anonimizan las rutas
// personales: el log se puede copiar y compartir desde Ajustes al pedir ayuda.
// Rota a un único archivo `.1` al superar 512 KB.

import Foundation
import os

/// Registro de eventos para diagnosticar activadores, permisos y capturas.
enum DiagnosticLog {
    private static let maxLogBytes: UInt64 = 512 * 1024
    private static let privacyMigrationKey = "ScreeningAutomation.LogPrivacy.v2"
    private static let queue = DispatchQueue(label: "tech.686f6c61.screening-automation.diagnostic-log")
    private static let osLogger = Logger(subsystem: "tech.686f6c61.screening-automation", category: "diagnostics")

    private static var isTestProcess: Bool {
        NSClassFromString("XCTestCase") != nil
    }

    /// Carpeta del log. La variante de desarrollo (bundle ID `.dev`) usa una
    /// propia: comparte disco con la release pero no sus `UserDefaults`, y su
    /// `prepare()` borraría el log de la release en el primer arranque.
    static var folderURL: URL {
        let isDevBuild = Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true
        return FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(
                isDevBuild ? "Library/Logs/ScreeningAutomation-Dev" : "Library/Logs/ScreeningAutomation",
                isDirectory: true
            )
    }

    static var fileURL: URL {
        folderURL.appendingPathComponent("ScreeningAutomation.log", isDirectory: false)
    }

    private static var rotatedFileURL: URL {
        folderURL.appendingPathComponent("ScreeningAutomation.log.1", isDirectory: false)
    }

    /// Borra una vez los logs creados por versiones que no anonimizaban rutas.
    static func prepare() {
        guard !isTestProcess else {
            return
        }
        queue.sync {
            let defaults = UserDefaults.standard
            guard !defaults.bool(forKey: privacyMigrationKey) else {
                return
            }
            let fileManager = FileManager.default
            try? fileManager.removeItem(at: fileURL)
            try? fileManager.removeItem(at: rotatedFileURL)
            defaults.set(true, forKey: privacyMigrationKey)
        }
    }

    /// Añade una línea con marca de tiempo. Las rutas personales se anonimizan.
    /// No escribe nada cuando se ejecuta dentro de los tests.
    static func write(_ message: String) {
        guard !isTestProcess else {
            return
        }
        let sanitized = sanitizedMessage(message)
        osLogger.notice("\(sanitized, privacy: .public)")
        let line = "\(Date().formatted(.iso8601)) \(sanitized)\n"
        guard let data = line.data(using: .utf8) else {
            return
        }

        queue.sync {
            write(data)
        }
    }

    /// Últimas `limit` líneas del log. Si el archivo no existe devuelve una
    /// lista vacía; si existe pero no se puede leer, una línea que lo explica.
    static func recentLines(_ limit: Int = 30, from fileURL: URL = DiagnosticLog.fileURL) -> [String] {
        queue.sync {
            let data: Data
            do {
                data = try Data(contentsOf: fileURL)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                return []
            } catch {
                return ["<no se pudo leer el log: \(error.localizedDescription)>"]
            }
            let contents = String(decoding: data, as: UTF8.self)
            return contents
                .split(separator: "\n", omittingEmptySubsequences: true)
                .suffix(limit)
                .map(String.init)
        }
    }

    private static func write(_ data: Data) {
        let fileManager = FileManager.default

        do {
            try ensurePrivateDirectory(fileManager: fileManager)
            try rotateIfNeeded(fileManager: fileManager, incomingBytes: UInt64(data.count))
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                guard fileManager.createFile(
                    atPath: fileURL.path,
                    contents: data,
                    attributes: [.posixPermissions: 0o600]
                ) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
        } catch {
            NSLog("ScreeningAutomation diagnostic log error: \(error.localizedDescription)")
        }
    }

    /// Sustituye rutas personales por `<home>` y `<path>`.
    ///
    /// Una ruta puede contener espacios («Cliente X»), así que no termina en el
    /// primer espacio sino al final del mensaje, en una comilla o en el
    /// siguiente par `clave=` del formato de log.
    static func sanitizedMessage(_ message: String) -> String {
        var sanitized = message
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        if homePath.count > 1 {
            sanitized = sanitized.replacingOccurrences(of: homePath, with: "<home>")
        }

        // Una ruta termina en el siguiente `clave=`, en una comilla, en un salto
        // de línea o al final del mensaje.
        let pathEnd = #"(?=\s+[A-Za-z_]+=|["'“”\n]|$)"#
        // El orden importa: `<home>` debe ir antes que la regla genérica.
        let rules: [(pattern: String, replacement: String)] = [
            (#"<home>/[^\n"'“”]*?"# + pathEnd, "<home>/<path>"),
            (#"file://[^\n"'“”]*?"# + pathEnd, "<path>"),
            (#"/(?:Users|Volumes|private|var|tmp)/[^\n"'“”]*?"# + pathEnd, "<path>")
        ]
        for rule in rules {
            sanitized = sanitized.replacingOccurrences(
                of: rule.pattern,
                with: rule.replacement,
                options: .regularExpression
            )
        }
        return sanitized
    }

    private static func ensurePrivateDirectory(fileManager: FileManager) throws {
        try fileManager.createDirectory(
            at: folderURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folderURL.path)
    }

    private static func rotateIfNeeded(fileManager: FileManager, incomingBytes: UInt64) throws {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return
        }
        let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
        let currentSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        guard currentSize + incomingBytes > maxLogBytes else {
            return
        }

        do {
            if fileManager.fileExists(atPath: rotatedFileURL.path) {
                _ = try fileManager.replaceItemAt(rotatedFileURL, withItemAt: fileURL)
            } else {
                try fileManager.moveItem(at: fileURL, to: rotatedFileURL)
            }
        } catch {
            // Si no se puede rotar, se vacía el archivo actual: mejor perder el
            // historial que dejar de registrar para siempre.
            let note = sanitizedMessage("log rotation failed; log truncated error=\(error.localizedDescription)")
            NSLog("ScreeningAutomation diagnostic \(note)")
            try Data("\(Date().formatted(.iso8601)) \(note)\n".utf8).write(to: fileURL)
        }
    }
}
