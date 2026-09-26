import AppKit
import SwiftUI

// MARK: - 设计基调「Fjord」
// 单层液态玻璃 + 冷青蓝强调色，跟随系统浅色/深色外观。
//
// 规则：
// - 玻璃只有一层（GlassSurface），任何不透明色块都不要叠在玻璃上，否则模糊
//   与折射会被盖住，看起来就像"液态玻璃没生效"。
// - 卡片、行、按钮的底色用 surface1/2/3，描边用 hairline；它们在浅色与深色
//   外观下分别取值，不要再写 Color.white.opacity(x)。
// - 强调色只用于选中态、主按钮与关键数值；状态色用 success/warning/danger。

/// Fjord 配色的原始值：token 与对比度测试共用同一份数据。
enum FjordPalette {
    static let accentDark: UInt32 = 0x5AB0F2
    static let accentLight: UInt32 = 0x1E88D6
    static let accentTextDark: UInt32 = 0x8CCBFF
    static let accentTextLight: UInt32 = 0x176AA8
    static let onAccentDark: UInt32 = 0x0B1B2B
    static let onAccentLight: UInt32 = 0xFFFFFF
    /// 玻璃着色在典型后景（深色桌面 / 浅色桌面）上的等效实底，用于对比度估算。
    static let glassDark: UInt32 = 0x14181F
    static let glassLight: UInt32 = 0xF4F6F9
    static let successDark: UInt32 = 0x3DCC91
    static let successLight: UInt32 = 0x1F9D6A
    static let warningDark: UInt32 = 0xF2B23F
    static let warningLight: UInt32 = 0xB97A12
    static let dangerDark: UInt32 = 0xF0616B
    static let dangerLight: UInt32 = 0xD23F4B

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

    private static func srgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: alpha)
    }

    // 强调色
    /// 主强调色：选中态、主按钮底色、进度。
    static let accent = adaptive(light: srgb(FjordPalette.accentLight), dark: srgb(FjordPalette.accentDark))
    /// 强调色文字：在玻璃上保持 ≥ 4.5:1 对比。
    static let accentText = adaptive(light: srgb(FjordPalette.accentTextLight), dark: srgb(FjordPalette.accentTextDark))
    /// 主按钮上的文字。
    static let onAccent = adaptive(light: srgb(FjordPalette.onAccentLight), dark: srgb(FjordPalette.onAccentDark))

    // 玻璃与表面
    /// 玻璃着色：淡到能看见后方内容的模糊与折射。
    static let glassTint = adaptive(light: srgb(0xF4F6F9, 0.50), dark: srgb(0x0E1218, 0.40))
    /// 减少透明度时的实底。
    static let glassOpaque = adaptive(light: srgb(FjordPalette.glassLight), dark: srgb(FjordPalette.glassDark))
    /// 卡片 / 行底色三级。
    static let surface1 = adaptive(light: NSColor.white.withAlphaComponent(0.45),
                                   dark: NSColor.white.withAlphaComponent(0.05))
    static let surface2 = adaptive(light: NSColor.white.withAlphaComponent(0.62),
                                   dark: NSColor.white.withAlphaComponent(0.08))
    static let surface3 = adaptive(light: NSColor.white.withAlphaComponent(0.80),
                                   dark: NSColor.white.withAlphaComponent(0.12))
    /// 开关关闭态的轨道与滑块。
    static let trackOff = adaptive(light: NSColor.black.withAlphaComponent(0.14),
                                   dark: NSColor.white.withAlphaComponent(0.12))
    static let thumbOff = adaptive(light: .white, dark: NSColor.white.withAlphaComponent(0.82))
    /// 描边 / 分隔线。
    static let hairline = adaptive(light: NSColor.black.withAlphaComponent(0.08),
                                   dark: NSColor.white.withAlphaComponent(0.10))

    // 状态色
    static let success = adaptive(light: srgb(FjordPalette.successLight), dark: srgb(FjordPalette.successDark))
    static let warning = adaptive(light: srgb(FjordPalette.warningLight), dark: srgb(FjordPalette.warningDark))
    static let danger = adaptive(light: srgb(FjordPalette.dangerLight), dark: srgb(FjordPalette.dangerDark))

    // 兼容别名：旧代码里的 mole* 名称直接映射到新 token，避免一次性改 100+ 处。
    static let moleAccent = accent
    static let moleAccentText = accentText
    static let moleOnAccent = onAccent
    static let moleGlassBase = glassOpaque
}

extension NSColor {
    /// GlassSurface 传给 NSGlassEffectView 的着色（NSColor 版本，随外观变化）。
    static let forgeGlassTint = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0x0E / 255, green: 0x12 / 255, blue: 0x18 / 255, alpha: 0.40)
            : NSColor(srgbRed: 0xF4 / 255, green: 0xF6 / 255, blue: 0xF9 / 255, alpha: 0.50)
    }
}

// MARK: - 单层玻璃

/// 单层玻璃背景：macOS 26 用 NSGlassEffectView（Liquid Glass），13–25 回退
/// NSVisualEffectView；开启"减少透明度"时用实底。不叠任何实色层与渐变层。
struct GlassSurface: View {
    var cornerRadius: CGFloat = 0
    /// 主窗口与弹出面板都用系统玻璃；仅在需要更轻的材质时关掉。
    var usesSystemGlass = true

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            if reduceTransparency {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.glassOpaque)
            } else if usesSystemGlass {
                GlassBackground(cornerRadius: cornerRadius, tintColor: .forgeGlassTint)
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            if cornerRadius > 0 {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.hairline, lineWidth: 1)
            }
        }
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
        visual.layer?.borderWidth = 1
        visual.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
        return visual
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if #available(macOS 26.0, *), let glass = nsView as? NSGlassEffectView {
            glass.cornerRadius = cornerRadius
            glass.tintColor = tintColor
        }
    }
}
