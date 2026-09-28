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
        precondition(!hits(NSPoint(x: 184, y: 640)), "Transparent bottom must not hit")
        host.islandHitFrame = NSRect(x: 14, y: 0, width: 340, height: 112)
        precondition(hits(NSPoint(x: 320, y: 56)), "Expanded details button must hit")
        host.islandHitFrame.size.height = 580
        precondition(hits(NSPoint(x: 184, y: 560)), "Footer buttons must hit")
        precondition(!hits(NSPoint(x: 4, y: 56)), "Transparent side margin must not hit")

        let path = NotchShape(bottomRadius: 24).path(in: CGRect(x: 0, y: 0, width: 340, height: 112))
        precondition(path.contains(CGPoint(x: 2, y: 0.1)), "Shoulder must meet screen top")
        precondition(!path.contains(CGPoint(x: 2, y: 30)), "Shoulder must curve inward")
        precondition(path.contains(CGPoint(x: 170, y: 111)), "Bottom center must be filled")
        precondition(!path.contains(CGPoint(x: 11, y: 111)), "Bottom corners must be rounded")
        print("Island window: coordinate conversion, first click, expanded/footer hit targets and notch geometry passed")
    }
}
