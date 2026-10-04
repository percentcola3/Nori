import SwiftUI
import AppKit

// 设计 token 与玻璃背景见 Views/Theme.swift。

// Nori branding and mascot motion live in NoriMascotView.swift.

enum MoleMotion {
    /// 普通控件的按压节奏：跟手的小回弹弹簧——按下即缩、松手轻微回弹，
    /// 是系统控件“液态”手感的核心。只用于瞬时交互反馈，不用于面板切换。
    static let press = Animation.spring(response: 0.24, dampingFraction: 0.62,
                                        blendDuration: 0.08)
    /// 悬停亮度等不应回弹的瞬时状态：快速淡入淡出。
    static let hover = Animation.easeOut(duration: 0.11)
    /// 选择态切换比面板展开更快，避免列表连续操作时产生拖沓感。
    static let selection = Animation.spring(response: 0.28, dampingFraction: 0.82,
                                             blendDuration: 0.06)
    /// 控件级状态切换（开关、分段、图标）带一点弹性。
    static let control = Animation.spring(response: 0.36, dampingFraction: 0.72,
                                          blendDuration: 0.10)
    /// 面板与内容展开收缩：更长的行程 + 温和的回弹，内容“跟随”到位。
    static let panel = Animation.spring(response: 0.46, dampingFraction: 0.78,
                                        blendDuration: 0.12)
}

extension AnyTransition {
    /// 行内展开由父容器插值高度，内容只淡入淡出。
    /// 避免向上平移时穿过标题；父容器需裁剪收缩期间的淡出内容。
    static var molePanelReveal: AnyTransition {
        .opacity
    }

    /// 页面级状态互换（扫描中 ↔ 结果/空态）：进场内容轻微上浮淡入，
    /// 离场仅淡出。行程刻意小于 tab 切换，两层动效不叠加。
    /// 需配合根视图的 `.animation(MoleMotion.panel, value: 驱动状态)` 生效。
    static var moleStateSwap: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 10)),
            removal: .opacity
        )
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

struct ActionGlassChrome: ViewModifier {
    /// Semantic tint is opt-in; neutral callers keep the existing glass surface.
    var tint: Color? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.isEnabled) private var isEnabled

    @ViewBuilder
    func body(content: Content) -> some View {
        if !isEnabled {
            // 禁用控件不用玻璃：实底胶囊，避免次要操作与启用态同样醒目。
            content.background(Capsule().fill(Color.surface1))
        } else if #available(macOS 26.0, *), !reduceTransparency, controlActiveState == .key {
            if let tint {
                content
                    .glassEffect(.regular.tint(tint.opacity(0.24)).interactive(!reduceMotion), in: Capsule())
                    .clipGlassEdge(in: Capsule())
            } else {
                content
                    .glassEffect(.regular.interactive(!reduceMotion), in: Capsule())
                    .clipGlassEdge(in: Capsule())
            }
        } else {
            content
                .background {
                    GlassSurface(cornerRadius: 100, usesSystemGlass: false)
                        .overlay {
                            if let tint {
                                Capsule().fill(tint.opacity(0.10))
                            }
                        }
                }
        }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color? = nil

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(isEnabled ? (tint ?? Color.primary) : Color.secondary)
            .padding(.horizontal, 20)
            .frame(minHeight: 36)
            .modifier(ActionGlassChrome(tint: isEnabled ? tint : nil))
            .opacity(isEnabled ? 1 : 0.5)
            .modifier(MoleButtonFeedbackModifier(isPressed: configuration.isPressed))
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var tint: Color?
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(isEnabled ? (tint ?? .primary) : .secondary)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Capsule().fill(configuration.isPressed ? Color.accent.opacity(0.22) : Color.surface2))
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.5)
            .modifier(MoleButtonFeedbackModifier(isPressed: configuration.isPressed))
    }
}

struct DangerButtonStyle: ButtonStyle {
    /// 覆盖默认的 danger 着色，供非红色但同样需要警示表面的入口。
    var tint: Color? = nil

    private var base: Color { tint ?? Color.danger }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(base)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(base.opacity(configuration.isPressed ? 0.10 : 0.06)))
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
    var showsBackground = true

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
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .opacity(isEnabled ? 1 : 0.45)
            .modifier(MoleButtonFeedbackModifier(isPressed: configuration.isPressed))
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        guard showsBackground else { return .clear }
        if isActive {
            return Color.moleAccent.opacity(isPressed ? 0.22 : 0.15)
        }
        return isPressed ? Color.surface3 : Color.surface2
    }
}

/// 可选择列表行的统一交互表面。固定 padding，选择与按压不会改变布局。
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
            .modifier(ListRowSurface(selected: isSelected))
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .opacity(isEnabled ? 1 : 0.45)
            .modifier(MoleButtonFeedbackModifier(isPressed: configuration.isPressed,
                                                 pressedScale: 0.99))
            .animation(reduceMotion ? nil : MoleMotion.selection, value: isSelected)
    }


}

