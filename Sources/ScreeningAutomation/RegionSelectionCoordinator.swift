import AppKit
import Foundation

@MainActor
final class RegionSelectionCoordinator {
    private var windows: [NSWindow] = []
    private var completion: ((CaptureRegion) -> Void)?

    func begin(completion: @escaping (CaptureRegion) -> Void) {
        cancel()
        self.completion = completion

        NSApp.activate(ignoringOtherApps: true)

        windows = NSScreen.screens.map { screen in
            let view = SelectionOverlayView(screen: screen)
            view.onCancel = { [weak self] in
                self?.cancel()
            }
            view.onComplete = { [weak self] region in
                self?.complete(with: region)
            }

            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.ignoresMouseEvents = false
            window.acceptsMouseMovedEvents = true
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            view.window?.makeFirstResponder(view)
            return window
        }
    }

    func cancel() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        completion = nil
    }

    private func complete(with region: CaptureRegion) {
        let completion = completion
        cancel()
        completion?(region)
    }
}

private final class SelectionOverlayView: NSView {
    var onComplete: ((CaptureRegion) -> Void)?
    var onCancel: (() -> Void)?

    private let screen: NSScreen
    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?

    init(screen: NSScreen) {
        self.screen = screen
        super.init(frame: CGRect(origin: .zero, size: screen.frame.size))
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        dragStart = point
        dragCurrent = point
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        dragCurrent = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        dragCurrent = convert(event.locationInWindow, from: nil)
        guard let rect = currentSelectionRect, rect.width >= 6, rect.height >= 6 else {
            dragStart = nil
            dragCurrent = nil
            needsDisplay = true
            return
        }
        onComplete?(CaptureRegion.fromSelection(localRect: rect, on: screen))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let selectionRect = currentSelectionRect else {
            drawPrompt()
            return
        }

        drawSelectionFrame(selectionRect)
        drawCornerHandles(selectionRect)
        drawInfo(for: selectionRect)
    }

    private var currentSelectionRect: CGRect? {
        guard let dragStart, let dragCurrent else {
            return nil
        }
        let rect = CGRect(
            x: min(dragStart.x, dragCurrent.x),
            y: min(dragStart.y, dragCurrent.y),
            width: abs(dragCurrent.x - dragStart.x),
            height: abs(dragCurrent.y - dragStart.y)
        )
        return rect.integral
    }

    private func drawPrompt() {
        let text = "Arrastra para definir la zona"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let padding = CGSize(width: 14, height: 8)
        let size = text.size(withAttributes: attributes)
        let rect = CGRect(
            x: bounds.midX - (size.width + padding.width * 2) / 2,
            y: bounds.midY - (size.height + padding.height * 2) / 2,
            width: size.width + padding.width * 2,
            height: size.height + padding.height * 2
        )

        NSColor.black.withAlphaComponent(0.56).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()

        text.draw(
            in: rect.insetBy(dx: padding.width, dy: padding.height),
            withAttributes: attributes
        )
    }

    private func drawSelectionFrame(_ selectionRect: CGRect) {
        let rect = selectionRect.insetBy(dx: 0.5, dy: 0.5)

        let shadow = NSBezierPath(rect: rect)
        shadow.lineWidth = 2
        applyFrameDash(to: shadow, phase: 0)
        NSColor.black.withAlphaComponent(0.07).setStroke()
        shadow.stroke()

        let highlight = NSBezierPath(rect: rect)
        highlight.lineWidth = 1
        applyFrameDash(to: highlight, phase: 0)
        NSColor.white.withAlphaComponent(0.24).setStroke()
        highlight.stroke()

        let accent = NSBezierPath(rect: rect.insetBy(dx: 1.5, dy: 1.5))
        accent.lineWidth = 1
        applyFrameDash(to: accent, phase: 5)
        NSColor.systemTeal.withAlphaComponent(0.16).setStroke()
        accent.stroke()
    }

    private func drawCornerHandles(_ selectionRect: CGRect) {
        let side = max(12, min(24, min(selectionRect.width, selectionRect.height) / 3))
        let rect = selectionRect.insetBy(dx: 0.5, dy: 0.5)

        let shadow = cornerHandlesPath(for: rect, side: side)
        shadow.lineWidth = 3
        shadow.lineCapStyle = .round
        shadow.lineJoinStyle = .round
        NSColor.black.withAlphaComponent(0.08).setStroke()
        shadow.stroke()

        let handles = cornerHandlesPath(for: rect, side: side)
        handles.lineWidth = 1.5
        handles.lineCapStyle = .round
        handles.lineJoinStyle = .round
        NSColor.systemTeal.withAlphaComponent(0.26).setStroke()
        handles.stroke()
    }

    private func applyFrameDash(to path: NSBezierPath, phase: CGFloat) {
        let pattern: [CGFloat] = [6, 5]
        pattern.withUnsafeBufferPointer { buffer in
            path.setLineDash(buffer.baseAddress, count: buffer.count, phase: phase)
        }
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
    }

    private func cornerHandlesPath(for rect: CGRect, side: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()

        path.move(to: CGPoint(x: rect.minX, y: rect.minY + side))
        path.line(to: CGPoint(x: rect.minX, y: rect.minY))
        path.line(to: CGPoint(x: rect.minX + side, y: rect.minY))

        path.move(to: CGPoint(x: rect.maxX - side, y: rect.minY))
        path.line(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.line(to: CGPoint(x: rect.maxX, y: rect.minY + side))

        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - side))
        path.line(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.line(to: CGPoint(x: rect.maxX - side, y: rect.maxY))

        path.move(to: CGPoint(x: rect.minX + side, y: rect.maxY))
        path.line(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.line(to: CGPoint(x: rect.minX, y: rect.maxY - side))

        return path
    }

    private func drawInfo(for selectionRect: CGRect) {
        let region = CaptureRegion.fromSelection(localRect: selectionRect, on: screen)
        let text = "\(region.width)x\(region.height)  x:\(region.x) y:\(region.y)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let padding = CGSize(width: 8, height: 5)
        let textSize = text.size(withAttributes: attributes)
        var rect = CGRect(
            x: selectionRect.minX,
            y: selectionRect.minY - textSize.height - padding.height * 2 - 7,
            width: textSize.width + padding.width * 2,
            height: textSize.height + padding.height * 2
        )
        if rect.minY < bounds.minY + 8 {
            rect.origin.y = min(bounds.maxY - rect.height - 8, selectionRect.maxY + 7)
        }
        if rect.maxX > bounds.maxX - 8 {
            rect.origin.x = bounds.maxX - rect.width - 8
        }
        if rect.minX < bounds.minX + 8 {
            rect.origin.x = bounds.minX + 8
        }

        NSColor.black.withAlphaComponent(0.64).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()

        text.draw(
            in: rect.insetBy(dx: padding.width, dy: padding.height),
            withAttributes: attributes
        )
    }
}
