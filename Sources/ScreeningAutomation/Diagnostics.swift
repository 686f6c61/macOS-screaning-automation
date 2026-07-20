import AppKit
import Foundation

enum DiagnosticLog {
    private static let maxLogBytes: UInt64 = 512 * 1024
    private static let privacyMigrationKey = "ScreeningAutomation.LogPrivacy.v2"
    private static let queue = DispatchQueue(label: "tech.686f6c61.screening-automation.diagnostic-log")

    private static var isTestProcess: Bool {
        NSClassFromString("XCTestCase") != nil
    }

    static var folderURL: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ScreeningAutomation", isDirectory: true)
    }

    static var fileURL: URL {
        folderURL.appendingPathComponent("ScreeningAutomation.log", isDirectory: false)
    }

    private static var rotatedFileURL: URL {
        folderURL.appendingPathComponent("ScreeningAutomation.log.1", isDirectory: false)
    }

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

    static func write(_ message: String) {
        guard !isTestProcess else {
            return
        }
        let formatter = ISO8601DateFormatter()
        let line = "\(formatter.string(from: Date())) \(sanitizedMessage(message))\n"
        guard let data = line.data(using: .utf8) else {
            return
        }

        queue.sync {
            write(data)
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

    static func sanitizedMessage(_ message: String) -> String {
        var sanitized = message
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        if homePath.count > 1 {
            sanitized = sanitized.replacingOccurrences(of: homePath, with: "<home>")
        }

        for pattern in [
            #"file://[^\s]+"#,
            #"/(?:Users|Volumes|private|var|tmp)/[^\s]+"#
        ] {
            sanitized = sanitized.replacingOccurrences(
                of: pattern,
                with: "<path>",
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

        if fileManager.fileExists(atPath: rotatedFileURL.path) {
            try? fileManager.removeItem(at: rotatedFileURL)
        }
        try fileManager.moveItem(at: fileURL, to: rotatedFileURL)
    }

    static func reveal() {
        try? ensurePrivateDirectory(fileManager: .default)
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }
}
