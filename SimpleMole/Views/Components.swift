import SwiftUI
import AppKit

// 设计 token 与玻璃背景见 Views/Theme.swift。

struct HeaderBrandIconView: View {
    var size: CGFloat
    var isSearching = false
    var searchSucceeded = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var winkOpen: CGFloat = 1
    @State private var gazeX: CGFloat = 0
    @State private var gazeY: CGFloat = 0
    @State private var rotation: Double = 0
    @State private var scale: CGFloat = 1
    @State private var isHovered = false
    @State private var wasSearching = false
    @State private var celebrationID = 0
    @State private var confettiProgress: CGFloat = 0

    private var animationContext: MascotAnimationContext {
        MascotAnimationContext(reduceMotion: reduceMotion,
                                isSearching: isSearching,
                                isHovered: isHovered)
    }

    var body: some View {
        ZStack {
            MoleLogoMark(winkOpen: winkOpen, gazeX: gazeX, gazeY: gazeY)
                .rotationEffect(.degrees(rotation))
                .scaleEffect(scale)

            if isSearching {
                SearchMagnifier(size: size, animated: !reduceMotion)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }

            if confettiProgress > 0.001 {
                ConfettiBurst(progress: confettiProgress)
                    .frame(width: size * 2.2, height: size * 2.2)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            guard !reduceMotion, !isSearching else {
                resetGaze()
                return
            }
            switch phase {
            case let .active(location):
                isHovered = true
                let x = min(1, max(-1, ((location.x / size) - 0.5) * 2))
                let y = min(1, max(-1, ((location.y / size) - 0.5) * 2))
                withAnimation(.spring(response: 0.22, dampingFraction: 0.78)) {
                    gazeX = x
                    gazeY = y
                }
            case .ended:
                isHovered = false
                resetGaze()
            }
        }
        .onAppear { wasSearching = isSearching }
        .onChange(of: isSearching) { active in
            if wasSearching, !active, searchSucceeded, !reduceMotion {
                celebrationID += 1
            }
            wasSearching = active
        }
        .task(id: animationContext) {
            guard !reduceMotion, !isSearching, !isHovered else {
                resetMascot()
                return
            }
            while !Task.isCancelled {
                let pause = UInt64.random(in: 3_200_000_000...5_200_000_000)
                guard await wait(pause) else { return }
                switch Int.random(in: 0..<10) {
                case 0...5:
                    guard await wink() else { return }
                case 6...8:
                    guard await glanceAround() else { return }
                default:
                    guard await performSpin() else { return }
                }
            }
        }
        .task(id: celebrationID) {
            guard celebrationID > 0, !reduceMotion else { return }
            confettiProgress = 0.001
            withAnimation(.easeOut(duration: 0.82)) { confettiProgress = 1 }
            guard await wait(900_000_000) else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { confettiProgress = 0 }
        }
        .animation(reduceMotion ? nil : MoleMotion.control, value: isSearching)
        .accessibilityHidden(true)
    }

    @MainActor
    private func wink() async -> Bool {
        withAnimation(.easeIn(duration: 0.075)) { winkOpen = 0.08 }
        guard await wait(95_000_000) else { return false }
        withAnimation(.spring(response: 0.24, dampingFraction: 0.72)) { winkOpen = 1 }
        return true
    }

    @MainActor
    private func glanceAround() async -> Bool {
        let direction: CGFloat = Bool.random() ? 0.82 : -0.82
        withAnimation(.spring(response: 0.30, dampingFraction: 0.72)) {
            gazeX = direction
            gazeY = 0.18
            rotation = Double(direction) * 2.2
        }
        guard await wait(620_000_000) else { return false }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.76)) {
            gazeX = -direction * 0.32
            gazeY = -0.08
            rotation = 0
        }
        guard await wait(260_000_000) else { return false }
        resetGaze()
        return true
    }

    @MainActor
    private func performSpin() async -> Bool {
        withAnimation(.easeInOut(duration: 0.62)) {
            rotation += 360
            scale = 1.07
        }
        guard await wait(650_000_000) else { return false }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { rotation = 0 }
        withAnimation(.spring(response: 0.24, dampingFraction: 0.74)) { scale = 1 }
        return true
    }

    @MainActor
    private func resetGaze() {
        withAnimation(reduceMotion ? nil : .spring(response: 0.30, dampingFraction: 0.78)) {
            gazeX = 0
            gazeY = 0
        }
    }

    @MainActor
    private func resetMascot() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            winkOpen = 1
            gazeX = 0
            gazeY = 0
            rotation = 0
            scale = 1
        }
    }

    private func wait(_ nanoseconds: UInt64) async -> Bool {
        do {
            try await Task.sleep(nanoseconds: nanoseconds)
            return !Task.isCancelled
        } catch {
            return false
        }
    }
}

private struct MascotAnimationContext: Hashable {
    let reduceMotion: Bool
    let isSearching: Bool
    let isHovered: Bool
}

