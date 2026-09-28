import Foundation

@main
struct ThemeContrastTests {
    static func main() {
        func check(_ name: String, _ fg: UInt32, _ bg: UInt32, minimum: Double) {
            let ratio = EarthBluePalette.contrastRatio(fg, bg)
            precondition(ratio >= minimum, "\(name): contrast \(String(format: "%.2f", ratio)) < \(minimum)")
        }
        // 正文级（4.5:1）：强调色文字与主按钮文字。
        check("accentText on dark glass", EarthBluePalette.accentTextDark, EarthBluePalette.glassDark, minimum: 4.5)
        check("accentText on light glass", EarthBluePalette.accentTextLight, EarthBluePalette.glassLight, minimum: 4.5)
        check("onAccent on dark accent", EarthBluePalette.onAccentDark, EarthBluePalette.accentDark, minimum: 4.5)
        check("onAccent on light accent", EarthBluePalette.onAccentLight, EarthBluePalette.accentLight, minimum: 3.0)
        // 状态色作为图标 / 大字（3:1）。
        check("success dark", EarthBluePalette.successDark, EarthBluePalette.glassDark, minimum: 3.0)
        check("success light", EarthBluePalette.successLight, EarthBluePalette.glassLight, minimum: 3.0)
        check("warning dark", EarthBluePalette.warningDark, EarthBluePalette.glassDark, minimum: 3.0)
        check("warning light", EarthBluePalette.warningLight, EarthBluePalette.glassLight, minimum: 3.0)
        check("danger dark", EarthBluePalette.dangerDark, EarthBluePalette.glassDark, minimum: 3.0)
        check("danger light", EarthBluePalette.dangerLight, EarthBluePalette.glassLight, minimum: 3.0)
        // 亮度函数的锚点。
        precondition(abs(EarthBluePalette.relativeLuminance(0xFFFFFF) - 1) < 0.0001, "white luminance must be 1")
        precondition(EarthBluePalette.relativeLuminance(0x000000) == 0, "black luminance must be 0")
        precondition(abs(EarthBluePalette.contrastRatio(0xFFFFFF, 0x000000) - 21) < 0.01, "white/black must be 21:1")
        print("theme contrast ok")
    }
}
