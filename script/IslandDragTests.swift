import AppKit
import SwiftUI

private final class FlippedDragRoot: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class DragFixture {
    struct Report {
        let delta: CGFloat
        let phase: String
    }
    let panel = IslandPanel(contentRect: NSRect(x: 200, y: 300, width: 200, height: 200),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
    let root = FlippedDragRoot(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
    let view = IslandDragView()
    var reports: [Report] = []
    var clicks = 0
    var movesPanel = false
    var anchor = NSPoint(x: 200, y: 300)
    private var sequence = 0

    init() {
        panel.isReleasedWhenClosed = false
        panel.contentView = root
        view.frame = NSRect(x: 20, y: 20, width: 20, height: 96)
        root.addSubview(view)
        view.onClick = { [weak self] in self?.clicks += 1 }
        view.onDrag = { [weak self] delta, phase in
            guard let self else { return }
            let name: String
            switch phase {
            case .began:
                name = "began"
                anchor = panel.frame.origin
            case .changed: name = "changed"
            case .ended: name = "ended"
            case .cancelled: name = "cancelled"
            }
            reports.append(Report(delta: delta, phase: name))
            if movesPanel {
                if name == "changed" || name == "ended" {
                    panel.setFrameOrigin(NSPoint(x: anchor.x, y: anchor.y + delta))
                } else if name == "cancelled" {
                    panel.setFrameOrigin(anchor)
                }
            }
        }
    }

    func reset(movesPanel: Bool = false) {
        panel.setFrameOrigin(NSPoint(x: 200, y: 300))
        view.isEnabled = true
        if view.superview == nil { root.addSubview(view) }
        reports = []
        clicks = 0
        self.movesPanel = movesPanel
    }

    var center: NSPoint {
        panel.convertPoint(toScreen: view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil))
    }

    func event(_ type: NSEvent.EventType, at screenPoint: NSPoint) -> NSEvent {
        sequence += 1
        return NSEvent.mouseEvent(with: type, location: panel.convertPoint(fromScreen: screenPoint),
            modifierFlags: [], timestamp: TimeInterval(sequence), windowNumber: panel.windowNumber,
            context: nil, eventNumber: sequence, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
    }

    func down(_ point: NSPoint) { view.mouseDown(with: event(.leftMouseDown, at: point)) }
    func drag(_ point: NSPoint) { view.mouseDragged(with: event(.leftMouseDragged, at: point)) }
    func up(_ point: NSPoint) { view.mouseUp(with: event(.leftMouseUp, at: point)) }
}

@main
@MainActor
struct IslandDragTests {
    static func offset(_ point: NSPoint, x: CGFloat = 0, y: CGFloat = 0) -> NSPoint {
        NSPoint(x: point.x + x, y: point.y + y)
    }

    static func near(_ value: CGFloat, _ expected: CGFloat) -> Bool { abs(value - expected) < 0.01 }

    static func main() {
        _ = NSApplication.shared
        let fixture = DragFixture()
        defer { fixture.panel.close() }
        precondition(fixture.view.acceptsFirstMouse(for: nil), "An inactive side handle must accept its first click")
        precondition(!fixture.view.needsPanelToBecomeKey, "Dragging the nonactivating panel must not request key focus")
        precondition(!fixture.panel.isKeyWindow)

        fixture.reset()
        var start = fixture.center
        fixture.down(start)
        precondition(fixture.reports.map(\.phase) == ["began"] && near(fixture.reports[0].delta, 0),
                     "Mouse-down must immediately lock hover before any drag threshold")
        fixture.up(start)
        precondition(fixture.reports.map(\.phase) == ["began", "cancelled"] && fixture.clicks == 1,
                     "A simple click must release transient drag state and expand exactly once")

        fixture.reset()
        start = fixture.center
        fixture.down(start)
        fixture.drag(offset(start, x: 1, y: 2))
        fixture.up(offset(start, x: 1, y: 2))
        precondition(fixture.clicks == 1 && fixture.reports.map(\.phase) == ["began", "cancelled"],
                     "Subthreshold jitter must remain a single click, without changing position")

        fixture.reset(movesPanel: true)
        start = fixture.center
        fixture.down(start)
        fixture.drag(offset(start, y: 20))
        fixture.drag(offset(start, y: 44))
        fixture.up(offset(start, y: 63))
        precondition(fixture.clicks == 0 && fixture.reports.map(\.phase) == ["began", "changed", "changed", "ended"],
                     "A vertical drag must emit one terminal phase and never dispatch a click")
        precondition(near(fixture.reports[1].delta, 20) && near(fixture.reports[2].delta, 44)
                     && near(fixture.reports[3].delta, 63) && near(fixture.panel.frame.minY, 363),
                     "Drag delta must stay cumulative in global coordinates as the panel follows the pointer")

        fixture.reset()
        start = fixture.center
        fixture.down(start)
        fixture.drag(offset(start, x: 20))
        fixture.up(offset(start, x: 20))
        precondition(fixture.clicks == 0 && fixture.reports.last?.phase == "ended",
                     "Horizontal movement beyond the threshold must suppress accidental expansion")
        precondition(fixture.reports.allSatisfy { near($0.delta, 0) },
                     "Horizontal dragging must not change vertical position")

        fixture.reset()
        start = fixture.panel.convertPoint(toScreen: fixture.view.convert(
            NSPoint(x: fixture.view.bounds.maxX - 1, y: fixture.view.bounds.midY), to: nil))
        fixture.down(start)
        fixture.up(offset(start, x: 2))
        precondition(fixture.clicks == 0 && fixture.reports.last?.phase == "cancelled",
                     "Mouse-up outside the handle must never dispatch its click action")

        fixture.reset(movesPanel: true)
        start = fixture.center
        fixture.down(start)
        fixture.drag(offset(start, y: -30))
        fixture.view.removeFromSuperview()
        precondition(fixture.reports.last?.phase == "cancelled" && near(fixture.panel.frame.minY, 300),
                     "Detaching a dragging leaf must release locks and restore its initial window position")
        let detachedCount = fixture.reports.count
        fixture.up(offset(start, y: -30))
        fixture.view.removeFromSuperview()
        precondition(fixture.reports.count == detachedCount && fixture.clicks == 0,
                     "Late mouse-up and repeated detach must not emit duplicate cancellation or a click")

        fixture.reset()
        start = fixture.center
        fixture.down(start)
        fixture.drag(offset(start, y: 30))
        fixture.view.isEnabled = false
        precondition(fixture.reports.last?.phase == "cancelled",
                     "Disabling the active native leaf must immediately release its drag locks")
        let disabledCenter = fixture.view.convert(
            NSPoint(x: fixture.view.bounds.midX, y: fixture.view.bounds.midY), to: fixture.root)
        precondition(fixture.view.hitTest(disabledCenter) == nil,
                     "A disabled native leaf must not intercept the invisible handle's clicks")
        let disabledCount = fixture.reports.count
        fixture.up(offset(start, y: 30))
        fixture.down(start)
        precondition(fixture.reports.count == disabledCount && fixture.clicks == 0,
                     "A disabled leaf must ignore late events and new mouse-down")
        fixture.reset()
        start = fixture.center
        fixture.down(start)
        fixture.up(start)
        precondition(fixture.clicks == 1 && fixture.reports.map(\.phase) == ["began", "cancelled"],
                     "A cancelled native leaf must support the next gesture normally")
        precondition(!fixture.panel.isKeyWindow, "Synthetic side interactions must leave the panel nonactivating")

        fixture.reset()
        start = fixture.center
        fixture.down(start)
        fixture.drag(offset(start, y: 30))
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 100,
            windowNumber: fixture.panel.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        fixture.view.keyDown(with: escape)
        let escapedCount = fixture.reports.count
        fixture.up(offset(start, y: 30))
        precondition(fixture.reports.last?.phase == "cancelled" && fixture.reports.count == escapedCount
                     && fixture.clicks == 0, "Escape must cancel once and suppress the pending click")

        var accessibleReports: [(CGFloat, String)] = []
        let host = IslandHostingView(rootView:
            IslandDragTarget(label: "Move sidebar", onDrag: { delta, phase in
                let name: String
                switch phase {
                case .began: name = "began"
                case .changed: name = "changed"
                case .ended: name = "ended"
                case .cancelled: name = "cancelled"
                }
                accessibleReports.append((delta, name))
            })
            .frame(width: 20, height: 96))
        let accessiblePanel = IslandPanel(contentRect: NSRect(x: 0, y: 0, width: 20, height: 96),
                                         styleMask: [.borderless, .nonactivatingPanel],
                                         backing: .buffered, defer: false)
        accessiblePanel.isReleasedWhenClosed = false
        accessiblePanel.contentView = host
        host.layoutSubtreeIfNeeded()
        defer { accessiblePanel.close() }
        func findDrag(in view: NSView) -> IslandDragView? {
            if let drag = view as? IslandDragView { return drag }
            return view.subviews.lazy.compactMap { findDrag(in: $0) }.first
        }
        guard let accessibleDrag = findDrag(in: host) else {
            preconditionFailure("The drag representable must mount its actual native leaf")
        }
        host.islandHitFrame = host.bounds
        let leafCenter = accessibleDrag.convert(
            NSPoint(x: accessibleDrag.bounds.midX, y: accessibleDrag.bounds.midY), to: host.superview)
        precondition(host.hitTest(leafCenter) === accessibleDrag,
                     "The hosted grip must receive the actual native leaf hit")
        precondition(accessibleDrag.accessibilityPerformIncrement(),
                     "A drag-only leaf must support accessible upward movement")
        precondition(accessibleReports.first?.1 == "began" && accessibleReports.last?.1 == "ended"
                     && near(accessibleReports.last!.0, 24),
                     "Accessible movement must use a complete drag transaction with a 24-point delta")
        accessibleReports = []
        precondition(accessibleDrag.accessibilityPerformDecrement(),
                     "A drag-only leaf must support accessible downward movement")
        precondition(accessibleReports.first?.1 == "began" && accessibleReports.last?.1 == "ended"
                     && near(accessibleReports.last!.0, -24),
                     "Accessible downward movement must retain the global vertical sign")
        print("Island drag: first click, threshold, cumulative screen delta, horizontal suppression, cancellation, restart and accessibility transactions passed")
    }
}