/// 直接复用品牌头像以保留圆润轮廓；Canvas 只重绘眼睛，不近似重画整张 Logo。
private struct MoleLogoMark: View, Animatable {
    var winkOpen: CGFloat
    var gazeX: CGFloat
    var gazeY: CGFloat

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(winkOpen, AnimatablePair(gazeX, gazeY)) }
        set {
            winkOpen = newValue.first
            gazeX = newValue.second.first
            gazeY = newValue.second.second
        }
    }

    private static let artwork: NSImage = {
        guard let url = Bundle.main.url(forResource: "HeaderBrandIcon", withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            return NSImage(size: NSSize(width: 256, height: 256))
        }
        return image
    }()

    var body: some View {
        ZStack {
            Image(nsImage: Self.artwork)
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .aspectRatio(contentMode: .fit)

            Canvas { context, size in
                let closedAmount = 1 - winkOpen
                let isLooking = abs(gazeX) + abs(gazeY) > 0.001
                guard closedAmount > 0.001 || isLooking else { return }

                let w = size.width
                let h = size.height
                let face = Color(red: 0.975, green: 0.970, blue: 0.945)
                let ink = Color(red: 0.065, green: 0.085, blue: 0.105)

                if isLooking {
                    let leftCover = RoundedRectangle(cornerRadius: w * 0.05).path(in:
                        CGRect(x: w * 0.292, y: h * 0.522,
                               width: w * 0.125, height: h * 0.188)
                    )
                    let rightCover = RoundedRectangle(cornerRadius: w * 0.05).path(in:
                        CGRect(x: w * 0.550, y: h * 0.558,
                               width: w * 0.130, height: h * 0.188)
                    )
                    context.fill(leftCover, with: .color(face))
                    context.fill(rightCover, with: .color(face))

                    let eyeShift = CGSize(width: gazeX * w * 0.013,
                                          height: gazeY * h * 0.012)
                    context.drawLayer { eye in
                        eye.translateBy(x: w * 0.350 + eyeShift.width,
                                        y: h * 0.612 + eyeShift.height)
                        eye.rotate(by: .degrees(14))
                        eye.fill(Ellipse().path(in: CGRect(x: -w * 0.041, y: -h * 0.067,
                                                          width: w * 0.082, height: h * 0.134)),
                                 with: .color(ink))
                    }
                    context.drawLayer { eye in
                        eye.translateBy(x: w * 0.617 + eyeShift.width,
                                        y: h * 0.646 + eyeShift.height)
                        eye.rotate(by: .degrees(14))
                        eye.fill(Ellipse().path(in: CGRect(x: -w * 0.041, y: -h * 0.067,
                                                          width: w * 0.082, height: h * 0.134)),
                                 with: .color(ink))
                    }
                }

                // 仅在眨眼时盖住底图左眼，避免重绘整张品牌头像。
                if closedAmount > 0.001 {
                    let eyeCover = RoundedRectangle(cornerRadius: w * 0.045).path(in:
                        CGRect(x: w * 0.275, y: h * 0.515,
                               width: w * 0.155, height: h * 0.190)
                    )
                    context.fill(eyeCover, with: .color(face.opacity(closedAmount)))

                    var eyelid = Path()
                    eyelid.move(to: CGPoint(x: w * 0.305, y: h * 0.625))
                    eyelid.addCurve(to: CGPoint(x: w * 0.398, y: h * 0.605),
                                    control1: CGPoint(x: w * 0.335, y: h * 0.642),
                                    control2: CGPoint(x: w * 0.375, y: h * 0.632))
                    context.stroke(eyelid, with: .color(ink.opacity(closedAmount)),
                                   style: StrokeStyle(lineWidth: max(0.72, w * 0.042),
                                                      lineCap: .round))
                }
            }
        }
    }
}

private struct SearchMagnifier: View {
    let size: CGFloat
    let animated: Bool

    var body: some View {
        if animated {
            TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { context in
                magnifier(at: context.date.timeIntervalSinceReferenceDate)
            }
        } else {
            magnifier(at: 0)
        }
    }

    private func magnifier(at time: TimeInterval) -> some View {
        let travel = animated ? CGFloat(sin(time * 4.2)) : 0
        let bob = animated ? CGFloat(cos(time * 8.4)) : 0
        return ZStack {
            Circle()
                .fill(Color.cyan.opacity(0.18))
                .overlay(Circle().strokeBorder(Color.moleAccentText,
                                               lineWidth: max(1, size * 0.065)))
                .frame(width: size * 0.38, height: size * 0.38)
            Capsule()
                .fill(Color.moleAccentText)
                .frame(width: max(1.2, size * 0.075), height: size * 0.28)
                .rotationEffect(.degrees(-43))
                .offset(x: size * 0.16, y: size * 0.16)
        }
        .shadow(color: .black.opacity(0.38), radius: 1, y: 0.5)
        .rotationEffect(.degrees(-7 + Double(travel) * 7))
        .offset(x: size * (0.23 + travel * 0.07),
                y: size * (0.22 + bob * 0.025))
    }
}

private struct ConfettiBurst: View, Animatable {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let colors: [Color] = [.moleAccentText, .orange, .cyan, .pink]
            let fade = max(0, sin(Double(progress) * .pi))

            for index in 0..<8 {
                let angle = Double(index) * (.pi * 2 / 8) - .pi / 2
                let distance = size.width * (0.12 + progress * 0.36)
                let point = CGPoint(x: center.x + CGFloat(cos(angle)) * distance,
                                    y: center.y + CGFloat(sin(angle)) * distance
                                        + progress * progress * size.height * 0.08)
                let particle = RoundedRectangle(cornerRadius: 0.7).path(in:
                    CGRect(x: point.x - 1, y: point.y - 1.8, width: 2, height: 3.6)
                )
                var transform = CGAffineTransform(translationX: -point.x, y: -point.y)
                transform = transform.rotated(by: CGFloat(angle) + progress * 2.4)
                transform = transform.translatedBy(x: point.x, y: point.y)
                context.fill(particle.applying(transform),
                             with: .color(colors[index % colors.count].opacity(fade)))
            }
        }
    }
}

