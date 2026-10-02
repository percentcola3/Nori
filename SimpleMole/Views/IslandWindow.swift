import AppKit
import SwiftUI

/// Physical screen edge. Left and right are intentionally independent of RTL layout.
enum IslandAttachment {
    case top, left, right
}

enum IslandWindowGeometry {
    static let sideScreenMargin: CGFloat = 8

    static func origin(size: NSSize, screenFrame: NSRect, visibleFrame: NSRect,
                       attachment: IslandAttachment, positionFraction: Double = 0.5) -> NSPoint {
        switch attachment {
        case .top:
            return NSPoint(x: screenFrame.midX - size.width / 2,
                           y: screenFrame.maxY - size.height)
        case .left:
            return NSPoint(x: screenFrame.minX,
                           y: sideOriginY(windowHeight: size.height, visibleFrame: visibleFrame,
                                          positionFraction: positionFraction))
        case .right:
            return NSPoint(x: screenFrame.maxX - size.width,
                           y: sideOriginY(windowHeight: size.height, visibleFrame: visibleFrame,
                                          positionFraction: positionFraction))
        }
    }

    static func sideVerticalRange(windowHeight: CGFloat, visibleFrame: NSRect) -> ClosedRange<CGFloat> {
        let lower = visibleFrame.minY + sideScreenMargin
        let upper = visibleFrame.maxY - sideScreenMargin - windowHeight
        guard upper > lower else {
            let centered = visibleFrame.midY - windowHeight / 2
            return centered...centered
        }
        return lower...upper
    }

    static func sideOriginY(windowHeight: CGFloat, visibleFrame: NSRect,
                            positionFraction: Double) -> CGFloat {
        let range = sideVerticalRange(windowHeight: windowHeight, visibleFrame: visibleFrame)
        let fraction = positionFraction.isFinite ? min(1, max(0, positionFraction)) : 0.5
        return range.lowerBound + CGFloat(fraction) * (range.upperBound - range.lowerBound)
    }

    static func draggedSideOrigin(initialOrigin: NSPoint, screenYDelta: CGFloat,
                                   windowHeight: CGFloat, visibleFrame: NSRect) -> NSPoint {
        let range = sideVerticalRange(windowHeight: windowHeight, visibleFrame: visibleFrame)
        let delta = screenYDelta.isFinite ? screenYDelta : 0
        let y = initialOrigin.y + delta
        let clampedY = y.isNaN ? (range.lowerBound + range.upperBound) / 2
                              : min(range.upperBound, max(range.lowerBound, y))
        return NSPoint(x: initialOrigin.x, y: clampedY)
    }

    static func sidePositionFraction(originY: CGFloat, windowHeight: CGFloat,
                                      visibleFrame: NSRect) -> Double {
        let range = sideVerticalRange(windowHeight: windowHeight, visibleFrame: visibleFrame)
        let span = range.upperBound - range.lowerBound
        guard span > 0, originY.isFinite else { return 0.5 }
        return Double(min(1, max(0, (originY - range.lowerBound) / span)))
    }
}

