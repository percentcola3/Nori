import SwiftUI
import AppKit
import CoreImage
import UniformTypeIdentifiers

// MARK: - 数据模型

enum EditorTool: String, CaseIterable, Identifiable {
    case rect, ellipse, arrow, pen, text, mosaic
    var id: String { rawValue }
    var cursor: NSCursor { self == .text ? .iBeam : .crosshair }
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

/// Derive indices from shape order so moving/resizing keeps them and undo reuses the last index.
enum AnnotationIndexing {
    static func numberedShapes(in strokes: [Stroke]) -> [(number: Int, stroke: Stroke)] {
        strokes.filter { ($0.kind == .rect || $0.kind == .ellipse) && $0.points.count >= 2 }
            .enumerated().map { (number: $0.offset + 1, stroke: $0.element) }
    }

    static func badgeRect(for bounds: CGRect, number: Int, canvasSize: CGSize,
                          drawingScale: CGFloat) -> CGRect {
        let margin = 2 * drawingScale
        let height = min(16 * drawingScale, max(0, canvasSize.height - 2 * margin))
        let width = min(max(16, CGFloat(String(number).count) * 6 + 8) * drawingScale,
                        max(0, canvasSize.width - 2 * margin))
        // Sit just above the upper-left border; clamp at image edges to keep every digit visible.
        return CGRect(x: max(margin, min(bounds.minX + 4 * drawingScale, canvasSize.width - margin - width)),
                      y: max(margin, min(bounds.minY - height - 4 * drawingScale, canvasSize.height - margin - height)),
                      width: width, height: height)
    }
}

/// Shape editing uses a snapshot from drag start, so repeated updates never compound deltas.
enum AnnotationShapeEditing {
    enum Handle: Int, CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
        var horizontal: Int {
            switch self {
            case .topLeft, .bottomLeft, .left: return -1
            case .topRight, .bottomRight, .right: return 1
            default: return 0
            }
        }
        var vertical: Int {
            switch self {
            case .topLeft, .top, .topRight: return -1
            case .bottomLeft, .bottom, .bottomRight: return 1
            default: return 0
            }
        }
        func point(in rect: CGRect) -> CGPoint {
            CGPoint(x: horizontal < 0 ? rect.minX : horizontal > 0 ? rect.maxX : rect.midX,
                    y: vertical < 0 ? rect.minY : vertical > 0 ? rect.maxY : rect.midY)
        }
    }
    struct Target {
        let id: UUID
        let handle: Handle?
        var cursor: NSCursor {
            guard let handle else { return .openHand }
            if handle.horizontal == 0 { return .resizeUpDown }
            if handle.vertical == 0 { return .resizeLeftRight }
            return .crosshair
        }
    }
    struct Session {
        let target: Target
        let original: Stroke
        let start: CGPoint
    }
    static func supports(_ stroke: Stroke) -> Bool {
        (stroke.kind == .rect || stroke.kind == .ellipse) && stroke.points.count >= 2
    }
    static func hit(at point: CGPoint, size: CGSize, strokes: [Stroke], selected: UUID?) -> Target? {
        guard size.width > 0, size.height > 0 else { return nil }
        func bounds(_ stroke: Stroke) -> CGRect {
            CGRect(points: stroke.points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) })
        }
        if let stroke = strokes.first(where: { $0.id == selected && supports($0) }) {
            let rect = bounds(stroke)
            for handle in Handle.allCases {
                let p = handle.point(in: rect)
                if hypot(point.x - p.x, point.y - p.y) <= 9 {
                    return Target(id: stroke.id, handle: handle)
                }
            }
        }
        // Borders select shapes; empty interiors remain available for drawing nested annotations.
        for stroke in strokes.reversed() where supports(stroke) {
            let rect = bounds(stroke)
            let onBorder: Bool
            if stroke.kind == .ellipse, rect.width > 0, rect.height > 0 {
                let radius = hypot((point.x - rect.midX) / (rect.width / 2),
                                   (point.y - rect.midY) / (rect.height / 2))
                onBorder = abs(radius - 1) * min(rect.width, rect.height) / 2 <= 7
            } else {
                onBorder = rect.insetBy(dx: -7, dy: -7).contains(point)
                    && !rect.insetBy(dx: 7, dy: 7).contains(point)
            }
            if onBorder { return Target(id: stroke.id, handle: nil) }
        }
        if let stroke = strokes.first(where: { $0.id == selected && supports($0) }),
           bounds(stroke).contains(point) { return Target(id: stroke.id, handle: nil) }
        return nil
    }
    static func updated(_ session: Session, to point: CGPoint, size: CGSize) -> Stroke {
        var stroke = session.original
        let rect = CGRect(points: stroke.points)
        var x0 = rect.minX, x1 = rect.maxX, y0 = rect.minY, y1 = rect.maxY
        let dx = point.x - session.start.x, dy = point.y - session.start.y
        if let handle = session.target.handle {
            let minimumX = min(rect.width, 4 / max(1, size.width))
            let minimumY = min(rect.height, 4 / max(1, size.height))
            if handle.horizontal < 0 { x0 = max(0, min(x1 - minimumX, x0 + dx)) }
            if handle.horizontal > 0 { x1 = min(1, max(x0 + minimumX, x1 + dx)) }
            if handle.vertical < 0 { y0 = max(0, min(y1 - minimumY, y0 + dy)) }
            if handle.vertical > 0 { y1 = min(1, max(y0 + minimumY, y1 + dy)) }
        } else {
            let boundedX = min(1 - x1, max(-x0, dx))
            let boundedY = min(1 - y1, max(-y0, dy))
            x0 += boundedX; x1 += boundedX; y0 += boundedY; y1 += boundedY
        }
        stroke.points = [CGPoint(x: x0, y: y0), CGPoint(x: x1, y: y1)]
        return stroke
    }
}