enum MoleMotion {
    /// 普通控件的短促按压节奏。只用于瞬时交互反馈，不用于面板或内容切换。
    static let press = Animation.easeOut(duration: 0.11)
    /// 选择态切换比面板展开更快，避免列表连续操作时产生拖沓感。
    static let selection = Animation.spring(response: 0.28, dampingFraction: 0.84,
                                             blendDuration: 0.06)
    static let control = Animation.spring(response: 0.36, dampingFraction: 0.76,
                                          blendDuration: 0.10)
    static let panel = Animation.spring(response: 0.44, dampingFraction: 0.82,
                                        blendDuration: 0.12)
}

extension AnyTransition {
    static var molePanelReveal: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .move(edge: .top)),
                    removal: .opacity.combined(with: .move(edge: .top)))
    }

    static var moleFloatingPanel: AnyTransition {
        .modifier(active: MoleFloatingPanelMotion(scale: 0.92, x: 9, y: -10, opacity: 0),
                  identity: MoleFloatingPanelMotion(scale: 1, x: 0, y: 0, opacity: 1))
    }
}

private struct MoleFloatingPanelMotion: ViewModifier {
    let scale: CGFloat
    let x: CGFloat
    let y: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale, anchor: .topTrailing)
            .offset(x: x, y: y)
            .opacity(opacity)
    }
}

/// 与胶囊导航相同的轻量弹性节奏；不依赖 AppKit switch，因此开关滑块、
/// 轨道颜色和阴影可以在所有受支持的 macOS 版本上同步插值。
struct MoleSwitchToggleStyle: ToggleStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    func makeBody(configuration: Configuration) -> some View {
        Button {
            if reduceMotion {
                configuration.isOn.toggle()
            } else {
                withAnimation(MoleMotion.control) { configuration.isOn.toggle() }
            }
        } label: {
            HStack(spacing: 8) {
                configuration.label
                switchTrack(isOn: configuration.isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.48)
        .disabled(!isEnabled)
    }

    private func switchTrack(isOn: Bool) -> some View {
        let size = metrics
        let thumb = size.height - 4
        let travel = size.width - size.height
        return Capsule()
            .fill(isOn ? Color.moleAccent.opacity(0.82) : Color.trackOff)
            .frame(width: size.width, height: size.height)
            .overlay(alignment: .leading) {
                Circle()
                    .fill(isOn ? Color.moleOnAccent : Color.thumbOff)
                    .frame(width: thumb, height: thumb)
                    .shadow(color: isOn ? Color.moleAccent.opacity(0.30) : .black.opacity(0.24),
                            radius: isOn ? 4 : 2, y: 1)
                    .padding(2)
                    .offset(x: isOn ? travel : 0)
            }
            .overlay(Capsule().strokeBorder(Color.hairline, lineWidth: 1))
            .animation(reduceMotion ? nil : MoleMotion.control, value: isOn)
    }

    private var metrics: (width: CGFloat, height: CGFloat) {
        switch controlSize {
        case .mini: return (28, 16)
        case .small: return (32, 18)
        default: return (36, 20)
        }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isEnabled ? Color.moleOnAccent : Color.secondary)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(
                Capsule()
                    .fill(isEnabled
                          ? Color.moleAccent.opacity(configuration.isPressed ? 0.55 : 0.72)
                          : Color.surface2)
                    .shadow(color: isEnabled
                            ? Color.moleAccent.opacity(configuration.isPressed ? 0.10 : 0.18)
                            : .clear,
                            radius: configuration.isPressed ? 2 : 5, y: 1)
            )
            .overlay(Capsule().strokeBorder(isEnabled
                                           ? Color.moleAccentText.opacity(0.22)
                                           : Color.hairline, lineWidth: 1))
            .modifier(MoleButtonFeedbackModifier(isPressed: configuration.isPressed))
    }
}

/// 快捷面板主动作使用独立的品牌黄到金色渐变，并保留明确的按压反馈。
/// 不要复用于删除、卸载等高风险确认动作。
struct QuickActionButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.moleOnAccent.opacity(configuration.isPressed ? 0.86 : 1))
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background {
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.moleAccent.opacity(configuration.isPressed ? 0.84 : 1),
                                Color(red: 0.91, green: 0.66, blue: 0.04)
                                    .opacity(configuration.isPressed ? 0.82 : 1),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .shadow(
                        color: Color.moleAccent.opacity(configuration.isPressed ? 0.10 : 0.25),
                        radius: configuration.isPressed ? 2 : 7,
                        y: configuration.isPressed ? 1 : 3
                    )
            }
            .overlay {
                Capsule()
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.58), Color.moleAccentText.opacity(0.30)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            }
            .scaleEffect(reduceMotion || !configuration.isPressed ? 1 : 0.982)
            .offset(y: reduceMotion || !configuration.isPressed ? 0 : 1)
            .animation(reduceMotion ? nil : MoleMotion.press,
                       value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var tint: Color?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(tint ?? .primary)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Capsule().fill(.quinary.opacity(configuration.isPressed ? 0.7 : 1)))
            .overlay(Capsule().strokeBorder(.separator.opacity(0.6), lineWidth: 1))
            .modifier(MoleButtonFeedbackModifier(isPressed: configuration.isPressed))
    }
}

struct DangerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.red)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(.red.opacity(configuration.isPressed ? 0.10 : 0.06)))
            .overlay(Capsule().strokeBorder(.red.opacity(0.35), lineWidth: 1))
            .modifier(MoleButtonFeedbackModifier(isPressed: configuration.isPressed))
    }
}

