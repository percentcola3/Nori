import SwiftUI
import AppKit
import CoreImage
import UniformTypeIdentifiers

// MARK: - 数据模型

enum EditorTool: String, CaseIterable, Identifiable {
    case rect, ellipse, arrow, pen, text, mosaic
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .rect: return "rectangle"
        case .ellipse: return "circle"
        case .arrow: return "arrow.up.right"
        case .pen: return "pencil.tip"
        case .text: return "textformat"
        case .mosaic: return "squareshape.split.2x2"
        }
    }
}

/// 标注笔画：坐标为归一化（0~1，相对原图），导出与显示尺寸解耦。
struct Stroke: Identifiable {
    enum Kind { case rect, ellipse, arrow, pen, mosaic, text }
    let id = UUID()
    let kind: Kind
    let colorIndex: Int
    var points: [CGPoint]
    var text: String = ""
}

private let editorColors: [Color] = [
    Color(red: 1.0, green: 0.84, blue: 0.18),
    .red, .blue, .black, .white
]

// MARK: - 编辑器视图

struct ScreenshotEditorView: View {
    let image: NSImage
    let onClose: () -> Void

    @State private var strokes: [Stroke] = []
    @State private var draft: Stroke?
    @State private var tool: EditorTool = .rect
    @State private var colorIndex = 0
    @State private var composition: ScreenshotComposition
    @State private var exportOptions: ScreenshotExportOptions
    @State private var showCompositionOptions = false
    @State private var pendingTextAt: CGPoint?
    @State private var pendingTextInput = ""
    @State private var feedbackKey: String?
    @ObservedObject private var l10n = L10n.shared

    private let preferences: ScreenshotPreferences

    init(image: NSImage, preferences: ScreenshotPreferences = ScreenshotPreferences(),
         onClose: @escaping () -> Void) {
        self.image = image
        self.onClose = onClose
        self.preferences = preferences
        _composition = State(initialValue: preferences.loadComposition())
        _exportOptions = State(initialValue: preferences.loadExportOptions())
    }

    private static let previewMax = CGSize(width: 1100, height: 620)

    /// 截图在预览里的尺寸：连同预设的留白、标题栏和画幅一起放进预览区，
    /// 比例越"高"的画幅，截图本身缩得越小。
    private var displaySize: CGSize {
        let maxW = Self.previewMax.width
        let maxH = Self.previewMax.height
        let size = image.size
        var scale = min(1, maxW / size.width, maxH / size.height)
        // 两轮迭代足够：布局尺寸对内容尺寸近似线性。
        for _ in 0..<2 {
            let content = CGSize(width: size.width * scale, height: size.height * scale)
            let canvas = PresetLayout.compute(contentSize: content, composition: composition).canvasSize
            let fit = min(1, maxW / canvas.width, maxH / canvas.height)
            if fit >= 0.999 { break }
            scale *= fit
        }
        return CGSize(width: floor(size.width * scale), height: floor(size.height * scale))
    }

    private var previewLayout: PresetLayout {
        PresetLayout.compute(contentSize: displaySize, composition: composition)
    }

