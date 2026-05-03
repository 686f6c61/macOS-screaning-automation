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

        NSColor.black.withAlphaComponent(0.28).setFill()
        bounds.fill()

        guard let selectionRect = currentSelectionRect else {
            drawPrompt()
            return
        }

        NSColor.clear.setFill()
        selectionRect.fill(using: .copy)

        NSColor.systemBlue.withAlphaComponent(0.14).setFill()
        selectionRect.fill()

        let border = NSBezierPath(rect: selectionRect)
        border.lineWidth = 2
        NSColor.systemBlue.setStroke()
        border.stroke()

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
            .font: NSFont.systemFont(ofSize: 18, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = text.size(withAttributes: attributes)
        let rect = CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        text.draw(in: rect, withAttributes: attributes)
    }

    private func drawInfo(for selectionRect: CGRect) {
        let region = CaptureRegion.fromSelection(localRect: selectionRect, on: screen)
        let text = "\(region.width)x\(region.height)  x:\(region.x) y:\(region.y)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let padding: CGFloat = 8
        let textSize = text.size(withAttributes: attributes)
        var rect = CGRect(
            x: selectionRect.minX,
            y: max(8, selectionRect.minY - textSize.height - padding * 2),
            width: textSize.width + padding * 2,
            height: textSize.height + padding
        )
        if rect.maxX > bounds.maxX - 8 {
            rect.origin.x = bounds.maxX - rect.width - 8
        }

        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()

        text.draw(
            in: rect.insetBy(dx: padding, dy: padding / 2),
            withAttributes: attributes
        )
    }
}