/// 无额外表面的文字/内容按钮，只补齐原生按压反馈。
/// 适合列表标题等已有父级卡片背景的入口，避免再叠一层胶囊或圆角底色。
struct MolePlainButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.98

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(MoleButtonFeedbackModifier(
                isPressed: configuration.isPressed,
                pressedScale: pressedScale))
    }
}

/// 小型图标按钮：保持固定命中尺寸，仅提供轻量悬停和按压反馈。
/// `isActive` 适用于展开、筛选等持续状态，不承担危险操作的语义着色。
struct MoleIconButtonStyle: ButtonStyle {
    var isActive = false
    var tint: Color? = nil
    var size: CGFloat = 26

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint ?? (isActive ? Color.moleAccentText : Color.secondary))
            .frame(width: size, height: size)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(backgroundColor(isPressed: configuration.isPressed))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(isActive
                                  ? Color.moleAccentText.opacity(0.24)
                                  : Color.surface2,
                                  lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .opacity(isEnabled ? 1 : 0.45)
            .modifier(MoleButtonFeedbackModifier(isPressed: configuration.isPressed))
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if isActive {
            return Color.moleAccent.opacity(isPressed ? 0.22 : 0.15)
        }
        return isPressed ? Color.surface3 : Color.surface2
    }
}

/// 可选择列表行的统一交互表面。固定 padding 和描边，选择与按压不会改变布局。
struct MoleSelectableRowButtonStyle: ButtonStyle {
    let isSelected: Bool
    var cornerRadius: CGFloat = 8
    var horizontalPadding: CGFloat = 12
    var verticalPadding: CGFloat = 6

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(backgroundColor(isPressed: configuration.isPressed))
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(isSelected
                                  ? AnyShapeStyle(Color.moleAccentText.opacity(0.34))
                                  : AnyShapeStyle(.separator.opacity(0.30)),
                                  lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .opacity(isEnabled ? 1 : 0.45)
            .modifier(MoleButtonFeedbackModifier(isPressed: configuration.isPressed,
                                                 pressedScale: 0.99))
            .animation(reduceMotion ? nil : MoleMotion.selection, value: isSelected)
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if isSelected {
            return Color.moleAccent.opacity(isPressed ? 0.24 : 0.16)
        }
        return isPressed ? Color.surface3 : Color.surface2
    }
}

/// 通用按钮微交互。Reduce Motion 下保留颜色/亮度反馈，但不做缩放和位移。
private struct MoleButtonFeedbackModifier: ViewModifier {
    let isPressed: Bool
    var pressedScale: CGFloat = 0.98

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .brightness(isEnabled && isHovering ? 0.025 : 0)
            .scaleEffect(reduceMotion || !isEnabled || !isPressed ? 1 : pressedScale)
            .offset(y: reduceMotion || !isEnabled || !isPressed ? 0 : 1)
            .animation(reduceMotion ? nil : MoleMotion.press, value: isPressed)
            .animation(reduceMotion ? nil : MoleMotion.press, value: isHovering)
            .onHover { isHovering = $0 }
    }
}

struct SizeBadge: View {
    let text: String
    var prominent = false

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(prominent ? Color.moleAccentText : .secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(prominent
                ? AnyShapeStyle(Color.moleAccent.opacity(0.32))
                : AnyShapeStyle(.quaternary)))
    }
}

// MARK: - 胶囊分段导航

struct PillPicker: View {
    let items: [String]
    @Binding var selection: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Namespace private var selectionNamespace
    @State private var previousSelection: Int
    @State private var settledSelection: Int
    @State private var liquidProgress: CGFloat

    private var itemHorizontalPadding: CGFloat { items.count >= 8 ? 10 : 14 }

    init(items: [String], selection: Binding<Int>) {
        self.items = items
        _selection = selection
        let initialSelection = selection.wrappedValue
        _previousSelection = State(initialValue: initialSelection)
        _settledSelection = State(initialValue: initialSelection)
        _liquidProgress = State(initialValue: 1)
    }