/// AppKit owns cursor entry/exit so closing or resizing the editor cannot leak a cursor stack.
/// The view passes all clicks through to the annotation gesture and text editor.
struct EditorCursorRegion: NSViewRepresentable {
    let cursor: NSCursor

    func makeNSView(context: Context) -> CursorView {
        CursorView(cursor: cursor)
    }

    func updateNSView(_ view: CursorView, context: Context) {
        view.cursor = cursor
        view.window?.invalidateCursorRects(for: view)
    }

    final class CursorView: NSView {
        var cursor: NSCursor {
            didSet {
                if isPointerInside, window?.isKeyWindow == true { cursor.set() }
            }
        }
        private var cursorTrackingArea: NSTrackingArea?
        private var isPointerInside = false

        init(cursor: NSCursor) {
            self.cursor = cursor
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            if let cursorTrackingArea { removeTrackingArea(cursorTrackingArea) }
            super.updateTrackingAreas()
            // Cursor rects alone can be superseded by NSHostingView's arrow.
            // Tracking still delivers hover events when hitTest passes clicks through.
            let area = NSTrackingArea(rect: .zero,
                                      options: [.inVisibleRect, .activeInKeyWindow,
                                                .cursorUpdate, .mouseEnteredAndExited,
                                                .mouseMoved, .enabledDuringMouseDrag],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            cursorTrackingArea = area
        }

        override func cursorUpdate(with event: NSEvent) { cursor.set() }

        override func mouseEntered(with event: NSEvent) {
            isPointerInside = true
            cursor.set()
        }

        override func mouseMoved(with event: NSEvent) { cursor.set() }

        override func mouseExited(with event: NSEvent) {
            isPointerInside = false
            NSCursor.arrow.set()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil, isPointerInside {
                isPointerInside = false
                NSCursor.arrow.set()
            }
            super.viewWillMove(toWindow: newWindow)
        }

        override func resetCursorRects() {
            super.resetCursorRects()
            addCursorRect(visibleRect, cursor: cursor)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.invalidateCursorRects(for: self)
        }
    }
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
    @State private var selectedStrokeID: UUID?
    @State private var editSession: AnnotationShapeEditing.Session?
    @State private var dragStarted = false
    @State private var hoverCursor: NSCursor?
    @State private var tool: EditorTool = .rect
    @State private var colorIndex = 0
    @State private var composition: ScreenshotComposition
    @State private var exportOptions: ScreenshotExportOptions
    @State private var pendingTextAt: CGPoint?
    @State private var pendingTextInput = ""
    @State private var feedbackKey: String?
    @State private var taskNotice: TaskFeedbackNotice?
    @State private var previewAvailableSize = CGSize(width: 640, height: 320)
    @ObservedObject private var l10n = L10n.shared

    private let captureFrame: PresetFrameStyle?
    private let preferences: ScreenshotPreferences

    init(image: NSImage, captureFrame: PresetFrameStyle? = nil, preferences: ScreenshotPreferences = ScreenshotPreferences(),
         onClose: @escaping () -> Void) {
        self.image = image
        self.captureFrame = captureFrame
        self.onClose = onClose
        self.preferences = preferences
        _composition = State(initialValue: preferences.loadEditorComposition(captureFrame: captureFrame))
        _exportOptions = State(initialValue: preferences.loadExportOptions())
    }

