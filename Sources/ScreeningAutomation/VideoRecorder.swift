import AppKit
import AVFoundation
import Combine
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

struct VideoRegionDescriptor {
    var displayID: CGDirectDisplayID
    var quartzBounds: CGRect
    var scale: CGFloat
}

enum VideoRegionResolver {
    static func resolve(
        region: CaptureRegion,
        descriptors: [VideoRegionDescriptor]
    ) -> (displayID: CGDirectDisplayID, localRect: CGRect, scale: CGFloat)? {
        let center = CGPoint(
            x: CGFloat(region.x) + CGFloat(region.width) / 2,
            y: CGFloat(region.y) + CGFloat(region.height) / 2
        )
        for descriptor in descriptors where descriptor.quartzBounds.contains(center) {
            let localRect = CGRect(
                x: CGFloat(region.x) - descriptor.quartzBounds.minX,
                y: CGFloat(region.y) - descriptor.quartzBounds.minY,
                width: CGFloat(region.width),
                height: CGFloat(region.height)
            )
            return (descriptor.displayID, localRect, descriptor.scale)
        }
        return nil
    }
}

final class VideoWriterSession: @unchecked Sendable {
    let queue = DispatchQueue(label: "tech.686f6c61.screening-automation.video-writer")

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private var startedWriting = false
    private var startedSession = false

    init?(url: URL, pixelWidth: Int, pixelHeight: Int) {
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else {
            return nil
        }
        self.writer = writer
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: pixelWidth,
            AVVideoHeightKey: pixelHeight
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        queue.async {
            guard self.writer.status == .writing else {
                return
            }
            if !self.startedWriting {
                self.writer.startWriting()
                self.startedWriting = true
            }
            if !self.startedSession {
                self.writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
                self.startedSession = true
            }
            guard self.input.isReadyForMoreMediaData else {
                return
            }
            self.input.append(sampleBuffer)
        }
    }

    func finish(completion: @escaping (Bool) -> Void) {
        queue.async {
            guard self.startedWriting else {
                completion(false)
                return
            }
            self.input.markAsFinished()
            self.writer.finishWriting {
                completion(self.writer.status == .completed)
            }
        }
    }
}

private final class FrameForwarder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    var session: VideoWriterSession?

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else {
            return
        }
        session?.append(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DiagnosticLog.write("video stream stopped error=\(error.localizedDescription)")
    }
}