    private var exportSize: CGSize {
        image.representations
            .map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) }
            .filter { $0.width > 0 && $0.height > 0 }
            .max { $0.width * $0.height < $1.width * $1.height }
            ?? image.size
    }

    var body: some View {
        VStack(spacing: 8) {
            toolBar
            canvasArea
            presetBar
            actionBar
        }
        .padding(12)
        .frame(minWidth: max(640, previewLayout.canvasSize.width + 24),
               idealWidth: max(640, previewLayout.canvasSize.width + 24),
               minHeight: previewLayout.canvasSize.height + 190)
        .onChange(of: composition) { value in preferences.save(value) }
        .onChange(of: exportOptions) { value in preferences.save(value) }
    }

    // MARK: 工具条

    private var toolBar: some View {
        HStack(spacing: 6) {
            ForEach(EditorTool.allCases) { t in
                Button {
                    tool = t
                } label: {
                    Image(systemName: t.icon)
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 28, height: 24)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(tool == t ? AnyShapeStyle(Color.moleAccent.opacity(0.35))
                                            : AnyShapeStyle(Color.surface2)))
                }
                .buttonStyle(.plain)
                .help(l10n.t("tool.\(t.rawValue)"))
            }
            Divider().frame(height: 18)
            ForEach(editorColors.indices, id: \.self) { index in
                Circle()
                    .fill(editorColors[index])
                    .frame(width: 16, height: 16)
                    .overlay(Circle().strokeBorder(
                        colorIndex == index ? Color.white : Color.white.opacity(0.25),
                        lineWidth: colorIndex == index ? 2 : 1))
                    .onTapGesture { colorIndex = index }
                    .padding(2)
            }
            Divider().frame(height: 18)
            Button {
                strokes.removeLast()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 28, height: 24)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.surface2))
            }
            .buttonStyle(.plain)
            .disabled(strokes.isEmpty)
            .help(l10n.t("shot.undo"))
            Spacer()
        }
    }

    // MARK: 画布（含模板）

    /// 截图 + 标注层（归一化坐标渲染到当前显示尺寸）。
    private var editorCanvas: some View {
        ZStack {
            Image(nsImage: image)
                .resizable()
                .frame(width: displaySize.width, height: displaySize.height)
            AnnotationCanvas(strokes: strokes + (draft.map { [$0] } ?? []),
                             baseImage: image,
                             size: displaySize)
                .frame(width: displaySize.width, height: displaySize.height)
                .contentShape(Rectangle())
                .gesture(dragGesture)
        }
        .overlay(pendingTextOverlay)
    }

    private var canvasArea: some View {
        Group {
            if composition.isPlain {
                editorCanvas
            } else {
                PresetFrameView(composition: composition, contentSize: displaySize) {
                    editorCanvas
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard tool != .text else { return }
                let p = normalized(value.location)
                if draft == nil {
                    guard tool != .mosaic || strokes.count + 1 <= 400 else { return }
                    draft = Stroke(kind: kindFor(tool), colorIndex: colorIndex, points: [p])
                } else {
                    draft?.points.append(p)
                }
            }
            .onEnded { value in
                guard tool != .text else {
                    pendingTextAt = normalized(value.location)
                    pendingTextInput = ""
                    return
                }
                if var stroke = draft {
                    stroke.points.append(normalized(value.location))
                    // 单击（矩形/椭圆）给最小尺寸，避免零面积不可见
                    if stroke.points.count == 2, stroke.kind == .rect || stroke.kind == .ellipse {
                        stroke.points[1] = CGPoint(x: min(1, stroke.points[0].x + 0.05),
                                                   y: min(1, stroke.points[0].y + 0.05))
                    }
                    strokes.append(stroke)
                }
                draft = nil
            }
    }

    private func kindFor(_ tool: EditorTool) -> Stroke.Kind {
        switch tool {
        case .rect: return .rect
        case .ellipse: return .ellipse
        case .arrow: return .arrow
        case .pen: return .pen
        case .mosaic: return .mosaic
        case .text: return .text
        }
    }

    private func normalized(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(1, max(0, point.x / displaySize.width)),
                y: min(1, max(0, point.y / displaySize.height)))
    }

    /// 文字工具：点击位置弹出输入框。
    @ViewBuilder
    private var pendingTextOverlay: some View {
        if let at = pendingTextAt {
            HStack(spacing: 6) {
                TextField(l10n.t("tool.text"), text: $pendingTextInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .font(.system(size: 13))
                Button(l10n.t("common.done")) {
                    if !pendingTextInput.isEmpty {
                        strokes.append(Stroke(kind: .text, colorIndex: colorIndex,
                                              points: [at], text: pendingTextInput))
                    }
                    pendingTextAt = nil
                    pendingTextInput = ""
                }
                .buttonStyle(PrimaryButtonStyle())
                .controlSize(.small)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(.ultraThinMaterial))
            .offset(x: at.x * displaySize.width,
                    y: at.y * displaySize.height + 12)
        }
    }

    // MARK: 预设条

    private var presetBar: some View {
        HStack(spacing: 8) {
            Text(l10n.t("shot.preset"))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(ScreenshotPreset.builtIn) { preset in
                        Button {
                            composition.select(preset)
                        } label: {
                            VStack(spacing: 3) {
                                PresetThumbnail(preset: preset,
                                                selected: composition.preset.id == preset.id)
                                Text(l10n.t(preset.l10nKey))
                                    .font(.system(size: 8.5, weight: composition.preset.id == preset.id ? .semibold : .regular))
                                    .foregroundStyle(composition.preset.id == preset.id
                                                     ? Color.moleAccentText : Color.secondary)
                                    .lineLimit(1)
                            }
                            .frame(width: 60)
                        }
                        .buttonStyle(.plain)
                        .help(l10n.t(preset.l10nKey))
                    }
                }
                .padding(.vertical, 2)
            }
            Button {
                showCompositionOptions.toggle()
            } label: {
                Label(l10n.t("shot.options"), systemImage: "slider.horizontal.3")
            }
            .buttonStyle(SecondaryButtonStyle())
            .popover(isPresented: $showCompositionOptions, arrowEdge: .bottom) {
                compositionOptions
            }
        }
    }

    /// 相框与画幅覆盖：对当前预设临时生效，切换预设后恢复预设默认值。
    private var compositionOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(l10n.t("shot.frame"))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Picker("", selection: $composition.frame) {
                ForEach(PresetFrameStyle.allCases, id: \.self) { style in
                    Label(l10n.t(style.l10nKey), systemImage: style.icon).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(l10n.t("shot.aspect"))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Picker("", selection: $composition.aspect) {
                ForEach(PresetAspect.allCases, id: \.self) { aspect in
                    Text(l10n.t(aspect.l10nKey)).tag(aspect)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(14)
        .frame(width: 320)
    }

    // MARK: 操作条

    private var actionBar: some View {
        HStack(spacing: 8) {
            Button {
                showFeedback(copyToPasteboard() ? "shot.copied" : "shot.failed")
            } label: {
                Label(l10n.t("common.copy"), systemImage: "doc.on.doc")
            }
            .buttonStyle(SecondaryButtonStyle())
            Button {
                showFeedback(saveToDownloads() ? "shot.saved" : "shot.failed")
            } label: {
                Label(l10n.t("shot.save"), systemImage: "square.and.arrow.down")
            }
            .buttonStyle(SecondaryButtonStyle())
            Button {
                saveAs()
            } label: {
                Label(l10n.t("shot.saveAs"), systemImage: "folder")
            }
            .buttonStyle(SecondaryButtonStyle())
            Divider().frame(height: 18)
            Picker("", selection: $exportOptions.scale) {
                ForEach(ScreenshotExportScale.allCases, id: \.self) { scale in
                    Text(l10n.t(scale.l10nKey)).tag(scale)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 96)
            .help(l10n.t("shot.export.scale"))
            Picker("", selection: $exportOptions.format) {
                ForEach(ScreenshotExportFormat.allCases, id: \.self) { format in
                    Text(l10n.t(format.l10nKey)).tag(format)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 80)
            .help(l10n.t("shot.export.format"))
            if let feedbackKey {
                Text(l10n.t(feedbackKey))
                    .font(.system(size: 10))
                    .foregroundStyle(feedbackKey == "shot.failed" ? Color.orange : Color.moleAccentText)
            }
            Spacer()
            Button(l10n.t("common.done"), action: onClose)
                .buttonStyle(PrimaryButtonStyle())
        }
    }

    // MARK: 导出

    /// 导出视图 = 与画布一致的渲染（预设或原图）+ 标注层，按原始像素尺寸布局。
    private var exportView: some View {
        let annotated = ZStack {
            Image(nsImage: image)
                .resizable()
                .frame(width: exportSize.width, height: exportSize.height)
            AnnotationCanvas(strokes: strokes, baseImage: image, size: displaySize)
                .frame(width: exportSize.width, height: exportSize.height)
        }
        .frame(width: exportSize.width, height: exportSize.height)
        return Group {
            if composition.isPlain {
                annotated
            } else {
                PresetFrameView(composition: composition, contentSize: exportSize) {
                    annotated
                }
            }
        }
    }

    private func renderExportImage() -> NSImage? {
        let renderer = ImageRenderer(content: exportView)
        // exportView 已按原始像素尺寸布局；scale=1 即原始分辨率，2 用于需要
        // 更锐利相框细节的放大导出。透明背景的预设保留 alpha。
        renderer.scale = CGFloat(exportOptions.scale.rawValue)
        renderer.isOpaque = false
        return renderer.nsImage
    }

    private func copyToPasteboard() -> Bool {
        guard let rendered = renderExportImage(),
              let tiff = rendered.tiffRepresentation else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        var ok = pasteboard.setData(tiff, forType: .tiff)
        // 同时放一份 PNG：多数聊天工具与浏览器优先读取 PNG，透明背景才不会变黑。
        if let png = ScreenshotExporter.encode(rendered, options: ScreenshotExportOptions(format: .png)) {
            ok = pasteboard.setData(png, forType: .png) || ok
        }
        return ok
    }

    private func encodedExport() -> Data? {
        guard let rendered = renderExportImage() else { return nil }
        return ScreenshotExporter.encode(rendered, options: exportOptions)
    }

    private func saveToDownloads() -> Bool {
        guard let data = encodedExport() else { return false }
        let url = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(ScreenshotExporter.defaultFileName(format: exportOptions.format))
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private func saveAs() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = exportOptions.format == .png ? [.png] : [.jpeg]
        panel.nameFieldStringValue = ScreenshotExporter.defaultFileName(format: exportOptions.format)
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = encodedExport() else {
            showFeedback("shot.failed")
            return
        }
        do {
            try data.write(to: url, options: .atomic)
            showFeedback("shot.saved")
        } catch {
            showFeedback("shot.failed")
        }
    }

    private func showFeedback(_ key: String) {
        feedbackKey = key
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if feedbackKey == key { feedbackKey = nil }
        }
    }
}

// MARK: - 标注画布（Canvas 绘制）

struct AnnotationCanvas: View {
    let strokes: [Stroke]
    let baseImage: NSImage
    let size: CGSize

    var body: some View {
        Canvas { context, canvasSize in
            let pixelated = MosaicCache.shared.pixelatedImage(for: baseImage)
            let drawingScale = max(0.5, canvasSize.width / max(1, size.width))
            for stroke in strokes {
                let points = stroke.points.map {
                    CGPoint(x: $0.x * canvasSize.width, y: $0.y * canvasSize.height)
                }
                guard !points.isEmpty else { continue }
                let color = editorColors[stroke.colorIndex % editorColors.count]
                Self.draw(stroke, points: points, color: color,
                          in: &context, canvasSize: canvasSize,
                          drawingScale: drawingScale, pixelated: pixelated)
            }
        }
    }

    private static func draw(_ stroke: Stroke, points: [CGPoint], color: Color,
                             in context: inout GraphicsContext,
                             canvasSize: CGSize, drawingScale: CGFloat,
                             pixelated: CGImage?) {
        switch stroke.kind {
        case .pen:
            var path = Path()
            path.move(to: points[0])
            for p in points.dropFirst() { path.addLine(to: p) }
            context.stroke(path, with: .color(color),
                           style: StrokeStyle(lineWidth: 3 * drawingScale,
                                              lineCap: .round, lineJoin: .round))
        case .rect:
            context.stroke(Path(CGRect(points: points)), with: .color(color),
                           lineWidth: 3 * drawingScale)
        case .ellipse:
            context.stroke(Path(ellipseIn: CGRect(points: points)),
                           with: .color(color), lineWidth: 3 * drawingScale)
        case .arrow:
            guard let start = points.first, let end = points.last else { return }
            var path = Path()
            path.move(to: start)
            path.addLine(to: end)
            context.stroke(path, with: .color(color),
                           style: StrokeStyle(lineWidth: 3 * drawingScale, lineCap: .round))
            let angle = atan2(end.y - start.y, end.x - start.x)
            let head: CGFloat = 12 * drawingScale
            let p1 = CGPoint(x: end.x - head * cos(angle - 0.45),
                             y: end.y - head * sin(angle - 0.45))
            let p2 = CGPoint(x: end.x - head * cos(angle + 0.45),
                             y: end.y - head * sin(angle + 0.45))
            var headPath = Path()
            headPath.move(to: end)
            headPath.addLine(to: p1)
            headPath.addLine(to: p2)
            headPath.closeSubpath()
            context.fill(headPath, with: .color(color))
        case .mosaic:
            guard let pixelated, points.count >= 2 else { return }
            var path = Path()
            path.move(to: points[0])
            for p in points.dropFirst() { path.addLine(to: p) }
            let outline = path.strokedPath(
                StrokeStyle(lineWidth: 22 * drawingScale,
                            lineCap: .round, lineJoin: .round))
            let nsPixelated = NSImage(cgImage: pixelated,
                                      size: NSSize(width: canvasSize.width, height: canvasSize.height))
            let drawContext = context
            drawContext.drawLayer { layer in
                layer.clip(to: outline)
                layer.draw(Image(nsImage: nsPixelated), in: CGRect(origin: .zero, size: canvasSize))
            }
        case .text:
            guard let location = points.first else { return }
            context.draw(Text(stroke.text)
                .font(.system(size: 15 * drawingScale, weight: .semibold))
                .foregroundColor(color), at: location)
        }
    }
}

extension CGRect {
    init(points: [CGPoint]) {
        var minX = CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude
        for p in points {
            minX = Swift.min(minX, p.x)
            minY = Swift.min(minY, p.y)
            maxX = Swift.max(maxX, p.x)
            maxY = Swift.max(maxY, p.y)
        }
        self.init(x: minX, y: minY,
                  width: Swift.max(0, maxX - minX),
                  height: Swift.max(0, maxY - minY))
    }
}

/// 像素化底图缓存（马赛克工具用；按原图指针缓存一份）。
final class MosaicCache {
    static let shared = MosaicCache()
    private var cachedKey: NSObject?
    private var cachedImage: CGImage?

    func pixelatedImage(for image: NSImage) -> CGImage? {
        if cachedKey === image, let cachedImage { return cachedImage }
        guard let tiff = image.tiffRepresentation,
              let source = NSImage(data: tiff)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let ciImage = CIImage(cgImage: source)
        let filter = CIFilter(name: "CIPixellate")
        filter?.setValue(ciImage, forKey: kCIInputImageKey)
        filter?.setValue(14, forKey: kCIInputScaleKey)
        guard let output = filter?.outputImage,
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        cachedKey = image
        cachedImage = cg
        return cg
    }

    func clear() {
        cachedKey = nil
        cachedImage = nil
    }
}



// MARK: - 预设渲染（预览与导出共用）

/// 预设背景：透明 / 纯色 / 线性渐变 / 网格渐变（macOS 15+，否则线性回退）。
struct PresetBackgroundView: View {
    let background: PresetBackground

    var body: some View {
        switch background {
        case .transparent:
            Color.clear
        case .solid(let color):
            Color(nsColor: color.nsColor)
        case .linear(let colors, let angle):
            let (start, end) = Self.gradientPoints(angle: angle)
            LinearGradient(colors: colors.map { Color(nsColor: $0.nsColor) },
                           startPoint: start, endPoint: end)
        case .mesh(let colors):
            meshOrFallback(colors)
        }
    }

    @ViewBuilder
    private func meshOrFallback(_ colors: [PresetColor]) -> some View {
        if #available(macOS 15, *), colors.count == 9 {
            MeshGradient(width: 3, height: 3, points: [
                [0.0, 0.0], [0.5, 0.0], [1.0, 0.0],
                [0.0, 0.5], [0.42, 0.58], [1.0, 0.5],
                [0.0, 1.0], [0.5, 1.0], [1.0, 1.0],
            ], colors: colors.map { Color(nsColor: $0.nsColor) })
        } else {
            let (start, end) = Self.gradientPoints(angle: 45)
            LinearGradient(colors: background.linearFallbackColors.map { Color(nsColor: $0.nsColor) },
                           startPoint: start, endPoint: end)
        }
    }

    /// 0° = 左→右，90° = 上→下，45° = 左上→右下。
    static func gradientPoints(angle: Double) -> (UnitPoint, UnitPoint) {
        let radians = angle * .pi / 180
        let dx = cos(radians) / 2
        let dy = sin(radians) / 2
        return (UnitPoint(x: 0.5 - dx, y: 0.5 - dy), UnitPoint(x: 0.5 + dx, y: 0.5 + dy))
    }
}

/// 预设相框：背景 + 窗口卡片（标题栏三点）/ 圆角卡片 / 无框 + 内容。
struct PresetFrameView<Content: View>: View {
    let composition: ScreenshotComposition
    let contentSize: CGSize
    @ViewBuilder let content: () -> Content

    var body: some View {
        let layout = PresetLayout.compute(contentSize: contentSize, composition: composition)
        ZStack(alignment: .topLeading) {
            PresetBackgroundView(background: composition.preset.background)
                .frame(width: layout.canvasSize.width, height: layout.canvasSize.height)
            card(layout)
                .frame(width: layout.cardRect.width, height: layout.cardRect.height)
                .offset(x: layout.cardRect.minX, y: layout.cardRect.minY)
        }
        .frame(width: layout.canvasSize.width, height: layout.canvasSize.height)
    }

    private var isLight: Bool { composition.preset.frameAppearance == .light }

    private func card(_ layout: PresetLayout) -> some View {
        let shape = RoundedRectangle(cornerRadius: layout.cornerRadius, style: .continuous)
        return VStack(spacing: 0) {
            if composition.frame == .macWindow {
                titleBar(layout)
            }
            content()
                .frame(width: layout.contentRect.width, height: layout.contentRect.height)
        }
        .background(shape.fill(isLight ? Color(white: 0.97) : Color(white: 0.12)))
        .clipShape(shape)
        .overlay(shape.strokeBorder(
            composition.frame == .none ? Color.clear
                : (isLight ? Color.black.opacity(0.10) : Color.white.opacity(0.14)),
            lineWidth: max(1, layout.chromeScale)))
        .shadow(color: .black.opacity(composition.preset.showsShadow ? 0.38 : 0),
                radius: 24 * layout.chromeScale, y: 12 * layout.chromeScale)
    }

    private func titleBar(_ layout: PresetLayout) -> some View {
        let dot = 11 * layout.chromeScale
        return HStack(spacing: 7 * layout.chromeScale) {
            Circle().fill(Color(red: 1.0, green: 0.37, blue: 0.34)).frame(width: dot, height: dot)
            Circle().fill(Color(red: 1.0, green: 0.74, blue: 0.18)).frame(width: dot, height: dot)
            Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.26)).frame(width: dot, height: dot)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12 * layout.chromeScale)
        .frame(width: layout.cardRect.width, height: layout.titleBarHeight)
        .background(isLight ? Color(white: 0.93) : Color(white: 0.16))
    }
}

