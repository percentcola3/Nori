import AppKit
import CoreGraphics
import Foundation

// 截图美化预设：背景 + 相框 + 画幅比例，一键得到可直接分享的图。
// 这里只放与 SwiftUI 无关的模型、布局和导出编码，方便单独编译做测试；
// 渲染在 Views/ScreenshotEditorView.swift。

struct PresetColor: Equatable, Hashable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// `0xRRGGBB`
    init(hex: UInt32, alpha: Double = 1) {
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
        self.alpha = alpha
    }

    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

enum PresetBackground: Equatable, Hashable {
    /// 无背景：导出 PNG 时保留透明。
    case transparent
    case solid(PresetColor)
    /// 对角线性渐变；`angle` 为角度，0 = 从左到右，90 = 从上到下。
    case linear([PresetColor], angle: Double)
    /// 3×3 网格渐变（9 个颜色，逐行）；系统低于 macOS 15 时退化为线性渐变。
    case mesh([PresetColor])

    /// 网格渐变的线性回退使用四角颜色。
    var linearFallbackColors: [PresetColor] {
        switch self {
        case .transparent: return []
        case .solid(let color): return [color, color]
        case .linear(let colors, _): return colors
        case .mesh(let colors):
            guard colors.count == 9 else { return colors }
            return [colors[0], colors[4], colors[8]]
        }
    }

    var isTransparent: Bool { self == .transparent }
}

enum PresetFrameStyle: String, CaseIterable, Hashable {
    /// 只有截图本身（可带阴影）。
    case none
    /// macOS 窗口：标题栏 + 红黄绿三点。
    case macWindow
    /// 圆角卡片：无标题栏，细边框。
    case roundedCard
    /// iPhone 外壳：机身 + 灵动岛 + 侧键，截图完整落在屏幕内。
    case iphone

    var l10nKey: String { "shot.frame.\(rawValue)" }
    var icon: String {
        switch self {
        case .none: return "photo"
        case .macWindow: return "macwindow"
        case .roundedCard: return "rectangle.inset.filled"
        case .iphone: return "iphone"
        }
    }
}

enum PresetFrameAppearance: String, Hashable {
    case light, dark
}

enum PresetAspect: String, CaseIterable, Hashable {
    case free, square, wide16x9, portrait3x4, story9x16

    /// 宽 / 高；`free` 跟随内容。
    var ratio: CGFloat? {
        switch self {
        case .free: return nil
        case .square: return 1
        case .wide16x9: return 16.0 / 9.0
        case .portrait3x4: return 3.0 / 4.0
        case .story9x16: return 9.0 / 16.0
        }
    }

    var l10nKey: String { "shot.aspect.\(rawValue)" }
    var icon: String {
        switch self {
        case .free: return "arrow.up.left.and.arrow.down.right"
        case .square: return "square"
        case .wide16x9: return "rectangle"
        case .portrait3x4: return "rectangle.portrait"
        case .story9x16: return "iphone"
        }
    }
}

struct ScreenshotPreset: Identifiable, Equatable, Hashable {
    let id: String
    let background: PresetBackground
    let frame: PresetFrameStyle
    let frameAppearance: PresetFrameAppearance
    let aspect: PresetAspect
    /// 四周留白 = 内容宽度 × paddingRatio。
    let paddingRatio: CGFloat
    let showsShadow: Bool

    var l10nKey: String { "shot.preset.\(id)" }

    init(id: String, background: PresetBackground,
         frame: PresetFrameStyle = .macWindow,
         frameAppearance: PresetFrameAppearance = .dark,
         aspect: PresetAspect = .free,
         paddingRatio: CGFloat = 0.06,
         showsShadow: Bool = true) {
        self.id = id
        self.background = background
        self.frame = frame
        self.frameAppearance = frameAppearance
        self.aspect = aspect
        self.paddingRatio = paddingRatio
        self.showsShadow = showsShadow
    }

    static let defaultID = "aurora"