    @ViewBuilder
    var body: some View {
        // 内容比窗口窄时居中；超出窗口时保留完整宽度，允许横向滚动。
        GeometryReader { geometry in
            ScrollView(.horizontal, showsIndicators: false) {
                Group {
                    if #available(macOS 26.0, *), !reduceTransparency {
                        nativeGlassPicker
                    } else {
                        fallbackGooeyPicker
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
            }
        }
        .frame(height: pickerHeight)
    }

    private var pickerHeight: CGFloat {
        if #available(macOS 26.0, *), !reduceTransparency { return 36 }
        return 34
    }

    @available(macOS 26.0, *)
    private var nativeGlassPicker: some View {
        GlassEffectContainer(spacing: 24) {
            HStack(spacing: 4) {
                ForEach(items.indices, id: \.self) { index in
                    let selected = selection == index
                    Button { select(index) } label: {
                        if selected {
                            Text(items[index])
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.primary)
                                .padding(.horizontal, itemHorizontalPadding)
                                .frame(height: 28)
                                .background {
                                    // 只保留几何锚点，不再叠色块：玻璃自己就是选中态。
                                    Capsule()
                                        .fill(Color.clear)
                                        .matchedGeometryEffect(id: "pill-selection",
                                                               in: selectionNamespace)
                                }
                                // 文字必须作为 glassEffect 的内容；把独立玻璃 sibling
                                // 放在文字后方会被 AppKit 的玻璃合成层反向遮挡。
                                .glassEffect(
                                    Glass.regular
                                        .tint(Color.accent.opacity(0.22))
                                        .interactive(!reduceMotion),
                                    in: Capsule()
                                )
                                .glassEffectID(index, in: selectionNamespace)
                                .glassEffectTransition(reduceMotion ? .identity : .matchedGeometry)
                                .contentShape(Capsule())
                        } else {
                            Text(items[index])
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.secondary)
                                .padding(.horizontal, itemHorizontalPadding)
                                .frame(height: 28)
                                .contentShape(Capsule())
                        }
                    }
                    .buttonStyle(.plain)
                    .zIndex(selected ? 1 : 0)
                }
            }
        }
        .padding(4)
        .background(Capsule().fill(Color.surface1))
        .overlay(Capsule().strokeBorder(.separator.opacity(0.45), lineWidth: 1))
        // Keep this value animation as a fallback for programmatic navigation.
        // Pointer clicks use an explicit transaction in select(_:), which is
        // required for reliable glass hierarchy transitions on macOS 26.
        .animation(reduceMotion ? nil : selectionAnimation,
                   value: selection)
        .onAppear {
            previousSelection = selection
            settledSelection = selection
        }
    }

    private var fallbackGooeyPicker: some View {
        HStack(spacing: 4) {
            ForEach(items.indices, id: \.self) { index in
                let selected = selection == index
                Button { select(index) } label: {
                    Text(items[index])
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(selected ? AnyShapeStyle(Color.primary) : AnyShapeStyle(Color.secondary))
                        .padding(.horizontal, itemHorizontalPadding)
                        .frame(height: 26)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .anchorPreference(key: PillBoundsPreferenceKey.self, value: .bounds) {
                    [index: $0]
                }
            }
        }
        .padding(4)
        .backgroundPreferenceValue(PillBoundsPreferenceKey.self) { bounds in
            GeometryReader { proxy in
                if let targetAnchor = bounds[selection] {
                    let target = proxy[targetAnchor]
                    let source = bounds[previousSelection].map { proxy[$0] } ?? target
                    GooeySelectionSurface(from: source,
                                          to: target,
                                          progress: liquidProgress,
                                          reduceTransparency: reduceTransparency)
                }
            }
        }
        .background(Capsule().fill(.quinary))
        .overlay(Capsule().strokeBorder(.separator.opacity(0.5), lineWidth: 1))
        .onAppear {
            previousSelection = selection
            settledSelection = selection
        }
        .onChange(of: selection) { next in
            guard items.indices.contains(next), next != settledSelection else { return }
            if reduceMotion {
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    previousSelection = next
                    settledSelection = next
                    liquidProgress = 1
                }
                return
            }
            animateFallback(from: settledSelection, to: next)
        }
    }

    private func select(_ index: Int) {
        guard items.indices.contains(index), index != selection else { return }
        let oldSelection = selection

        if reduceMotion {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                previousSelection = oldSelection
                settledSelection = index
                selection = index
                liquidProgress = 1
            }
            return
        }

        if #available(macOS 26.0, *), !reduceTransparency {
            previousSelection = oldSelection
            settledSelection = index
            withAnimation(selectionAnimation) {
                selection = index
            }
            return
        }

        animateFallback(from: oldSelection, to: index)
        // Do not publish the global tab selection from a transaction that has
        // animations disabled. AnimatedTabContent owns its own page transition.
        selection = index
    }

    private var selectionAnimation: Animation {
        .spring(response: 0.56, dampingFraction: 0.72, blendDuration: 0.16)
    }

    private func animateFallback(from oldSelection: Int, to newSelection: Int) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            previousSelection = oldSelection
            settledSelection = newSelection
            liquidProgress = 0
        }
        DispatchQueue.main.async {
            withAnimation(selectionAnimation) {
                liquidProgress = 1
            }
        }
    }
}

private struct PillBoundsPreferenceKey: PreferenceKey {
    static var defaultValue: [Int: Anchor<CGRect>] = [:]