/// 外翻肩角连接物理屏幕边缘，内侧收圆；侧边栏复用同一条轮廓。
struct NotchShape: Shape {
    var bottomRadius: CGFloat
    var shoulderRadius: CGFloat = 10
    var attachment: IslandAttachment = .top
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(bottomRadius, shoulderRadius) }
        set { bottomRadius = newValue.first; shoulderRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        guard rect.width > 0, rect.height > 0 else { return Path() }
        if attachment == .top { return topPath(in: rect) }
        let upright = topPath(in: CGRect(x: 0, y: 0, width: rect.height, height: rect.width))
        switch attachment {
        case .left:
            return upright.applying(CGAffineTransform(a: 0, b: 1, c: 1, d: 0,
                                                       tx: rect.minX, ty: rect.minY))
        case .right:
            return upright.applying(CGAffineTransform(a: 0, b: 1, c: -1, d: 0,
                                                       tx: rect.maxX, ty: rect.minY))
        case .top:
            return upright
        }
    }

    private func topPath(in rect: CGRect) -> Path {
        let shoulder = max(0, min(shoulderRadius, rect.height / 3))
        let radius = max(0, min(bottomRadius, rect.height - shoulder, (rect.width - 2 * shoulder) / 2))
        let left = rect.minX + shoulder
        let right = rect.maxX - shoulder
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: left, y: rect.minY + shoulder),
                          control: CGPoint(x: left, y: rect.minY))
        path.addLine(to: CGPoint(x: left, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: left + radius, y: rect.maxY),
                          control: CGPoint(x: left, y: rect.maxY))
        path.addLine(to: CGPoint(x: right - radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: right, y: rect.maxY - radius),
                          control: CGPoint(x: right, y: rect.maxY))
        path.addLine(to: CGPoint(x: right, y: rect.minY + shoulder))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                          control: CGPoint(x: right, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class IslandHostingView<Content: View>: NSHostingView<Content> {
    var islandHitFrame: CGRect = .zero
    var islandHitShape = NotchShape(bottomRadius: 5, shoulderRadius: 4)
    var islandDetailHitFrame: CGRect?

    override func hitTest(_ point: NSPoint) -> NSView? {
        // hitTest 参数属于父视图坐标；SwiftUI 几何区域属于本地翻转坐标。
        guard islandContains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }

    /// 光标（屏幕坐标）是否落在灵动岛可见形状内；窗口据此切换鼠标穿透。
    func containsScreenPoint(_ screenPoint: NSPoint) -> Bool {
        guard let window else { return false }
        return islandContains(convert(window.convertPoint(fromScreen: screenPoint), from: nil))
    }

    func cancelIslandDragTracking() {
        func cancel(in view: NSView) {
            (view as? IslandDragView)?.cancelTracking()
            for child in view.subviews { cancel(in: child) }
        }
        cancel(in: self)
    }

    private func islandContains(_ localPoint: NSPoint) -> Bool {
        if islandHitFrame.contains(localPoint), islandHitShape.path(in: islandHitFrame).contains(localPoint) {
            return true
        }
        guard let detailFrame = islandDetailHitFrame, detailFrame.contains(localPoint) else { return false }
        return RoundedRectangle(cornerRadius: 20, style: .continuous)
            .path(in: detailFrame).contains(localPoint)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Use an AppKit target/action at the actual leaf hit target. First-mouse
/// acceptance on NSHostingView alone does not cover hosted SwiftUI controls.
struct IslandActionTarget: NSViewRepresentable {
    let label: String
    var isEnabled = true
    var onPressChange: (Bool) -> Void = { _ in }
    let action: () -> Void

    func makeNSView(context: Context) -> IslandActionButton {
        IslandActionButton()
    }

    func updateNSView(_ button: IslandActionButton, context: Context) {
        button.setAccessibilityLabel(label)
        button.toolTip = label
        button.isEnabled = isEnabled
        button.onPressChange = onPressChange
        button.onActivate = action
    }
}

final class IslandActionButton: NSButton {
    var onActivate: () -> Void = {}
    var onPressChange: (Bool) -> Void = { _ in }

    init() {
        super.init(frame: .zero)
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        target = self
        action = #selector(activate)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? {
        isEnabled ? super.hitTest(point) : nil
    }
    // SwiftUI draws the label; this native button owns click, drag cancellation,
    // keyboard/accessibility activation and the inactive-window first click.
    override func draw(_ dirtyRect: NSRect) {}
    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        onPressChange(flag)
    }

    @objc private func activate() { onActivate() }
}

enum IslandDragPhase: Equatable {
    case began, changed, ended, cancelled
}

/// A dedicated native leaf keeps dragging separate from metric button actions,
/// and tracks global points as its nonactivating window moves underneath it.
struct IslandDragTarget: NSViewRepresentable {
    let label: String
    var positionFraction: Double = 0.5
    var isEnabled = true
    var onClick: (() -> Void)? = nil
    let onDrag: (CGFloat, IslandDragPhase) -> Void

    func makeNSView(context: Context) -> IslandDragView { IslandDragView() }

    func updateNSView(_ view: IslandDragView, context: Context) {
        view.onClick = onClick
        view.onDrag = onDrag
        view.positionFraction = positionFraction
        view.isEnabled = isEnabled
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(onClick == nil ? .slider : .button)
        view.setAccessibilityLabel(label)
        view.setAccessibilityOrientation(.vertical)
        view.setAccessibilityMinValue(0)
        view.setAccessibilityMaxValue(1)
        view.toolTip = label
    }
}

final class IslandDragView: NSView {
    var onClick: (() -> Void)?
    var onDrag: (CGFloat, IslandDragPhase) -> Void = { _, _ in }
    var positionFraction: Double = 0.5
    var isEnabled = true {
        didSet {
            if !isEnabled { cancelTracking() }
            window?.invalidateCursorRects(for: self)
        }
    }
    private var startingPoint: NSPoint?
    private var didDrag = false
    private let dragThreshold: CGFloat = 4

    override var acceptsFirstResponder: Bool { isEnabled }
    override var needsPanelToBecomeKey: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isEnabled ? super.hitTest(point) : nil
    }

    override func resetCursorRects() {
        if isEnabled { addCursorRect(bounds, cursor: .openHand) }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { cancelTracking() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let point = screenPoint(for: event) else { return }
        cancelTracking()
        startingPoint = point
        didDrag = false
        onDrag(0, .began)
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = startingPoint else { return }
        guard isEnabled, let point = screenPoint(for: event) else {
            cancelTracking()
            return
        }
        let delta = NSPoint(x: point.x - start.x, y: point.y - start.y)
        if didDrag || hypot(delta.x, delta.y) >= dragThreshold {
            didDrag = true
            onDrag(delta.y, .changed)
            NSCursor.closedHand.set()
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = startingPoint else { return }
        guard isEnabled, let point = screenPoint(for: event) else {
            cancelTracking()
            return
        }
        let delta = NSPoint(x: point.x - start.x, y: point.y - start.y)
        let dragged = didDrag || hypot(delta.x, delta.y) >= dragThreshold
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        startingPoint = nil
        didDrag = false
        (inside ? NSCursor.openHand : NSCursor.arrow).set()
        if dragged {
            onDrag(delta.y, .ended)
        } else {
            onDrag(0, .cancelled)
            if inside { onClick?() }
        }
    }

    func cancelTracking() {
        guard startingPoint != nil else { return }
        startingPoint = nil
        didDrag = false
        NSCursor.arrow.set()
        onDrag(0, .cancelled)
    }

    private func screenPoint(for event: NSEvent) -> NSPoint? {
        guard let window else { return nil }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        return point.x.isFinite && point.y.isFinite ? point : nil
    }

    override func accessibilityValue() -> Any? { NSNumber(value: positionFraction) }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled, let onClick else { return false }
        onClick()
        return true
    }
    override func accessibilityPerformIncrement() -> Bool { moveByKeyboard(24) }
    override func accessibilityPerformDecrement() -> Bool { moveByKeyboard(-24) }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 126 where onClick == nil: _ = moveByKeyboard(24)
        case 125 where onClick == nil: _ = moveByKeyboard(-24)
        case 53: cancelTracking()
        case 36, 49:
            if !accessibilityPerformPress() { super.keyDown(with: event) }
        default: super.keyDown(with: event)
        }
    }

    private func moveByKeyboard(_ delta: CGFloat) -> Bool {
        guard isEnabled, onClick == nil else { return false }
        cancelTracking()
        onDrag(0, .began)
        onDrag(delta, .ended)
        return true
    }
}