    /// 内置预设。顺序即预设条顺序；`plain` 永远第一个，表示"不美化"。
    static let builtIn: [ScreenshotPreset] = [
        ScreenshotPreset(id: "plain", background: .transparent, frame: .none,
                         paddingRatio: 0, showsShadow: false),
        ScreenshotPreset(id: "aurora", background: .mesh([
            PresetColor(hex: 0x5B3FD9), PresetColor(hex: 0x3D7BF0), PresetColor(hex: 0x27C4C1),
            PresetColor(hex: 0x7A3FD1), PresetColor(hex: 0x4F6BE8), PresetColor(hex: 0x2DB5A6),
            PresetColor(hex: 0x9C4DD8), PresetColor(hex: 0x6156E0), PresetColor(hex: 0x33A3B8),
        ])),
        ScreenshotPreset(id: "sunset", background: .linear(
            [PresetColor(hex: 0xFF6A5C), PresetColor(hex: 0xFF9A5A), PresetColor(hex: 0xFFD166)],
            angle: 45)),
        ScreenshotPreset(id: "ocean", background: .linear(
            [PresetColor(hex: 0x1D4ED8), PresetColor(hex: 0x2F80ED), PresetColor(hex: 0x5AD1F5)],
            angle: 45)),
        ScreenshotPreset(id: "mint", background: .linear(
            [PresetColor(hex: 0x0FA37A), PresetColor(hex: 0x3DD6A3), PresetColor(hex: 0xB2F5E0)],
            angle: 45), frameAppearance: .light),
        ScreenshotPreset(id: "candy", background: .mesh([
            PresetColor(hex: 0xFF9AC4), PresetColor(hex: 0xFFB3D1), PresetColor(hex: 0xFFD6A5),
            PresetColor(hex: 0xC9A7F5), PresetColor(hex: 0xF7B7E3), PresetColor(hex: 0xFFC8A2),
            PresetColor(hex: 0xA5C8FF), PresetColor(hex: 0xD3B8F7), PresetColor(hex: 0xFFE0B5),
        ]), frame: .roundedCard, frameAppearance: .light),
        ScreenshotPreset(id: "graphite", background: .linear(
            [PresetColor(hex: 0x23262D), PresetColor(hex: 0x3A3F4A), PresetColor(hex: 0x5C6170)],
            angle: 45)),
        ScreenshotPreset(id: "paper", background: .solid(PresetColor(hex: 0xF4F1EA)),
                         frame: .roundedCard, frameAppearance: .light),
        ScreenshotPreset(id: "midnight", background: .mesh([
            PresetColor(hex: 0x0B1020), PresetColor(hex: 0x141B3A), PresetColor(hex: 0x0B1020),
            PresetColor(hex: 0x1B2450), PresetColor(hex: 0x2B2F7A), PresetColor(hex: 0x141B3A),
            PresetColor(hex: 0x0B1020), PresetColor(hex: 0x1B2450), PresetColor(hex: 0x0B1020),
        ])),
        ScreenshotPreset(id: "frame", background: .transparent, frame: .macWindow,
                         paddingRatio: 0.04),
        ScreenshotPreset(id: "iphone", background: .transparent, frame: .iphone,
                         paddingRatio: 0.05),
    ]

    static func builtIn(id: String) -> ScreenshotPreset? {
        builtIn.first { $0.id == id }
    }
}

/// 当前编辑器里的组合：预设 + 可临时覆盖的相框/比例。
struct ScreenshotComposition: Equatable {
    var preset: ScreenshotPreset
    var frame: PresetFrameStyle
    var aspect: PresetAspect

    init(preset: ScreenshotPreset) {
        self.preset = preset
        frame = preset.frame
        aspect = preset.aspect
    }

    init(preset: ScreenshotPreset, frame: PresetFrameStyle, aspect: PresetAspect) {
        self.preset = preset
        self.frame = frame
        self.aspect = aspect
    }

    /// 切换预设时相框与比例回到预设默认值。
    mutating func select(_ newPreset: ScreenshotPreset) {
        preset = newPreset
        frame = newPreset.frame
        aspect = newPreset.aspect
    }

    /// 是否等价于"原图直出"。
    var isPlain: Bool {
        preset.background.isTransparent && frame == .none && aspect == .free
    }
}