    static func reduce(value: inout [Int: Anchor<CGRect>],
                       nextValue: () -> [Int: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// liquid-gooey 的原理级 SwiftUI 回退：只过滤底层轮廓，文字和按钮命中区保持
/// 在独立的清晰层。Canvas 仅在分段切换的短动画期间重绘，静止时没有计时循环。
private struct GooeySelectionSurface: View, Animatable {
    let from: CGRect
    let to: CGRect
    var progress: CGFloat
    let reduceTransparency: Bool

    @Environment(\.colorScheme) private var colorScheme

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        Canvas { context, _ in
            let amount = min(1, max(0, progress))
            if reduceTransparency {
                context.fill(capsulePath(in: inset(interpolate(from, to, amount), by: 1)),
                             with: .color(Color.moleAccent.opacity(0.34)))
                return
            }

            let surface = colorScheme == .dark
                ? Color.white.opacity(0.22)
                : Color.white.opacity(0.92)
            context.addFilter(.alphaThreshold(min: 0.48, color: surface))
            context.addFilter(.blur(radius: 4.2))
            context.drawLayer { layer in
                if amount <= 0.001 || nearlyEqual(from, to) {
                    layer.fill(capsulePath(in: inset(from, by: 2)), with: .color(.white))
                    return
                }
                if amount >= 0.999 {
                    layer.fill(capsulePath(in: inset(to, by: 2)), with: .color(.white))
                    return
                }

                let sourcePhase = min(1, amount / 0.72)
                let targetPhase = max(0, (amount - 0.28) / 0.72)
                if sourcePhase < 1 {
                    let sourceRect = scaled(inset(from, by: 2),
                                            x: 1 - 0.58 * sourcePhase,
                                            y: 1 - 0.38 * sourcePhase)
                    layer.fill(capsulePath(in: sourceRect), with: .color(.white))
                }
                if targetPhase > 0 {
                    let targetRect = scaled(inset(to, by: 2),
                                            x: 0.42 + 0.58 * targetPhase,
                                            y: 0.62 + 0.38 * targetPhase)
                    layer.fill(capsulePath(in: targetRect), with: .color(.white))
                }

                let velocity = sin(.pi * amount)
                let center = CGPoint(x: from.midX + (to.midX - from.midX) * amount,
                                     y: from.midY + (to.midY - from.midY) * amount)
                let baseRadius = min(from.height, to.height) * (0.18 + 0.10 * velocity)
                let distance = abs(to.midX - from.midX)
                let stretch = 1 + min(0.9, distance / 190) * velocity
                let droplet = CGRect(x: center.x - baseRadius * stretch,
                                     y: center.y - baseRadius * (1 - 0.12 * velocity),
                                     width: baseRadius * 2 * stretch,
                                     height: baseRadius * 2 * (1 - 0.12 * velocity))
                layer.fill(Path(ellipseIn: droplet), with: .color(.white))
            }
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.28 : 0.16),
                radius: 4, y: 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func inset(_ rect: CGRect, by amount: CGFloat) -> CGRect {
        rect.insetBy(dx: amount, dy: amount)
    }

    private func scaled(_ rect: CGRect, x: CGFloat, y: CGFloat) -> CGRect {
        CGRect(x: rect.midX - rect.width * x / 2,
               y: rect.midY - rect.height * y / 2,
               width: rect.width * x,
               height: rect.height * y)
    }

    private func interpolate(_ from: CGRect, _ to: CGRect, _ progress: CGFloat) -> CGRect {
        CGRect(x: from.minX + (to.minX - from.minX) * progress,
               y: from.minY + (to.minY - from.minY) * progress,
               width: from.width + (to.width - from.width) * progress,
               height: from.height + (to.height - from.height) * progress)
    }

    private func capsulePath(in rect: CGRect) -> Path {
        Path(roundedRect: rect, cornerRadius: rect.height / 2)
    }

    private func nearlyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.midX - rhs.midX) < 0.5 &&
            abs(lhs.midY - rhs.midY) < 0.5 &&
            abs(lhs.width - rhs.width) < 0.5 &&
            abs(lhs.height - rhs.height) < 0.5
    }
}

struct ProgressBar: View {
    let value: Double
    var tint: Color = .moleAccent

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(tint)
                    .frame(width: max(3, proxy.size.width * min(1, max(0, value))))
            }
        }
    }
}

struct Sparkline: View {
    let data: [Double]
    var secondary: [Double] = []
    var tint: Color = .moleAccent
    var secondaryTint: Color = .moleAccentText

    var body: some View {
        GeometryReader { proxy in
            let peak = max(data.max() ?? 0, secondary.max() ?? 0, 0.001)
            stroke(data, in: proxy.size, peak: peak)
                .stroke(tint, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
            if !secondary.isEmpty {
                stroke(secondary, in: proxy.size, peak: peak)
                    .stroke(secondaryTint.opacity(0.85),
                            style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round))
            }
        }
    }

    private func stroke(_ samples: [Double], in size: CGSize, peak: Double) -> Path {
        var path = Path()
        guard !samples.isEmpty else { return path }
        for (index, sample) in samples.enumerated() {
            let x = size.width * CGFloat(index) / CGFloat(max(1, samples.count - 1))
            let y = size.height * (1 - CGFloat(sample / peak) * 0.9)
            if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        return path
    }
}

// MARK: - 观测仪表

/// 只用于有自然上限的占用率。网络吞吐没有 100%，不要复用这个圆环。
struct UsageRing: View {
    var progress: Double
    var lineWidth: CGFloat = 4.5

    private var tint: Color {
        if progress >= 0.92 { return .danger }
        if progress >= 0.75 { return .warning }
        return .moleAccent
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.hairline, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(max(0, min(1, progress))))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .accessibilityHidden(true)
    }
}

/// 网络仪表：下行、上行的绝对速率，旁边是近期走势。没有百分比圆环。
struct NetworkFlowMeter: View {
    let downMBps: Double
    let upMBps: Double
    let downHistory: [Double]
    let upHistory: [Double]
    var showsTitle = true
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showsTitle {
                Text(l10n.t("metric.network"))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    rateRow(symbol: "arrow.down",
                            text: ByteFormat.megabytesPerSecond(downMBps),
                            tint: .moleAccentText)
                    rateRow(symbol: "arrow.up",
                            text: ByteFormat.megabytesPerSecond(upMBps),
                            tint: .secondary)
                }
                Sparkline(data: downHistory.isEmpty ? [0] : downHistory,
                          secondary: upHistory,
                          tint: .moleAccent,
                          secondaryTint: .moleAccentText)
                    .frame(maxWidth: .infinity)
                    .frame(height: 26)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(l10n.t("metric.network"))
        .accessibilityValue("\(ByteFormat.megabytesPerSecond(downMBps)) \(ByteFormat.megabytesPerSecond(upMBps))")
    }

    private func rateRow(symbol: String, text: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 10)
            Text(text)
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}

struct LoadInstrument: View {
    let load: Double
    let cores: Int
    @ObservedObject private var l10n = L10n.shared

    private var fraction: Double {
        guard cores > 0 else { return 0 }
        return load / Double(cores)
    }