@MainActor
final class VideoRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var lastMessage = ""
    @Published private(set) var elapsedDescription = "0:00"

    private let settings: AppSettings
    private let maxDuration: TimeInterval
    private var stream: SCStream?
    private var forwarder: FrameForwarder?
    private var session: VideoWriterSession?
    private var fileURL: URL?
    private var timer: Timer?
    private var startedAt: Date?

    init(settings: AppSettings, maxDuration: TimeInterval = 600) {
        self.settings = settings
        self.maxDuration = maxDuration
    }

    func toggle() {
        if isRecording {
            stop()
        } else {
            start()
        }
    }

    func start() {
        guard !isRecording else {
            return
        }
        guard let request = settings.captureRequest() else {
            lastMessage = CaptureError.missingRegion.localizedDescription
            DiagnosticLog.write("video skipped reason=missing-region")
            NSSound.beep()
            return
        }

        isRecording = true
        lastMessage = L10n.t("Preparando grabacion...")
        elapsedDescription = "0:00"
        Task {
            await startSession(request: request)
        }
    }

    func stop() {
        guard isRecording else {
            return
        }
        isRecording = false
        stopTimer()
        startedAt = nil
        elapsedDescription = "0:00"

        let stream = stream
        let session = session
        let fileURL = fileURL
        self.stream = nil
        self.forwarder = nil
        self.session = nil
        self.fileURL = nil
        lastMessage = L10n.t("Guardando grabacion...")
        DiagnosticLog.write("video recording stop requested")

        Task {
            if let stream {
                try? await stream.stopCapture()
            }
            guard let session, let fileURL else {
                return
            }
            let saved = await withCheckedContinuation { continuation in
                session.finish { continuation.resume(returning: $0) }
            }
            if saved {
                CaptureManager.hardenCaptureFile(at: fileURL)
                lastMessage = L10n.format("Guardado: %@", fileURL.lastPathComponent)
                DiagnosticLog.write("video recording saved file=\(fileURL.lastPathComponent)")
            } else {
                try? FileManager.default.removeItem(at: fileURL)
                lastMessage = L10n.t("La grabacion no se pudo guardar.")
                DiagnosticLog.write("video recording failed to finalize")
            }
        }
    }

    private func startSession(request: CaptureRequest) async {
        let resolved = VideoRegionResolver.resolve(
            region: request.region,
            descriptors: Self.screenDescriptors()
        )
        guard let resolved else {
            finishWithError(L10n.t("La zona no esta en ninguna pantalla activa."))
            return
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == resolved.displayID }) else {
                finishWithError(L10n.t("No se encontro la pantalla de la zona."))
                return
            }

            let folderURL = URL(fileURLWithPath: request.outputFolderPath, isDirectory: true)
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            let url = folderURL.appendingPathComponent(Self.makeFileName(), isDirectory: false)
            let pixelWidth = max(2, Int(resolved.localRect.width * resolved.scale))
            let pixelHeight = max(2, Int(resolved.localRect.height * resolved.scale))
            guard let session = VideoWriterSession(url: url, pixelWidth: pixelWidth, pixelHeight: pixelHeight) else {
                try? FileManager.default.removeItem(at: url)
                finishWithError(L10n.t("No se pudo preparar el archivo de video."))
                return
            }

            let configuration = SCStreamConfiguration()
            configuration.sourceRect = resolved.localRect
            configuration.width = pixelWidth
            configuration.height = pixelHeight
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            configuration.queueDepth = 5
            configuration.showsCursor = true
            configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let forwarder = FrameForwarder()
            forwarder.session = session
            let stream = SCStream(filter: filter, configuration: configuration, delegate: forwarder)
            try stream.addStreamOutput(forwarder, type: .screen, sampleHandlerQueue: session.queue)
            try await stream.startCapture()

            self.stream = stream
            self.forwarder = forwarder
            self.session = session
            self.fileURL = url
            startedAt = Date()
            lastMessage = L10n.t("Grabando video de la zona")
            startTimer()
            DiagnosticLog.write("video recording started size=\(pixelWidth)x\(pixelHeight)")
        } catch {
            DiagnosticLog.write("video recording failed to start error=\(error.localizedDescription)")
            finishWithError(error.localizedDescription)
        }
    }

    private func finishWithError(_ message: String) {
        isRecording = false
        stopTimer()
        startedAt = nil
        elapsedDescription = "0:00"
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
        stream = nil
        forwarder = nil
        session = nil
        fileURL = nil
        lastMessage = message
        NSSound.beep()
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateElapsed()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func updateElapsed() {
        guard isRecording, let startedAt else {
            return
        }
        let elapsed = Date().timeIntervalSince(startedAt)
        elapsedDescription = Self.format(elapsed: elapsed)
        if elapsed >= maxDuration {
            DiagnosticLog.write("video recording reached max duration")
            stop()
        }
    }

    nonisolated static func screenDescriptors() -> [VideoRegionDescriptor] {
        MainActor.assumeIsolated {
            NSScreen.screens.compactMap { screen in
                guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                    return nil
                }
                let displayID = CGDirectDisplayID(number.uint32Value)
                return VideoRegionDescriptor(
                    displayID: displayID,
                    quartzBounds: CGDisplayBounds(displayID),
                    scale: screen.backingScaleFactor
                )
            }
        }
    }

    nonisolated static func format(elapsed: TimeInterval) -> String {
        let total = max(0, Int(elapsed))
        let minutes = min(99, total / 60)
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    nonisolated private static func makeFileName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        return "SA_\(formatter.string(from: Date())).mp4"
    }
}
