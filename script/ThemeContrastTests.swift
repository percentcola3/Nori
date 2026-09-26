import Foundation

@main
struct ThemeContrastTests {
    static func main() {
        func check(_ name: String, _ fg: UInt32, _ bg: UInt32, minimum: Double) {
            let ratio = FjordPalette.contrastRatio(fg, bg)
            precondition(ratio >= minimum, "\(name): contrast \(String(format: "%.2f", ratio)) < \(minimum)")
        }
        // 正文级（4.5:1）：强调色文字与主按钮文字。
        check("accentText on dark glass", FjordPalette.accentTextDark, FjordPalette.glassDark, minimum: 4.5)
        check("accentText on light glass", FjordPalette.accentTextLight, FjordPalette.glassLight, minimum: 4.5)
        check("onAccent on dark accent", FjordPalette.onAccentDark, FjordPalette.accentDark, minimum: 4.5)
        check("onAccent on light accent", FjordPalette.onAccentLight, FjordPalette.accentLight, minimum: 3.0)
        // 状态色作为图标 / 大字（3:1）。
        check("success dark", FjordPalette.successDark, FjordPalette.glassDark, minimum: 3.0)
        check("success light", FjordPalette.successLight, FjordPalette.glassLight, minimum: 3.0)
        check("warning dark", FjordPalette.warningDark, FjordPalette.glassDark, minimum: 3.0)
        check("warning light", FjordPalette.warningLight, FjordPalette.glassLight, minimum: 3.0)
        check("danger dark", FjordPalette.dangerDark, FjordPalette.glassDark, minimum: 3.0)
        check("danger light", FjordPalette.dangerLight, FjordPalette.glassLight, minimum: 3.0)
        // 亮度函数的锚点。
        precondition(abs(FjordPalette.relativeLuminance(0xFFFFFF) - 1) < 0.0001, "white luminance must be 1")
        precondition(FjordPalette.relativeLuminance(0x000000) == 0, "black luminance must be 0")
        precondition(abs(FjordPalette.contrastRatio(0xFFFFFF, 0x000000) - 21) < 0.01, "white/black must be 21:1")
        print("theme contrast ok")
    }
}