    private var tint: Color {
        if fraction >= 1 { return .danger }
        if fraction >= 0.75 { return .warning }
        return .moleAccent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(l10n.t("metric.load"))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Text(load.isFinite ? String(format: "%.2f", max(0, load)) : "--")
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .lineLimit(1)
            ProgressBar(value: min(1, max(0, fraction)), tint: tint)
                .frame(height: 4)
            Text(cores > 0 ? l10n.tf("metric.load.cores", cores) : " ")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(l10n.t("metric.load"))
        .accessibilityValue(String(format: "%.2f", max(0, load)))
    }
}

struct UptimeInstrument: View {
    let seconds: UInt64
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(l10n.t("metric.uptime"))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Text(formatted)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Image(systemName: "clock")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.moleAccentText)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(l10n.t("metric.uptime"))
        .accessibilityValue(formatted)
    }

    private var formatted: String {
        let days = Int(seconds / 86_400)
        let hours = Int((seconds % 86_400) / 3_600)
        let minutes = Int((seconds % 3_600) / 60)
        if days > 0 { return l10n.tf("metric.uptime.days", days, hours) }
        if hours > 0 { return l10n.tf("metric.uptime.hours", hours, minutes) }
        return l10n.tf("metric.uptime.minutes", minutes)
    }
}

struct BatteryInstrument: View {
    let percent: Double
    let charging: Bool
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        VStack(spacing: 4) {
            UsageRing(progress: percent / 100, lineWidth: 4)
                .frame(width: 26, height: 26)
                .overlay {
                    Image(systemName: charging ? "bolt.fill" : "battery.100")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.moleAccentText)
                }
            Text(String(format: "%.0f%%", min(100, max(0, percent))))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
            Text(l10n.t("metric.battery"))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Text(l10n.t(charging ? "metric.battery.charging" : "metric.battery.onbattery"))
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(l10n.t("metric.battery"))
        .accessibilityValue(String(format: "%.0f%%", percent))
    }
}

struct SwapInstrument: View {
    let used: UInt64
    let total: UInt64
    @ObservedObject private var l10n = L10n.shared

    private var fraction: Double {
        guard total > 0 else { return 0 }
        return Double(used) / Double(total)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(l10n.t("metric.swap"))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Text(ByteFormat.memoryShort(used))
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .lineLimit(1)
            ProgressBar(value: fraction, tint: fraction >= 0.8 ? .warning : .moleAccent)
                .frame(height: 4)
            Text(ByteFormat.memoryShort(total))
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(l10n.t("metric.swap"))
        .accessibilityValue(ByteFormat.memoryShort(used))
    }
}

struct RingInstrument: View {
    let title: String
    let value: String
    let caption: String
    let progress: Double

    var body: some View {
        VStack(spacing: 3) {
            UsageRing(progress: progress, lineWidth: 4)
                .frame(width: 26, height: 26)
            Text(value)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(caption)
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }
}

/// 主窗口快捷指标：占用率用圆环，网络用速率，并附带负载、运行时间等读数。
struct SystemInstrumentBar: View {
    let metrics: MetricsSnapshot
    let downloadHistory: [Double]
    let uploadHistory: [Double]
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        HStack(spacing: 0) {
            RingInstrument(title: l10n.t("metric.cpu"),
                           value: percent(metrics.cpuPercent),
                           caption: metrics.logicalCPUCount > 0
                               ? l10n.tf("metric.load.cores", metrics.logicalCPUCount) : " ",
                           progress: metrics.cpuPercent / 100)
            barDivider
            RingInstrument(title: l10n.t("metric.memory"),
                           value: percent(metrics.memoryPercent),
                           caption: metrics.memoryTotalBytes > 0
                               ? "\(ByteFormat.memoryShort(metrics.memoryUsedBytes)) / \(ByteFormat.memoryShort(metrics.memoryTotalBytes))"
                               : " ",
                           progress: metrics.memoryPercent / 100)
            barDivider
            RingInstrument(title: l10n.t("metric.disk.usage"),
                           value: percent(metrics.diskUsedPercent),
                           caption: metrics.diskFreeBytes > 0
                               ? l10n.tf("metric.disk.free", ByteFormat.format(metrics.diskFreeBytes))
                               : " ",
                           progress: metrics.diskUsedPercent / 100)
            barDivider
            NetworkFlowMeter(downMBps: metrics.networkRxMBps,
                             upMBps: metrics.networkTxMBps,
                             downHistory: downloadHistory,
                             upHistory: uploadHistory)
                .frame(minWidth: 148, maxWidth: 210)
                .padding(.horizontal, 8)
            barDivider
            LoadInstrument(load: metrics.loadOneMinute, cores: metrics.logicalCPUCount)
                .frame(minWidth: 64, maxWidth: 88)
                .padding(.horizontal, 8)
            barDivider
            UptimeInstrument(seconds: metrics.uptimeSeconds)
                .frame(minWidth: 72, maxWidth: 96)
                .padding(.horizontal, 8)
            if metrics.batteryPresent {
                barDivider
                BatteryInstrument(percent: metrics.batteryPercent, charging: metrics.batteryCharging)
                    .frame(maxWidth: 78)
            }
            if metrics.swapTotalBytes > 0 {
                barDivider
                SwapInstrument(used: metrics.swapUsedBytes, total: metrics.swapTotalBytes)
                    .frame(minWidth: 64, maxWidth: 84)
                    .padding(.horizontal, 8)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .frame(minHeight: 92)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.surface2))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.4), lineWidth: 1))
    }

    private var barDivider: some View {
        Divider().frame(height: 52)
    }

    private func percent(_ value: Double) -> String {
        String(format: "%.0f%%", min(100, max(0, value)))
    }
}