    /// 截图在预览里的尺寸：连同预设的留白、标题栏和画幅一起放进预览区，
    /// 比例越"高"的画幅，截图本身缩得越小。
    private var displaySize: CGSize {
        ScreenshotEditorSizing.previewContentSize(imageSize: image.size,
                                                  available: previewAvailableSize,
                                                  composition: composition)
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
            ScrollView(.horizontal, showsIndicators: false) {
                toolBar.fixedSize(horizontal: true, vertical: false)
            }.frame(height: 28)
            canvasArea.layoutPriority(-1)
            presetBar.fixedSize(horizontal: false, vertical: true)
            actionBar.fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: composition) { value in preferences.save(value) }
        .onChange(of: exportOptions) { value in preferences.save(value) }
        .taskFeedback($taskNotice)
    }

    // MARK: 工具条

    private var toolBar: some View {
        HStack(spacing: 6) {
            ForEach(EditorTool.allCases) { t in
                Button {
                    tool = t
                    selectedStrokeID = nil
                    hoverCursor = nil
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
                selectedStrokeID = nil
                hoverCursor = nil
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
            selectionOverlay.allowsHitTesting(false)
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                hoverCursor = shapeTarget(at: point)?.cursor
            case .ended: hoverCursor = nil
            }
        }
        .overlay(EditorCursorRegion(cursor: editSession.map {
            $0.target.handle == nil ? .closedHand : $0.target.cursor
        } ?? hoverCursor ?? tool.cursor))
        .overlay(pendingTextOverlay)
    }

    private func shapeTarget(at point: CGPoint) -> AnnotationShapeEditing.Target? {
        guard tool == .rect || tool == .ellipse else { return nil }
        return AnnotationShapeEditing.hit(at: point, size: displaySize, strokes: strokes,
                                          selected: selectedStrokeID)
    }

    private var selectionOverlay: some View {
        Canvas { context, size in
            guard let stroke = strokes.first(where: { $0.id == selectedStrokeID }),
                  AnnotationShapeEditing.supports(stroke) else { return }
            let rect = CGRect(points: stroke.points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) })
            context.stroke(Path(rect), with: .color(.moleAccent),
                           style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            for handle in AnnotationShapeEditing.Handle.allCases {
                let point = handle.point(in: rect)
                let path = Path(ellipseIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8))
                context.fill(path, with: .color(.surface1))
                context.stroke(path, with: .color(.moleAccent), lineWidth: 2)
            }
        }
        .frame(width: displaySize.width, height: displaySize.height)
    }

    private var canvasArea: some View {
        GeometryReader { geometry in
            let canvasSize = PresetLayout.compute(contentSize: displaySize, composition: composition).canvasSize
            Group {
                if composition.isPlain {
                    editorCanvas
                } else {
                    PresetFrameView(composition: composition, contentSize: displaySize) {
                        editorCanvas
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .modifier(ScreenshotPreviewOverflowClip(needed: canvasSize.width > geometry.size.width
                                                    || canvasSize.height > geometry.size.height))
            .onAppear { previewAvailableSize = geometry.size }
            .onChange(of: geometry.size) { previewAvailableSize = $0 }
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard tool != .text else { return }
                if !dragStarted {
                    dragStarted = true
                    if let target = shapeTarget(at: value.startLocation),
                       let original = strokes.first(where: { $0.id == target.id }) {
                        selectedStrokeID = target.id
                        editSession = .init(target: target, original: original, start: normalized(value.startLocation))
                    } else {
                        selectedStrokeID = nil
                    }
                }
                let p = normalized(value.location)
                if let editSession, let index = strokes.firstIndex(where: { $0.id == editSession.target.id }) {
                    strokes[index] = AnnotationShapeEditing.updated(editSession, to: p, size: displaySize)
                    return
                }
                if draft == nil {
                    guard tool != .mosaic || strokes.count + 1 <= 400 else { return }
                    draft = Stroke(kind: kindFor(tool), colorIndex: colorIndex, points: [p])
                } else {
                    draft?.points.append(p)
                }
            }
            .onEnded { value in
                defer { editSession = nil; dragStarted = false; hoverCursor = nil }
                if let editSession, let index = strokes.firstIndex(where: { $0.id == editSession.target.id }) {
                    strokes[index] = AnnotationShapeEditing.updated(editSession, to: normalized(value.location), size: displaySize)
                    return
                }
                guard tool != .text else {
                    pendingTextAt = normalized(value.location)
                    pendingTextInput = ""
                    return
                }
                if var stroke = draft {
                    stroke.points.append(normalized(value.location))
                    // 单击（矩形/椭圆）给最小尺寸，避免零面积不可见
                    if stroke.points.count == 2, stroke.points[0] == stroke.points[1],
                       stroke.kind == .rect || stroke.kind == .ellipse {
                        stroke.points[1] = CGPoint(x: min(1, stroke.points[0].x + 0.05),
                                                   y: min(1, stroke.points[0].y + 0.05))
                    }
                    strokes.append(stroke)
                    selectedStrokeID = AnnotationShapeEditing.supports(stroke) ? stroke.id : nil
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
                    ForEach(ScreenshotPreset.editorPresets) { preset in
                        Button {
                            composition.select(preset)
                            if let captureFrame {
                                composition.frame = captureFrame
                                composition.aspect = .free
                            }
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
        }
    }

    // MARK: 操作条

    private var actionBar: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: true) {
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
                            .foregroundStyle(feedbackKey == "shot.failed" ? Color.warning : Color.moleAccentText)
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            .frame(height: 46)
            Button(l10n.t("common.done")) {
                guard copyToPasteboard() else {
                    showFeedback("shot.failed")
                    return
                }
                onClose()
            }
            .buttonStyle(PrimaryButtonStyle())
            .fixedSize(horizontal: true, vertical: false)
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
        if key == "shot.failed" {
            taskNotice = TaskFeedbackNotice(message: l10n.t("task.failure.message"))
        }
        feedbackKey = key
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if feedbackKey == key { feedbackKey = nil }
        }
    }
}

// MARK: - 标注画布（Canvas 绘制）

/// Minimum-size frame chrome can exceed an exceptionally short viewport. In that case
/// clip the preview region so its drawing does not cover the fixed editing controls.
private struct ScreenshotPreviewOverflowClip: ViewModifier {
    let needed: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if needed { content.clipped() } else { content }
    }
}

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
            // Draw indices last so overlapping annotations cannot hide the reference numbers.
            for (number, stroke) in AnnotationIndexing.numberedShapes(in: strokes) {
                let bounds = CGRect(points: stroke.points.map {
                    CGPoint(x: $0.x * canvasSize.width, y: $0.y * canvasSize.height)
                })
                let badge = AnnotationIndexing.badgeRect(for: bounds, number: number,
                                                        canvasSize: canvasSize, drawingScale: drawingScale)
                let colorIndex = stroke.colorIndex % editorColors.count
                context.fill(Path(roundedRect: badge, cornerRadius: 8 * drawingScale),
                             with: .color(editorColors[colorIndex]))
                context.draw(Text(verbatim: String(number))
                    .font(.system(size: 10 * drawingScale, weight: .bold, design: .rounded))
                    .foregroundColor(colorIndex == 0 || colorIndex == 4 ? Color.black : Color.white),
                    at: CGPoint(x: badge.midX, y: badge.midY))
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

/// iPhone 外壳的金属渐变后盖：钛黑 / 银白，随预设的明暗外观切换。
private let darkPhoneBody = LinearGradient(
    colors: [Color(white: 0.32), Color(white: 0.14), Color(white: 0.24)],
    startPoint: .topLeading, endPoint: .bottomTrailing)
private let lightPhoneBody = LinearGradient(
    colors: [Color(white: 0.95), Color(white: 0.78), Color(white: 0.88)],
    startPoint: .topLeading, endPoint: .bottomTrailing)

/// 预设相框：背景 + 窗口卡片（标题栏三点）/ 圆角卡片 / iPhone 外壳 + 内容。
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
        // 成品画布四角圆角：PNG 导出时角外透出，不再是直角矩形。
        .clipShape(RoundedRectangle(cornerRadius: layout.canvasCornerRadius,
                                    style: .continuous))
    }

    private var isLight: Bool { composition.preset.frameAppearance == .light }

    @ViewBuilder
    private func card(_ layout: PresetLayout) -> some View {
        if composition.frame == .iphone || composition.frame == .ipad {
            phoneBody(layout)
        } else {
            windowCard(layout)
        }
    }

    private func windowCard(_ layout: PresetLayout) -> some View {
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

    // MARK: iPhone 外壳

    /// 金属渐变后盖：钛黑 / 银白，随预设的明暗外观切换。
    private var bodyFill: LinearGradient {
        isLight ? lightPhoneBody : darkPhoneBody
    }

    /// iPhone 机身：渐变后盖 + 侧键 + 黑色屏幕包边；截图以原始尺寸铺在屏幕上、
    /// 居中自动剪裁（cover），灵动岛留在上边框里，不遮挡内容。坐标同卡片（左上为原点）。
    private func phoneBody(_ layout: PresetLayout) -> some View {
        let bodyShape = RoundedRectangle(cornerRadius: layout.bodyCornerRadius, style: .continuous)
        let rim = (3 * layout.chromeScale).rounded()
        let screenShape = RoundedRectangle(cornerRadius: layout.screenCornerRadius, style: .continuous)
        let rimShape = RoundedRectangle(cornerRadius: layout.screenCornerRadius + rim, style: .continuous)
        return ZStack(alignment: .topLeading) {
            bodyShape.fill(AnyShapeStyle(bodyFill))
            if composition.frame == .iphone { phoneSideButtons(layout) }
            // 屏幕黑色包边：浅色截图也能看清屏幕边界
            rimShape.fill(Color.black)
                .frame(width: layout.contentRect.width + rim * 2,
                       height: layout.contentRect.height + rim * 2)
                .offset(x: layout.contentRect.minX - layout.cardRect.minX - rim,
                        y: layout.contentRect.minY - layout.cardRect.minY - rim)
            // 原图保持原始尺寸、超出屏幕的部分居中裁掉，绝不拉伸变形。
            content()
                .frame(width: layout.contentSourceSize.width, height: layout.contentSourceSize.height)
                .frame(width: layout.contentRect.width, height: layout.contentRect.height)
                .clipShape(screenShape)
                .offset(x: layout.contentRect.minX - layout.cardRect.minX,
                        y: layout.contentRect.minY - layout.cardRect.minY)
            if composition.frame == .iphone {
                Capsule()
                    .fill(Color.black)
                    .frame(width: layout.islandRect.width, height: layout.islandRect.height)
                    .offset(x: layout.islandRect.minX - layout.cardRect.minX,
                            y: layout.islandRect.minY - layout.cardRect.minY)
            } else {
                Circle().fill(Color.black)
                    .frame(width: 8 * layout.chromeScale, height: 8 * layout.chromeScale)
                    .offset(x: layout.cardRect.width / 2 - 4 * layout.chromeScale,
                            y: layout.bezelTop / 2 - 4 * layout.chromeScale)
            }
            bodyShape.strokeBorder(
                isLight ? Color.black.opacity(0.20) : Color.white.opacity(0.25),
                lineWidth: max(1, 1.5 * layout.chromeScale))
        }
        .frame(width: layout.cardRect.width, height: layout.cardRect.height)
        .shadow(color: .black.opacity(composition.preset.showsShadow ? 0.38 : 0),
                radius: 24 * layout.chromeScale, y: 12 * layout.chromeScale)
    }

    /// 左侧音量键 ×2、右侧电源键：凸出机身一点，留白由布局兜底不裁切。
    @ViewBuilder
    private func phoneSideButtons(_ layout: PresetLayout) -> some View {
        let scale = layout.chromeScale
        let thickness = max(2, 12 * scale)
        let tuck = 6 * scale
        let gap = 16 * scale
        let protrusion = layout.buttonProtrusion
        let width = protrusion + tuck
        let length = 150 * scale
        // 音量键位于机身上半区，电源键在右侧对准两颗音量键中间
        let volumeY = layout.bezelTop + layout.contentRect.height * 0.16
        let powerLength = min(length * 1.4, layout.contentRect.height * 0.4)
        let powerY = volumeY + length + gap / 2 - powerLength / 2
        let floor = layout.cardRect.height - layout.bezelBottom * 0.5
        let buttonColor = isLight ? Color(white: 0.60) : Color(white: 0.36)
        let shape = RoundedRectangle(cornerRadius: thickness / 2, style: .continuous)
        shape.fill(buttonColor)
            .frame(width: width, height: length)
            .offset(x: -protrusion, y: volumeY)
        // 内容太扁时装不下第二颗音量键，宁可少画也不越出机身
        if volumeY + length * 2 + gap <= floor {
            shape.fill(buttonColor)
                .frame(width: width, height: length)
                .offset(x: -protrusion, y: volumeY + length + gap)
        }
        shape.fill(buttonColor)
            .frame(width: width, height: powerLength)
            .offset(x: layout.cardRect.width - tuck, y: max(volumeY, min(powerY, floor - powerLength)))
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
            if preset.frame == .iphone {
                RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                    .fill(preset.frameAppearance == .light ? Color(white: 0.88) : Color(white: 0.22))
                    .frame(width: 17, height: 30)
                    .overlay(
                        VStack(spacing: 2.5) {
                            Capsule().fill(Color.black).frame(width: 6, height: 2.5)
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(Color(white: 0.96))
                        }
                        .padding(2.5))
                    .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
            } else if preset.frame != .none {
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
