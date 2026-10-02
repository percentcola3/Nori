import AppKit
import SwiftUI

/// A titled NSWindow draws an inactive dark frame even when its background is clear.
/// Keep window operations in AppKit while letting the single glass surface own the edge.
final class NoriMainWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    private var resizeStart: (frame: NSRect, pointer: NSPoint, edges: NSEdgeInsets)?
    private var styleBeforeMiniaturizing: NSWindow.StyleMask?
    private var restoreObserver: NSObjectProtocol?

    override func miniaturize(_ sender: Any?) {
        guard !isMiniaturized else { return }
        // AppKit only creates a Dock thumbnail for titled windows. Keep this style
        // while hidden and restore our chrome once the native restore finishes.
        if !styleMask.contains(.titled) {
            styleBeforeMiniaturizing = styleMask
            let originalFrame = frame
            styleMask.formUnion([.titled, .fullSizeContentView])
            titlebarAppearsTransparent = true
            titleVisibility = .hidden
            for kind in [ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                standardWindowButton(kind)?.isHidden = true
            }
            setFrame(originalFrame, display: false)
            if restoreObserver == nil {
                restoreObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.didDeminiaturizeNotification, object: self, queue: .main
                ) { [weak self] _ in self?.restoreBorderlessChrome() }
            }
        }
        super.miniaturize(sender)
    }

    private func restoreBorderlessChrome() {
        guard let originalStyle = styleBeforeMiniaturizing else { return }
        styleBeforeMiniaturizing = nil
        let restoredFrame = frame
        styleMask = originalStyle
        setFrame(restoredFrame, display: true)
    }

    deinit {
        if let restoreObserver { NotificationCenter.default.removeObserver(restoreObserver) }
    }

    override func sendEvent(_ event: NSEvent) {
        // Borderless windows have no frame view to handle edge resizing.
        if event.type == .leftMouseDown, !styleMask.contains(.fullScreen) {
            let p = event.locationInWindow
            let edges = NSEdgeInsets(top: p.y > frame.height - 6 ? 1 : 0,
                                     left: p.x < 6 ? 1 : 0,
                                     bottom: p.y < 6 ? 1 : 0,
                                     right: p.x > frame.width - 6 ? 1 : 0)
            if edges.top + edges.left + edges.bottom + edges.right > 0 {
                makeKeyAndOrderFront(nil)
                resizeStart = (frame, convertPoint(toScreen: event.locationInWindow), edges)
                return
            }
        }
        if let start = resizeStart {
            if event.type == .leftMouseDragged {
                let pointer = convertPoint(toScreen: event.locationInWindow)
                let dx = pointer.x - start.pointer.x
                let dy = pointer.y - start.pointer.y
                var rect = start.frame
                if start.edges.right > 0 { rect.size.width += dx }
                if start.edges.left > 0 { rect.size.width -= dx }
                if start.edges.top > 0 { rect.size.height += dy }
                if start.edges.bottom > 0 { rect.size.height -= dy }
                rect.size.width = min(max(rect.width, minSize.width), maxSize.width)
                rect.size.height = min(max(rect.height, minSize.height), maxSize.height)
                if start.edges.left > 0 { rect.origin.x = start.frame.maxX - rect.width }
                if start.edges.bottom > 0 { rect.origin.y = start.frame.maxY - rect.height }
                setFrame(rect, display: true)
                return
            }
            if event.type == .leftMouseUp {
                resizeStart = nil
                return
            }
        }
        super.sendEvent(event)
    }
}

struct MainWindowControls: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { TrafficLightsView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class TrafficLightsView: NSView {
        override init(frame: NSRect) {
            super.init(frame: frame)
            for (index, kind) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
                guard let button = NSWindow.standardWindowButton(kind, for: [.titled, .closable, .miniaturizable, .resizable]) else { continue }
                button.setFrameOrigin(NSPoint(x: index * 20, y: 7))
                button.target = self
                button.action = index == 0 ? #selector(closeWindow) : index == 1 ? #selector(minimizeWindow) : #selector(fullScreenWindow)
                addSubview(button)
            }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        // performClose requires AppKit's frame close button, which a borderless
        // window does not have. The main window has no unsaved document delegate.
        @objc private func closeWindow() { window?.close() }
        @objc private func minimizeWindow() { window?.miniaturize(nil) }
        @objc private func fullScreenWindow() {
            if NSEvent.modifierFlags.contains(.option) { window?.zoom(nil) }
            else { window?.toggleFullScreen(nil) }
        }
    }
}

/// Only the unused header space accepts drags; buttons keep their normal hit testing.
struct MainWindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
                case "Minimize": window?.miniaturize(nil)
                case "None": break
                default: window?.zoom(nil)
                }
            } else { window?.performDrag(with: event) }
        }
    }
}