// MARK: - 空态 / 占位

struct EmptyStateView: View {
    let symbol: String
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 设置面板（语言 + 功能页显隐）

struct SettingsSheet: View {
    @ObservedObject var state: AppState
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var languageExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(l10n.t("settings.title"))
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button {
                    state.showSettingsSheet = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            .padding(16)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(l10n.t("header.language"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Button {
                        if reduceMotion { languageExpanded.toggle() }
                        else { withAnimation(MoleMotion.panel) { languageExpanded.toggle() } }
                    } label: {
                        HStack {
                            Text(L10n.shared.language.displayName)
                                .font(.system(size: 12))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                                .rotationEffect(.degrees(languageExpanded ? 180 : 0))
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(Capsule().fill(.quinary))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if languageExpanded {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 5)], spacing: 5) {
                            ForEach(AppLanguage.allCases) { language in
                                Button {
                                    L10n.shared.setLanguage(language)
                                    if reduceMotion { languageExpanded = false }
                                    else { withAnimation(MoleMotion.panel) { languageExpanded = false } }
                                } label: {
                                    HStack(spacing: 6) {
                                        Text(language.displayName)
                                            .lineLimit(1)
                                        Spacer(minLength: 2)
                                        Image(systemName: "checkmark")
                                            .opacity(L10n.shared.language == language ? 1 : 0)
                                    }
                                    .font(.system(size: 10, weight: L10n.shared.language == language ? .semibold : .regular))
                                    .padding(.horizontal, 8)
                                    .frame(height: 25)
                                    .background(RoundedRectangle(cornerRadius: 7)
                                        .fill(L10n.shared.language == language
                                              ? Color.moleAccent.opacity(0.15) : Color.surface1))
                                    .contentShape(RoundedRectangle(cornerRadius: 7))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .transition(.molePanelReveal)
                    }

                    Divider().padding(.vertical, 2)
                    Text(l10n.t("settings.tools"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Toggle(l10n.t("clip.title"), isOn: $state.clipboardHistoryEnabled)
                        .toggleStyle(MoleSwitchToggleStyle())
                        .controlSize(.small)
                        .tint(Color.moleAccentText)
                        .font(.system(size: 12))
                    if state.clipboardHistoryEnabled {
                        Stepper(value: clipboardCapacityBinding, in: 10...500, step: 10) {
                            HStack {
                                Text(l10n.t("settings.clipboard.capacity"))
                                Spacer()
                                Text("\(state.clipboardManager.capacity)")
                                    .monospacedDigit()
                                    .foregroundStyle(Color.moleAccentText)
                            }
                            .font(.system(size: 10))
                        }
                        .controlSize(.small)
                        HStack {
                            Text(l10n.tf("settings.clipboard.count", state.clipboardManager.entries.count))
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                            Spacer()
                            Button(l10n.t("clip.clearUnpinned")) {
                                state.clipboardManager.clearUnpinned()
                            }
                            .buttonStyle(SecondaryButtonStyle())
                            .disabled(state.clipboardManager.unpinnedCount == 0)
                        }
                        .transition(.molePanelReveal)
                    }
                    Toggle(l10n.t("shot.hotkey"), isOn: $state.screenshotHotKeyEnabled)
                        .toggleStyle(MoleSwitchToggleStyle())
                        .controlSize(.small)
                        .tint(Color.moleAccentText)
                        .font(.system(size: 12))
                    if state.screenshotHotKeyRegistrationFailed {
                        Label(l10n.t("settings.screenshot.conflict"), systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                    }
                    HStack(spacing: 8) {
                        Button(l10n.t("settings.screenshot.capture")) {
                            state.showSettingsSheet = false
                            DispatchQueue.main.async { state.takeScreenshot() }
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        Button {
                            state.presentPermissionCenter()
                        } label: {
                            Label(l10n.t("permissions.openCenter"), systemImage: "lock.shield")
                        }
                        .buttonStyle(PrimaryButtonStyle())
                    }
                    Text(l10n.t("settings.tools.hint"))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)

                    Divider().padding(.vertical, 2)
                    Text(l10n.t("settings.pages"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    VStack(spacing: 2) {
                        ForEach(AppState.PageKey.configurableCases) { key in
                            Toggle(l10n.t(key.titleKey), isOn: pageBinding(key))
                                .toggleStyle(MoleSwitchToggleStyle())
                                .controlSize(.small)
                                .tint(Color.moleAccentText)
                                .font(.system(size: 12))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: 7).fill(Color.surface1))
                        }
                    }
                    Text(l10n.t("settings.pages.hint"))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
        .frame(width: 380, height: 520)
    }

    private func pageBinding(_ key: AppState.PageKey) -> Binding<Bool> {
        Binding(
            get: { !state.hiddenPages.contains(key.rawValue) },
            set: { state.setPageVisible(key, $0) })
    }

    private var clipboardCapacityBinding: Binding<Int> {
        Binding(
            get: { state.clipboardManager.capacity },
            set: { state.clipboardManager.updateCapacity($0) })
    }
}

/// 标题栏小胶囊按钮：与面板玻璃同调，SwiftUI 命中可靠。
struct TitleBarButtonStyle: ButtonStyle {
    var isActive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(configuration.isPressed ? Color.primary : Color.secondary)
            .frame(width: 32, height: 24)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(configuration.isPressed || isActive
                          ? AnyShapeStyle(Color.surface3)
                          : AnyShapeStyle(Color.surface2)))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Color.hairline, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .modifier(MoleButtonFeedbackModifier(isPressed: configuration.isPressed))
    }
}
