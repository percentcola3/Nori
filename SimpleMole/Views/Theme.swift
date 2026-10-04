import AppKit
import SwiftUI

// MARK: - Nori 品牌深蓝
// 使用 Logo 的墨蓝 #10283F 与冰蓝 #BFEAF2，跟随系统浅色 / 深色外观。
// 深色以墨蓝承托冰蓝 Logo 与按钮，浅色以近白底承托墨蓝文字与按钮。
//
// 规则：
// - 玻璃分层：L0 只保留窗口底的 GlassSurface；L1 导航与浮层（PillPicker
//   选中、侧栏选中透镜、liquidSurface 弹层、灵动岛、启用态主操作按钮）
//   才使用玻璃。内容层一律不用原生玻璃——滚动列表里的玻璃会逃出裁剪，
//   泄漏到相邻视图。
// - 内容平面用 surface：L2 工作区面板 surface1 圆角 14（contentPanel，
//   仅带侧栏页套右侧；单列页不用面板，直接落在窗口玻璃上）；
//   L3 行/卡片用 ListRowSurface——分组头 surface2，普通行 surface1，
//   选中态 selectionFill，已打开路径 surface2。
// - 卡片、行、按钮的底色用 surface1/2/3；不叠组件外围描边。hairline 仅用于
//   内容分隔线。它们随外观取值，不要再写 Color.white.opacity(x)。
// - 强调色只用于选中态、主按钮与关键数值；状态色用 success/warning/danger。
// - 禁用控件不用玻璃，回退 surface1 实底；一屏玻璃不超过 3 处。

/// 品牌配色的原始值：token 与对比度测试共用同一份数据。
enum EarthBluePalette {
    static let accentDark: UInt32 = 0xBFEAF2
    static let accentLight: UInt32 = 0x10283F
    static let accentTextDark: UInt32 = 0xBFEAF2
    static let accentTextLight: UInt32 = 0x10283F
    static let onAccentDark: UInt32 = 0x10283F
    static let onAccentLight: UInt32 = 0xFFFFFF
    /// 玻璃着色在典型后景（深色桌面 / 浅色桌面）上的等效实底，用于对比度估算。
    static let glassDark: UInt32 = 0x10283F
    static let glassLight: UInt32 = 0xF0F5FA
    static let tintDark: UInt32 = 0x10283F
    static let tintLight: UInt32 = 0xEAF1F8
    static let tintAlpha: CGFloat = 0.66
    static let successDark: UInt32 = 0x53C68C
    static let successLight: UInt32 = 0x1E8A55
    static let warningDark: UInt32 = 0xE3A43C
    static let warningLight: UInt32 = 0xA9700E
    static let dangerDark: UInt32 = 0xE56672
    static let dangerLight: UInt32 = 0xCB3D4C

    /// WCAG 2.x 相对亮度。
    static func relativeLuminance(_ hex: UInt32) -> Double {
        func channel(_ value: UInt32) -> Double {
            let c = Double(value) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel((hex >> 16) & 0xFF)
            + 0.7152 * channel((hex >> 8) & 0xFF)
            + 0.0722 * channel(hex & 0xFF)
    }

    /// WCAG 对比度（≥ 4.5 为正文可读）。
    static func contrastRatio(_ a: UInt32, _ b: UInt32) -> Double {
        let la = relativeLuminance(a)
        let lb = relativeLuminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}

extension Color {
    /// 按当前外观（浅色 / 深色）动态取值。
    static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    fileprivate static func srgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: alpha)
    }

    // 强调色
    /// 主强调色：选中态、主按钮底色、进度。
    static let accent = adaptive(light: srgb(EarthBluePalette.accentLight), dark: srgb(EarthBluePalette.accentDark))
    /// 强调色文字：在玻璃上保持 ≥ 4.5:1 对比。
    static let accentText = adaptive(light: srgb(EarthBluePalette.accentTextLight), dark: srgb(EarthBluePalette.accentTextDark))
    /// 主按钮上的文字。
    static let onAccent = adaptive(light: srgb(EarthBluePalette.onAccentLight), dark: srgb(EarthBluePalette.onAccentDark))

    // 玻璃与表面
    /// 减少透明度时的实底。
    static let glassOpaque = adaptive(light: srgb(EarthBluePalette.glassLight), dark: srgb(EarthBluePalette.glassDark))
    /// 卡片 / 行底色三级：中性白罩，避免给品牌深蓝叠加青色。
    static let surface1 = adaptive(light: NSColor.white.withAlphaComponent(0.55),
                                   dark: NSColor.white.withAlphaComponent(0.06))
    static let surface2 = adaptive(light: NSColor.white.withAlphaComponent(0.72),
                                   dark: NSColor.white.withAlphaComponent(0.10))
    static let surface3 = adaptive(light: NSColor.white.withAlphaComponent(0.88),
                                   dark: NSColor.white.withAlphaComponent(0.16))
    /// 开关关闭态的轨道与滑块。
    static let trackOff = adaptive(light: NSColor.black.withAlphaComponent(0.12),
                                   dark: NSColor.white.withAlphaComponent(0.12))
    static let thumbOff = adaptive(light: .white, dark: NSColor.white.withAlphaComponent(0.82))
    /// 内容分隔线；玻璃组件的轮廓由材质本身呈现，不再叠外围描边。
    static let hairline = adaptive(light: NSColor.black.withAlphaComponent(0.10),
                                   dark: NSColor.white.withAlphaComponent(0.13))
    /// 内容行/卡片的选中底：强调色轻染，选中语义与导航的玻璃透镜区分开。
    static let selectionFill = adaptive(light: srgb(EarthBluePalette.accentLight, 0.10),
                                        dark: srgb(EarthBluePalette.accentDark, 0.16))