/// 布局结果：所有尺寸与传入的 `contentSize` 同一坐标系（预览用点，导出用像素）。
struct PresetLayout: Equatable {
    /// 整张输出图的尺寸。
    let canvasSize: CGSize
    /// 相框（窗口卡片 / iPhone 机身）的位置，包含标题栏与边框。
    let cardRect: CGRect
    /// 截图内容在画布中的位置。
    let contentRect: CGRect
    let padding: CGFloat
    let titleBarHeight: CGFloat
    let cornerRadius: CGFloat
    /// 相框细节（三点、边框、阴影）的缩放系数，随内容分辨率变化。
    let chromeScale: CGFloat
    // iPhone 外壳（其余相框全为 0 / .zero）
    /// 屏幕四周的机身边框；上边框加高以容纳灵动岛。
    let bezelTop: CGFloat
    let bezelSide: CGFloat
    let bezelBottom: CGFloat
    /// 机身外轮廓与屏幕内容的圆角。
    let bodyCornerRadius: CGFloat
    let screenCornerRadius: CGFloat
    /// 侧键凸出机身的深度，留白至少要盖住它。
    let buttonProtrusion: CGFloat
    /// 灵动岛（画布坐标），完全落在上边框内、不遮挡内容。
    let islandRect: CGRect

    static func compute(contentSize: CGSize, composition: ScreenshotComposition) -> PresetLayout {
        let preset = composition.preset
        let width = max(1, contentSize.width)
        let height = max(1, contentSize.height)
        // 以 1000pt 宽为基准缩放相框细节，导出 2x 时线条与点仍成比例。
        let chromeScale = min(4, max(0.5, width / 1000))
        let isPhone = composition.frame == .iphone
        let bezelSide = isPhone ? (55 * chromeScale).rounded() : 0
        let bezelTop = isPhone ? (110 * chromeScale).rounded() : 0
        let bezelBottom = bezelSide
        let buttonProtrusion = isPhone ? (16 * chromeScale).rounded() : 0
        let padding = max((preset.paddingRatio * width).rounded(), buttonProtrusion)
        let titleBarHeight: CGFloat = composition.frame == .macWindow
            ? (30 * chromeScale).rounded() : 0
        let cornerRadius: CGFloat = composition.frame == .none || isPhone
            ? 0 : (14 * chromeScale).rounded()

        let cardSize = CGSize(width: width + bezelSide * 2,
                              height: height + titleBarHeight + bezelTop + bezelBottom)
        var canvas = CGSize(width: cardSize.width + padding * 2,
                            height: cardSize.height + padding * 2)
        if let ratio = composition.aspect.ratio {
            // 只放大画布，绝不裁切内容。
            if canvas.width / canvas.height < ratio {
                canvas.width = (canvas.height * ratio).rounded()
            } else {
                canvas.height = (canvas.width / ratio).rounded()
            }
        }
        let cardOrigin = CGPoint(x: ((canvas.width - cardSize.width) / 2).rounded(),
                                 y: ((canvas.height - cardSize.height) / 2).rounded())
        let cardRect = CGRect(origin: cardOrigin, size: cardSize)
        let contentRect = CGRect(x: cardRect.minX + bezelSide,
                                 y: cardRect.minY + titleBarHeight + bezelTop,
                                 width: width, height: height)
        let bodyCornerRadius = isPhone ? (0.145 * cardSize.width).rounded() : 0
        // 屏幕圆角 = 机身圆角内缩一个边框；再留一条黑色屏幕包边。
        let screenRim = (3 * chromeScale).rounded()
        let screenCornerRadius = isPhone
            ? max(0, bodyCornerRadius - bezelSide - screenRim) : 0
        let islandWidth = min((300 * chromeScale).rounded(), width * 0.9)
        let islandHeight = min((72 * chromeScale).rounded(), bezelTop)
        let islandRect = isPhone
            ? CGRect(x: cardRect.midX - islandWidth / 2,
                     y: cardRect.minY + ((bezelTop - islandHeight) / 2).rounded(),
                     width: islandWidth, height: islandHeight)
            : .zero
        return PresetLayout(canvasSize: canvas, cardRect: cardRect, contentRect: contentRect,
                            padding: padding, titleBarHeight: titleBarHeight,
                            cornerRadius: cornerRadius, chromeScale: chromeScale,
                            bezelTop: bezelTop, bezelSide: bezelSide, bezelBottom: bezelBottom,
                            bodyCornerRadius: bodyCornerRadius,
                            screenCornerRadius: screenCornerRadius,
                            buttonProtrusion: buttonProtrusion, islandRect: islandRect)
    }
}