/// 预设条缩略图：56×36 的背景 + 迷你窗口，直观看出配色与相框。
struct PresetThumbnail: View {
    let preset: ScreenshotPreset
    let selected: Bool

    var body: some View {
        ZStack {
            if preset.background.isTransparent {
                CheckerboardView()
            } else {
                PresetBackgroundView(background: preset.background)
            }
            if preset.frame != .none {
                VStack(spacing: 0) {
                    if preset.frame == .macWindow {
                        HStack(spacing: 2) {
                            Circle().fill(Color(red: 1.0, green: 0.37, blue: 0.34)).frame(width: 3, height: 3)
                            Circle().fill(Color(red: 1.0, green: 0.74, blue: 0.18)).frame(width: 3, height: 3)
                            Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.26)).frame(width: 3, height: 3)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 3)
                        .frame(height: 6)
                        .background(preset.frameAppearance == .light ? Color(white: 0.93) : Color(white: 0.16))
                    }
                    Rectangle().fill(preset.frameAppearance == .light ? Color(white: 0.99) : Color(white: 0.24))
                }
                .frame(width: 36, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
            } else if preset.background.isTransparent {
                Image(systemName: "photo")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 56, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(
            selected ? Color.moleAccentText : Color.white.opacity(0.18),
            lineWidth: selected ? 2 : 1))
    }
}

/// 透明背景的棋盘格提示。
struct CheckerboardView: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 6
            var y: CGFloat = 0
            var row = 0
            while y < size.height {
                var x: CGFloat = 0
                var column = 0
                while x < size.width {
                    let dark = (row + column) % 2 == 0
                    context.fill(Path(CGRect(x: x, y: y, width: cell, height: cell)),
                                 with: .color(Color(white: dark ? 0.30 : 0.42)))
                    x += cell
                    column += 1
                }
                y += cell
                row += 1
            }
        }
    }
}
