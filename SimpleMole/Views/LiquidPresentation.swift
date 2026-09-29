import SwiftUI

private struct LiquidNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}
private struct LiquidDialogIDKey: EnvironmentKey {
    static let defaultValue: String? = nil
}
extension EnvironmentValues {
    var liquidNamespace: Namespace.ID? {
        get { self[LiquidNamespaceKey.self] }
        set { self[LiquidNamespaceKey.self] = newValue }
    }
    var liquidDialogID: String? {
        get { self[LiquidDialogIDKey.self] }
        set { self[LiquidDialogIDKey.self] = newValue }
    }
}

/// Group native glass surfaces; scrolling controls use ordinary SwiftUI surfaces
/// so the window-level glass compositor cannot draw them outside their viewport.
struct LiquidGlassGroup<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 8, content: content)
        } else {
            content()
        }
    }
}

private struct LiquidSurface: ViewModifier {
    let id: String
    var radius: CGFloat
    @Environment(\.liquidNamespace) private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !reduceTransparency, let namespace {
            content
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .glassEffectID(id, in: namespace)
                .glassEffectTransition(reduceMotion ? .identity : .matchedGeometry)
        } else {
            content.background(GlassSurface(cornerRadius: radius, usesSystemGlass: false))
        }
    }
}
extension View {
    func liquidSurface(_ id: String, radius: CGFloat = 20) -> some View {
        modifier(LiquidSurface(id: id, radius: radius))
    }
}

struct LiquidActionButton: View {
    let id: String
    let title: String
    let symbol: String
    let action: () -> Void
    @Environment(\.liquidDialogID) private var activeID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var label: some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 12, weight: .medium))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .contentShape(RoundedRectangle(cornerRadius: 12))
    }
    var body: some View {
        if activeID == id {
            label.hidden().accessibilityHidden(true)
        } else if activeID != nil {
            label.background(RoundedRectangle(cornerRadius: 12).fill(Color.surface1))
                .allowsHitTesting(false)
        } else {
            Button {
                withAnimation(reduceMotion ? nil : MoleMotion.panel, action)
            } label: { label }
            .buttonStyle(MolePlainButtonStyle())
            // Native glass is composed by the window-level container and can
            // escape ScrollView clipping. Only the modal uses liquidSurface.
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.surface2))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.hairline, lineWidth: 1)
                .allowsHitTesting(false))
        }
    }
}

struct IslandLiquidSurface: ViewModifier {
    let shape: NotchShape
    var isExpanded = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var handleVeil: some View {
        shape.fill(Color.islandHandleVeil)
            .opacity(isExpanded ? 0 : 1)
            .allowsHitTesting(false)
    }

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !reduceTransparency {
            // 玻璃必须直接承载内容（content.glassEffect），不能作为 background
            // sibling 垫在内容后面——玻璃合成层会把上方内容反向遮挡成毛玻璃
            // （同类坑见 Components.swift 原生分段控件的注释）。收起态只叠
            // 半透明暗纱，与展开面板共享同一玻璃质感。
            content
                .background { handleVeil }
                .glassEffect(Glass.regular.tint(Color.islandGlassTint), in: shape)
                .clipShape(shape)
                .contentShape(shape)
        } else {
            content
                .background {
                    if reduceTransparency {
                        shape.fill(Color.glassOpaque)
                    } else {
                        ZStack {
                            shape.fill(.ultraThinMaterial)
                            handleVeil
                        }
                    }
                }
                .clipShape(shape)
                .contentShape(shape)
        }
    }
}