// MARK: - 导出选项

enum ScreenshotExportFormat: String, CaseIterable {
    case png, jpeg

    var fileExtension: String { rawValue }
    var l10nKey: String { "shot.export.\(rawValue)" }
}

enum ScreenshotExportScale: Int, CaseIterable {
    case standard = 1
    case retina = 2

    var l10nKey: String { "shot.export.scale\(rawValue)x" }
}

struct ScreenshotExportOptions: Equatable {
    var format: ScreenshotExportFormat = .png
    var scale: ScreenshotExportScale = .standard
    var jpegQuality: Double = 0.9
}

enum ScreenshotExporter {
    /// 把渲染结果编码为文件数据。JPEG 没有透明通道，先铺白底。
    static func encode(_ image: NSImage, options: ScreenshotExportOptions) -> Data? {
        guard let tiff = image.tiffRepresentation,
              var rep = NSBitmapImageRep(data: tiff) else { return nil }
        switch options.format {
        case .png:
            return rep.representation(using: .png, properties: [:])
        case .jpeg:
            if rep.hasAlpha, let flattened = flattenOntoWhite(rep) { rep = flattened }
            return rep.representation(using: .jpeg,
                                      properties: [.compressionFactor: options.jpegQuality])
        }
    }

    static func defaultFileName(format: ScreenshotExportFormat, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return "Screenshot-\(formatter.string(from: date)).\(format.fileExtension)"
    }

    private static func flattenOntoWhite(_ rep: NSBitmapImageRep) -> NSBitmapImageRep? {
        let size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        guard let flattened = NSBitmapImageRep(bitmapDataPlanes: nil,
                                               pixelsWide: rep.pixelsWide,
                                               pixelsHigh: rep.pixelsHigh,
                                               bitsPerSample: 8, samplesPerPixel: 3,
                                               hasAlpha: false, isPlanar: false,
                                               colorSpaceName: .deviceRGB,
                                               bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: flattened) else { return nil }
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        rep.draw(in: NSRect(origin: .zero, size: size))
        context.flushGraphics()
        return flattened
    }
}

// MARK: - 偏好

/// 记住上次使用的预设、相框、比例和导出选项。
struct ScreenshotPreferences {
    private let defaults: UserDefaults
    private enum Key {
        static let preset = "screenshot.preset"
        static let frame = "screenshot.frame"
        static let aspect = "screenshot.aspect"
        static let format = "screenshot.export.format"
        static let scale = "screenshot.export.scale"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadComposition() -> ScreenshotComposition {
        let preset = defaults.string(forKey: Key.preset).flatMap(ScreenshotPreset.builtIn(id:))
            ?? ScreenshotPreset.builtIn(id: ScreenshotPreset.defaultID)
            ?? ScreenshotPreset.builtIn[0]
        var composition = ScreenshotComposition(preset: preset)
        if let raw = defaults.string(forKey: Key.frame), let frame = PresetFrameStyle(rawValue: raw) {
            composition.frame = frame
        }
        if let raw = defaults.string(forKey: Key.aspect), let aspect = PresetAspect(rawValue: raw) {
            composition.aspect = aspect
        }
        return composition
    }

    func save(_ composition: ScreenshotComposition) {
        defaults.set(composition.preset.id, forKey: Key.preset)
        defaults.set(composition.frame.rawValue, forKey: Key.frame)
        defaults.set(composition.aspect.rawValue, forKey: Key.aspect)
    }

    func loadExportOptions() -> ScreenshotExportOptions {
        var options = ScreenshotExportOptions()
        if let raw = defaults.string(forKey: Key.format),
           let format = ScreenshotExportFormat(rawValue: raw) {
            options.format = format
        }
        if let scale = ScreenshotExportScale(rawValue: defaults.integer(forKey: Key.scale)) {
            options.scale = scale
        }
        return options
    }

    func save(_ options: ScreenshotExportOptions) {
        defaults.set(options.format.rawValue, forKey: Key.format)
        defaults.set(options.scale.rawValue, forKey: Key.scale)
    }
}
