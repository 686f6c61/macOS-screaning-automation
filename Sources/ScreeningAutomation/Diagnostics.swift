import AppKit
import Foundation

enum DiagnosticLog {
    private static let maxLogBytes: UInt64 = 512 * 1024
    private static let queue = DispatchQueue(label: "tech.686f6c61.screening-automation.diagnostic-log")

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

    static func write(_ message: String) {
        let formatter = ISO8601DateFormatter()
        let line = "\(formatter.string(from: Date())) \(message)\n"
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
            try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
            try rotateIfNeeded(fileManager: fileManager, incomingBytes: UInt64(data.count))
            if fileManager.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: fileURL)
            }
        } catch {
            NSLog("ScreeningAutomation diagnostic log error: \(error.localizedDescription)")
        }
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
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }
}