    // 状态色
    static let success = adaptive(light: srgb(EarthBluePalette.successLight), dark: srgb(EarthBluePalette.successDark))
    static let warning = adaptive(light: srgb(EarthBluePalette.warningLight), dark: srgb(EarthBluePalette.warningDark))
    static let danger = adaptive(light: srgb(EarthBluePalette.dangerLight), dark: srgb(EarthBluePalette.dangerDark))

    // 兼容别名：旧代码里的 mole* 名称直接映射到新 token，避免一次性改 100+ 处。
    static let moleAccent = accent
    static let moleAccentText = accentText
    static let moleOnAccent = onAccent
}

extension Color {
    /// 灵动岛玻璃的着色：浮在任意窗口之上，着色太浅时背后的文字会透上来抢字。
    static let islandGlassTint = Color(nsColor: srgb(EarthBluePalette.tintDark, 0.62))
    /// 折叠句柄上的短横线提示。
    static let islandHandleGrip = Color.white.opacity(0.55)
    /// 折叠手柄的暗色纱罩：半透明，叠在玻璃上加深一档，
    /// 与展开面板保持同一材质观感（不用实底黑遮住玻璃）。
    static let islandHandleVeil = Color.black.opacity(0.30)
}

extension NSColor {
    /// GlassSurface 传给 NSGlassEffectView 的着色（NSColor 版本，随外观变化）。
    static let forgeGlassTint = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? Color.srgb(EarthBluePalette.tintDark, EarthBluePalette.tintAlpha)
            : Color.srgb(EarthBluePalette.tintLight, EarthBluePalette.tintAlpha)
    }
}

// MARK: - 单层玻璃

/// 单层玻璃背景：macOS 26 用 NSGlassEffectView（Liquid Glass），13–25 回退
/// NSVisualEffectView；开启"减少透明度"时用实底。不叠任何实色层与渐变层。
struct GlassSurface: View {
    var cornerRadius: CGFloat = 0
    /// 主窗口与弹出面板都用系统玻璃；仅在需要更轻的材质时关掉。
    var usesSystemGlass = true
    /// 旧系统选中态仅调整同一层材质的厚度，不额外叠实色高亮。
    var highlighted = false

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.displayScale) private var displayScale

    private var edgeInset: CGFloat {
        if #available(macOS 26.0, *), usesSystemGlass, !reduceTransparency {
            return max(1, 1 / max(displayScale, 1))
        }
        return 0
    }

    var body: some View {
        ZStack {
            if reduceTransparency {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.glassOpaque)
                    .overlay {
                        if cornerRadius > 0 {
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .strokeBorder(highlighted ? Color.accentText : Color.hairline,
                                              lineWidth: highlighted ? 1.5 : 1 / max(displayScale, 1))
                        }
                    }
            } else if usesSystemGlass {
                // Put the native rim outside the visible surface instead of leaving
                // a transparent gap around the window or adding a covering stroke.
                GlassBackground(cornerRadius: cornerRadius == 0 ? 0 : cornerRadius + edgeInset,
                                tintColor: .forgeGlassTint)
                    .padding(-edgeInset)
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(highlighted ? AnyShapeStyle(.thinMaterial) : AnyShapeStyle(.ultraThinMaterial))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - 系统玻璃承载视图（macOS 26 NSGlassEffectView，13–25 回退 NSVisualEffectView）

struct GlassBackground: NSViewRepresentable {
    var cornerRadius: CGFloat = 16
    var tintColor: NSColor?

    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: .zero)
            glass.cornerRadius = cornerRadius
            glass.style = .regular
            glass.tintColor = tintColor
            let container = NSView(frame: .zero)
            glass.contentView = container
            return glass
        }
        let visual = NSVisualEffectView(frame: .zero)
        visual.material = .popover
        visual.blendingMode = .behindWindow
        visual.state = .active
        visual.wantsLayer = true
        visual.layer?.cornerRadius = cornerRadius
        visual.layer?.masksToBounds = true
        return visual
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if #available(macOS 26.0, *), let glass = nsView as? NSGlassEffectView {
            glass.cornerRadius = cornerRadius
            glass.tintColor = tintColor
        }
    }
}

/// 原生玻璃的轮廓占用约一个逻辑点，Retina 上只裁一个物理像素仍会留暗边。
/// 只裁材质边缘，保留内容布局、命中区域与原生玻璃切换。
private struct GlassEdgeClip<GlassShape: InsettableShape>: ViewModifier {
    let shape: GlassShape
    @Environment(\.displayScale) private var displayScale

    func body(content: Content) -> some View {
        content.clipShape(shape.inset(by: max(1, 1 / max(displayScale, 1))))
    }
}

extension View {
    func clipGlassEdge<GlassShape: InsettableShape>(in shape: GlassShape) -> some View {
        modifier(GlassEdgeClip(shape: shape))
    }
}