/// 清理、Agent 和分析共用的内容行/卡片底色；布局先完成，再包住内容。
/// 内容层不使用玻璃：分组头 surface2，普通行 surface1，选中态 selectionFill。
struct ListRowSurface: ViewModifier {
    enum Emphasis { case row, header }
    var selected = false
    var emphasis: Emphasis = .row

    func body(content: Content) -> some View {
        content.background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(fillColor)
        }
    }

    private var fillColor: Color {
        if selected { return .selectionFill }
        return emphasis == .header ? .surface2 : .surface1
    }
}

extension View {
    /// L2 工作区面板：surface1 圆角 14 的内容平面，不是玻璃。
    /// 只在带侧栏的页面套右侧工作区；单列页内容直接落在窗口玻璃上。
    func contentPanel() -> some View {
        background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.surface1))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// 侧栏选中透镜（L1）：分析与开发环境侧栏共用的导航选中玻璃。
/// 同一侧栏使用同一个 id，选中块在行间做 matchedGeometry 流动。
struct SidebarSelectionLens: ViewModifier {
    let selected: Bool
    let id: String
    let namespace: Namespace.ID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.controlActiveState) private var controlActiveState

    @ViewBuilder func body(content: Content) -> some View {
        if selected {
            if #available(macOS 26.0, *), !reduceTransparency, controlActiveState == .key {
                content.glassEffect(.regular.interactive(!reduceMotion), in: RoundedRectangle(cornerRadius: 10))
                    .glassEffectID(id, in: namespace)
                    .glassEffectTransition(reduceMotion ? .identity : .matchedGeometry)
            } else {
                content.background(GlassSurface(cornerRadius: 10, usesSystemGlass: false, highlighted: true))
            }
        } else { content }
    }
}

/// 通用按钮微交互。Reduce Motion 下保留颜色/亮度反馈，但不做缩放和位移。
struct MoleButtonFeedbackModifier: ViewModifier {
    let isPressed: Bool
    var pressedScale: CGFloat = 0.955

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .brightness(isEnabled && isHovering ? 0.025 : 0)
            // 按压用带小回弹的弹簧：按下即缩，松手弹性回位；悬停亮度
            // 走快速淡入，不参与回弹。
            .scaleEffect(reduceMotion || !isEnabled || !isPressed ? 1 : pressedScale)
            .offset(y: reduceMotion || !isEnabled || !isPressed ? 0 : 1.5)
            .animation(reduceMotion ? nil : MoleMotion.press, value: isPressed)
            .animation(reduceMotion ? nil : MoleMotion.hover, value: isHovering)
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
    let alignment: Alignment

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.controlActiveState) private var controlActiveState
    @Namespace private var selectionNamespace
    @State private var previousSelection: Int
    @State private var settledSelection: Int
    @State private var liquidProgress: CGFloat

    private var itemHorizontalPadding: CGFloat { items.count >= 8 ? 10 : 14 }

    init(items: [String], selection: Binding<Int>, alignment: Alignment = .center) {
        self.items = items
        _selection = selection
        self.alignment = alignment
        let initialSelection = selection.wrappedValue
        _previousSelection = State(initialValue: initialSelection)
        _settledSelection = State(initialValue: initialSelection)
        _liquidProgress = State(initialValue: 1)
    }

    @ViewBuilder
    var body: some View {
        // 内容比窗口窄时按调用方指定的方式对齐；超出窗口时允许横向滚动。
        GeometryReader { geometry in
            ScrollView(.horizontal, showsIndicators: false) {
                Group {
                    if #available(macOS 26.0, *), !reduceTransparency {
                        if controlActiveState == .key {
                            nativeGlassPicker
                        } else {
                            inactiveGlassPicker
                        }
                    } else {
                        fallbackGooeyPicker
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: geometry.size.width, minHeight: geometry.size.height,
                       alignment: alignment)
            }
        }
        .frame(height: pickerHeight)
    }

    private var pickerHeight: CGFloat {
        if #available(macOS 26.0, *), !reduceTransparency { return 36 }
        return 34
    }

    /// 非关键窗口使用更轻的单层材质，保留与原生选中透镜相同的布局尺寸。
    private var inactiveGlassPicker: some View {
        HStack(spacing: 4) {
            ForEach(items.indices, id: \.self) { index in
                let selected = selection == index
                Button { select(index) } label: {
                    Text(items[index])
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .padding(.horizontal, itemHorizontalPadding)
                        .frame(height: 28)
                        .background {
                            if selected {
                                GlassSurface(cornerRadius: 100, usesSystemGlass: false,
                                             highlighted: true)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Capsule().fill(Color.surface1))
    }

    @available(macOS 26.0, *)
    private var nativeGlassPicker: some View {
        GlassEffectContainer(spacing: 24) {
            HStack(spacing: 4) {
                ForEach(items.indices, id: \.self) { index in
                    let selected = selection == index
                    Button { select(index) } label: {
                        if selected {
                            GlassEffectContainer(spacing: 24) {
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
                            }
                            // Clip the compositor, not a child lifted into it by glassEffectID.
                            .clipGlassEdge(in: Capsule())
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

// MARK: - 空态 / 占位

struct EmptyStateView: View {
    let symbol: String
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 14, weight: .medium))
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
