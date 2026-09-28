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

/// The source control and destination surface share a native glass identity.
/// Older macOS and accessibility settings retain a readable material fallback.
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
            // Background controls must leave the glass compositor while a modal
            // overlaps them, otherwise native glass joins them to the dialog.
            label.background(RoundedRectangle(cornerRadius: 12).fill(Color.surface1))
                .allowsHitTesting(false)
        } else {
            Button {
                withAnimation(reduceMotion ? nil : MoleMotion.panel, action)
            } label: { label }
            .buttonStyle(.plain)
            .liquidSurface(id, radius: 12)
        }
    }
}

struct IslandLiquidSurface: ViewModifier {
    let shape: NotchShape
    let namespace: Namespace.ID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !reduceTransparency {
            content
                .glassEffect(.regular.tint(.black.opacity(0.25)), in: shape)
                .glassEffectID("notch", in: namespace)
                .glassEffectTransition(reduceMotion ? .identity : .matchedGeometry)
        } else {
            content.background {
                if reduceTransparency { shape.fill(Color.glassOpaque) }
                else { shape.fill(.ultraThinMaterial) }
            }
            .clipShape(shape)
        }
    }
}
