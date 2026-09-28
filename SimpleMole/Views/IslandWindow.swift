import AppKit
import SwiftUI

/// 顶部外翻肩角与屏幕边缘相接，底部向内收圆。
struct NotchShape: Shape {
    var bottomRadius: CGFloat
    var shoulderRadius: CGFloat = 10
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(bottomRadius, shoulderRadius) }
        set { bottomRadius = newValue.first; shoulderRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let shoulder = min(shoulderRadius, rect.height / 3)
        let radius = min(bottomRadius, rect.height - shoulder, (rect.width - 2 * shoulder) / 2)
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

    override func hitTest(_ point: NSPoint) -> NSView? {
        // hitTest 参数属于父视图坐标；SwiftUI 几何区域属于本地翻转坐标。
        let localPoint = convert(point, from: superview)
        guard islandHitFrame.contains(localPoint),
              islandHitShape.path(in: islandHitFrame).contains(localPoint) else { return nil }
        return super.hitTest(point)
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
