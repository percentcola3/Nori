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

        // A side rail receives only its painted pixels, while the inward detail
        // bubble receives clicks independently of the transparent connecting gap.
        host.islandHitFrame = NSRect(x: 280, y: 64, width: 88, height: 480)
        host.islandHitShape = NotchShape(bottomRadius: 24, shoulderRadius: 10, attachment: .right)
        host.islandDetailHitFrame = NSRect(x: 14, y: 180, width: 254, height: 240)
        precondition(hits(NSPoint(x: 330, y: 300)), "Vertical rail center must receive clicks")
        precondition(!hits(NSPoint(x: 281, y: 65)), "Rail inward corner must pass through")
        precondition(hits(NSPoint(x: 367.9, y: 64.5)), "Right shoulder must meet the physical edge")
        precondition(hits(NSPoint(x: 140, y: 300)), "Detached detail bubble must receive clicks")
        precondition(!hits(NSPoint(x: 15, y: 181)), "Detail bubble rounded corner must pass through")
        precondition(!hits(NSPoint(x: 274, y: 300)), "Gap between rail and detail must pass through")
        let sideCenter = NSPoint(x: panel.frame.minX + 330, y: panel.frame.maxY - 300)
        precondition(host.containsScreenPoint(sideCenter), "Side rail must route screen-space cursor coordinates")
        host.islandDetailHitFrame = nil
        precondition(!hits(NSPoint(x: 140, y: 300)), "Hidden detail bubble must release its hit region")

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

        // Rotate the existing top outline into both physical side attachments.
        // Test nonzero bounds as reported by the hosting view's named space.
        let railRect = CGRect(x: 21, y: 35, width: 88, height: 480)
        let uprightRail = NotchShape(bottomRadius: 24, shoulderRadius: 10)
            .path(in: CGRect(x: 0, y: 0, width: 480, height: 88))
        let leftRail = NotchShape(bottomRadius: 24, shoulderRadius: 10, attachment: .left).path(in: railRect)
        let rightRail = NotchShape(bottomRadius: 24, shoulderRadius: 10, attachment: .right).path(in: railRect)
        for longAxis in stride(from: CGFloat(0.5), to: 480, by: 13) {
            for depth in stride(from: CGFloat(0.5), to: 88, by: 7) {
                let expected = uprightRail.contains(CGPoint(x: longAxis, y: depth))
                precondition(leftRail.contains(CGPoint(x: railRect.minX + depth, y: railRect.minY + longAxis)) == expected,
                             "Left outline must preserve the top outline under rotation")
                precondition(rightRail.contains(CGPoint(x: railRect.maxX - depth, y: railRect.minY + longAxis)) == expected,
                             "Right outline must preserve the top outline under rotation")
            }
        }
        for attachment in [IslandAttachment.left, .right] {
            let handleRect = CGRect(x: 13, y: 29, width: 12, height: 96)
            let handle = NotchShape(bottomRadius: 5, shoulderRadius: 4, attachment: attachment).path(in: handleRect)
            let edgeX = attachment == .left ? handleRect.minX + 0.05 : handleRect.maxX - 0.05
            let inwardX = attachment == .left ? handleRect.maxX - 0.05 : handleRect.minX + 0.05
            precondition(handle.contains(CGPoint(x: edgeX, y: handleRect.minY + 0.5)),
                         "Collapsed side shoulder must attach to the edge")
            precondition(!handle.contains(CGPoint(x: inwardX, y: handleRect.minY + 0.5)),
                         "Collapsed side inward corners must stay rounded")
            precondition(handle.contains(CGPoint(x: handleRect.midX, y: handleRect.midY)),
                         "Collapsed side handle must retain a visible body")
        }

        // NSScreen uses global coordinates, including negative origins for
        // displays left of or below the primary display.
        let screen = NSRect(x: -1920, y: -240, width: 1920, height: 1080)
        let visible = NSRect(x: -1880, y: -190, width: 1880, height: 1005)
        let sideSize = NSSize(width: 458, height: 508)
        let leftOrigin = IslandWindowGeometry.origin(size: sideSize, screenFrame: screen,
                                                     visibleFrame: visible, attachment: .left)
        let rightOrigin = IslandWindowGeometry.origin(size: sideSize, screenFrame: screen,
                                                      visibleFrame: visible, attachment: .right)
        precondition(leftOrigin.x == screen.minX, "Left window must touch the physical screen edge, even beside a Dock")
        precondition(rightOrigin.x + sideSize.width == screen.maxX, "Right window must touch the physical screen edge")
        precondition(leftOrigin.y + sideSize.height / 2 == visible.midY,
                     "Side window must vertically center in the available screen area")
        precondition(leftOrigin.y == rightOrigin.y, "Both side positions must share vertical centering")
        let topSize = NSSize(width: 368, height: 650)
        let topOrigin = IslandWindowGeometry.origin(size: topSize, screenFrame: screen,
                                                    visibleFrame: visible, attachment: .top)
        precondition(topOrigin.x + topSize.width / 2 == screen.midX, "Top must remain horizontally centered")
        precondition(topOrigin.y + topSize.height == screen.maxY, "Top must keep its existing physical-top attachment")

        let verticalRange = IslandWindowGeometry.sideVerticalRange(windowHeight: sideSize.height, visibleFrame: visible)
        precondition(verticalRange.lowerBound == visible.minY + 8, "Lower drag boundary must clear the usable screen edge")
        precondition(verticalRange.upperBound + sideSize.height == visible.maxY - 8,
                     "Upper drag boundary must keep the whole expanded window visible")
        for attachment in [IslandAttachment.left, .right] {
            let low = IslandWindowGeometry.origin(size: sideSize, screenFrame: screen, visibleFrame: visible,
                                                   attachment: attachment, positionFraction: 0)
            let high = IslandWindowGeometry.origin(size: sideSize, screenFrame: screen, visibleFrame: visible,
                                                    attachment: attachment, positionFraction: 1)
            precondition(low.y == verticalRange.lowerBound && high.y == verticalRange.upperBound,
                         "Persisted side fractions must span exactly the safe drag range")
            precondition(low.x == high.x, "Changing vertical position must not move the rail off its physical edge")
            for (fraction, expectedY) in [(-3.0, low.y), (4.0, high.y), (Double.nan, leftOrigin.y),
                                          (Double.infinity, leftOrigin.y), (-Double.infinity, leftOrigin.y)] {
                let restored = IslandWindowGeometry.origin(size: sideSize, screenFrame: screen, visibleFrame: visible,
                                                            attachment: attachment, positionFraction: fraction)
                precondition(restored.y == expectedY, "Invalid stored fractions must be clamped or default to the center")
            }
        }
        let firstDrag = IslandWindowGeometry.draggedSideOrigin(initialOrigin: leftOrigin, screenYDelta: 100,
                                                               windowHeight: sideSize.height, visibleFrame: visible)
        let secondDrag = IslandWindowGeometry.draggedSideOrigin(initialOrigin: leftOrigin, screenYDelta: 200,
                                                                windowHeight: sideSize.height, visibleFrame: visible)
        precondition(firstDrag.y == leftOrigin.y + 100 && secondDrag.y == leftOrigin.y + 200,
                     "Drag deltas must remain cumulative from the original screen point")
        precondition(secondDrag.x == leftOrigin.x, "Dragging must only change vertical position")
        for (delta, expectedY) in [(CGFloat(10_000), verticalRange.upperBound),
                                  (CGFloat(-10_000), verticalRange.lowerBound),
                                  (CGFloat.nan, leftOrigin.y), (CGFloat.infinity, leftOrigin.y),
                                  (-CGFloat.infinity, leftOrigin.y)] {
            let dragged = IslandWindowGeometry.draggedSideOrigin(initialOrigin: leftOrigin, screenYDelta: delta,
                                                                  windowHeight: sideSize.height, visibleFrame: visible)
            precondition(dragged.y == expectedY, "Dragging must clamp at boundaries and ignore nonfinite deltas")
        }
        let savedFraction = IslandWindowGeometry.sidePositionFraction(originY: secondDrag.y,
                                                                       windowHeight: sideSize.height, visibleFrame: visible)
        let restored = IslandWindowGeometry.origin(size: sideSize, screenFrame: screen, visibleFrame: visible,
                                                    attachment: .left, positionFraction: savedFraction)
        precondition(abs(restored.y - secondDrag.y) < 0.000001, "A saved drag position must round-trip without drift")
        let resizedScreen = NSRect(x: 1920, y: -800, width: 2560, height: 1440)
        let resizedVisible = NSRect(x: 1920, y: -752, width: 2560, height: 1363)
        let resizedOrigin = IslandWindowGeometry.origin(size: sideSize, screenFrame: resizedScreen, visibleFrame: resizedVisible,
                                                         attachment: .right, positionFraction: savedFraction)
        let resizedFraction = IslandWindowGeometry.sidePositionFraction(originY: resizedOrigin.y,
                                                                         windowHeight: sideSize.height, visibleFrame: resizedVisible)
        precondition(abs(resizedFraction - savedFraction) < 0.000001,
                     "Normalized position must remain stable across display resolutions and global origins")
        precondition(resizedOrigin.x + sideSize.width == resizedScreen.maxX,
                     "Resolution changes must preserve physical right-edge anchoring")
        for badY in [CGFloat.nan, .infinity, -.infinity] {
            precondition(IslandWindowGeometry.sidePositionFraction(originY: badY, windowHeight: sideSize.height,
                                                                    visibleFrame: visible) == 0.5,
                         "Invalid live coordinates must never persist a nonfinite position")
        }
        let shortVisible = NSRect(x: -800, y: -200, width: 800, height: 400)
        let shortRange = IslandWindowGeometry.sideVerticalRange(windowHeight: sideSize.height, visibleFrame: shortVisible)
        precondition(shortRange.lowerBound == shortRange.upperBound,
                     "Screens shorter than the fixed expanded window must have no unsafe drag range")
        precondition(shortRange.lowerBound + sideSize.height / 2 == shortVisible.midY,
                     "An oversized sidebar must remain centered on a short screen")
        for fraction in [0.0, 0.5, 1.0] {
            precondition(IslandWindowGeometry.sideOriginY(windowHeight: sideSize.height, visibleFrame: shortVisible,
                                                          positionFraction: fraction) == shortRange.lowerBound,
                         "A short screen cannot restore an offscreen vertical offset")
        }
        precondition(IslandWindowGeometry.origin(size: topSize, screenFrame: screen, visibleFrame: visible,
                                                 attachment: .top, positionFraction: 1) == topOrigin,
                     "Side position preferences must not change the top notch location")
        print("Island window: draggable side bounds and restoration, hit routing, native actions and first-click behavior passed")
    }
}
