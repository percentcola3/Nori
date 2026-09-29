import AppKit
import SwiftUI

@main
struct IslandWindowTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        let panel = IslandPanel(contentRect: NSRect(x: 0, y: 0, width: 368, height: 650),
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        let host = IslandHostingView(rootView: Color.black.frame(width: 368, height: 650))
        panel.contentView = host
        host.layoutSubtreeIfNeeded()
        precondition(host.isFlipped)
        precondition(panel.canBecomeKey && !panel.canBecomeMain)
        precondition(host.acceptsFirstMouse(for: nil))

        func hits(_ point: NSPoint) -> Bool {
            host.hitTest(host.convert(point, to: host.superview)) != nil
        }
        // Real window has an unflipped frame view, while SwiftUI reports top-left coordinates.
        host.islandHitFrame = NSRect(x: 130, y: 0, width: 108, height: 20)
        precondition(hits(NSPoint(x: 184, y: 10)), "Collapsed handle must receive first click")
        precondition(!hits(NSPoint(x: 129, y: 10)), "Invisible hit slop must not expand the handle")
        precondition(!hits(NSPoint(x: 131, y: 19)), "Transparent rounded corner must not hit")
        precondition(!hits(NSPoint(x: 184, y: 640)), "Transparent bottom must not hit")
        // 刘海屏：表面从物理顶边盖住 32pt 硬件刘海，并向下延出 8pt。
        host.islandHitFrame = NSRect(x: 88, y: 0, width: 193, height: 40)
        host.islandHitShape = NotchShape(bottomRadius: 9, shoulderRadius: 4)
        precondition(hits(NSPoint(x: 184, y: 20)), "Surface covering the hardware notch must hit")
        precondition(hits(NSPoint(x: 184, y: 36)), "Lip below the hardware notch must hit")
        precondition(!hits(NSPoint(x: 93, y: 39.5)), "Notch lip corners must stay rounded")
        host.islandHitShape = NotchShape(bottomRadius: 5, shoulderRadius: 4)
        // Mouse pass-through routing uses screen coordinates (bottom-left origin).
        host.islandHitFrame = NSRect(x: 130, y: 0, width: 108, height: 20)
        let windowTop = panel.frame.maxY
        precondition(host.containsScreenPoint(NSPoint(x: panel.frame.minX + 184, y: windowTop - 10)),
                     "Cursor over the visible island must stop mouse pass-through")
        precondition(!host.containsScreenPoint(NSPoint(x: panel.frame.minX + 184, y: windowTop - 300)),
                     "Transparent window margin must keep passing clicks to windows below")
        host.islandHitFrame = NSRect(x: 14, y: 0, width: 340, height: 112)
        precondition(hits(NSPoint(x: 320, y: 56)), "Expanded details button must hit")
        host.islandHitFrame.size.height = 580
        precondition(hits(NSPoint(x: 184, y: 560)), "Footer buttons must hit")
        precondition(!hits(NSPoint(x: 4, y: 56)), "Transparent side margin must not hit")

        // Test the real leaf control, not just the hosting view's first-mouse
        // override. No panel is shown and no global input events are sent.
        var activations = 0
        var pressed = false
        let actionHost = IslandHostingView(rootView:
            IslandActionTarget(label: "More", onPressChange: { pressed = $0 }) {
                activations += 1
            }
            .frame(width: 46, height: 76)
            .frame(width: 300, height: 76, alignment: .trailing))
        let actionPanel = IslandPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 76),
                                      styleMask: [.borderless, .nonactivatingPanel],
                                      backing: .buffered, defer: false)
        actionPanel.contentView = actionHost
        actionHost.islandHitFrame = actionHost.bounds
        actionHost.layoutSubtreeIfNeeded()
        func findButton(in view: NSView) -> IslandActionButton? {
            if let button = view as? IslandActionButton { return button }
            return view.subviews.lazy.compactMap { findButton(in: $0) }.first
        }
        guard let button = findButton(in: actionHost) else {
            preconditionFailure("More must mount a native action target")
        }
        precondition(button.acceptsFirstMouse(for: nil))
        precondition(!button.needsPanelToBecomeKey, "More must not steal key focus before opening main")
        let buttonCenter = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY),
                                          to: actionHost.superview)
        precondition(actionHost.hitTest(buttonCenter) === button, "More must receive the actual leaf hit")
        button.highlight(true)
        precondition(pressed, "More must provide pressed feedback")
        button.highlight(false)
        precondition(!pressed)
        button.performClick(nil)
        precondition(activations == 1, "A single click must invoke the advanced-panel callback once")
        button.isEnabled = false
        button.performClick(nil)
        precondition(activations == 1, "Collapsed controls must not dispatch actions")

        let path = NotchShape(bottomRadius: 24).path(in: CGRect(x: 0, y: 0, width: 340, height: 112))
        precondition(path.contains(CGPoint(x: 2, y: 0.1)), "Shoulder must meet screen top")
        precondition(!path.contains(CGPoint(x: 2, y: 30)), "Shoulder must curve inward")
        precondition(path.contains(CGPoint(x: 170, y: 111)), "Bottom center must be filled")
        precondition(!path.contains(CGPoint(x: 11, y: 111)), "Bottom corners must be rounded")
        let collapsed = NotchShape(bottomRadius: 5, shoulderRadius: 4)
            .path(in: CGRect(x: 0, y: 0, width: 72, height: 8))
        precondition(collapsed.contains(CGPoint(x: 0.5, y: 0.05)), "Collapsed shoulder must meet the top edge")
        precondition(!collapsed.contains(CGPoint(x: 3, y: 7.5)), "Collapsed bottom must retain visible rounding")
        let notch = NotchShape(bottomRadius: 9, shoulderRadius: 4)
            .path(in: CGRect(x: 0, y: 0, width: 193, height: 40))
        precondition(notch.contains(CGPoint(x: 0.5, y: 0.05)), "Notch shoulder must meet the screen top edge")
        precondition(notch.contains(CGPoint(x: 4.5, y: 20)), "Notch body must cover the hardware notch edge")
        precondition(!notch.contains(CGPoint(x: 5, y: 39.5)), "Notch lip must round its bottom corners")
        print("Island window: coordinates, native More hit/action, first click, pressed feedback and notch geometry passed")
    }
}
