import AppKit
import SwiftUI

/// 按比例截取：盖在鼠标所在屏幕上的全屏覆盖层，选区比例固定、只允许拖动，
/// 底部控制条切换比例（iPhone / Stories / Instagram / 1:1 / X）并确认截取。
@MainActor
final class RatioCaptureController {
    static let shared = RatioCaptureController()
    private var window: NSWindow?
    private var captureProcess: Process?
    private var session = UUID()

    var isCapturing: Bool { window?.isVisible == true || captureProcess?.isRunning == true }

    func present(onCapture: @escaping (NSImage?, PresetFrameStyle) -> Void) {
        dismiss()
        let session = self.session
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
            ?? NSScreen.main else { onCapture(nil, .none); return }
        let window = RatioCaptureWindow(contentRect: screen.frame,
                              styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = false
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let screenFrame = screen.frame
        let hosting = NSHostingController(rootView: RatioCaptureOverlayView(
            screenFrame: screenFrame) { [weak self] localRect, frame in
            // SwiftUI 视图坐标以上左为原点；换算成全局坐标（左下原点）。
            let global = CGRect(x: screenFrame.minX + localRect.minX,
                                y: screenFrame.maxY - localRect.maxY,
                                width: localRect.width, height: localRect.height)
            guard let self, self.session == session else { return }
            self.window?.orderOut(nil)
            self.window = nil
            self.captureProcess = ScreenShotService.captureRegion(global) { [weak self] image in
                guard let self, self.session == session else { return }
                self.captureProcess = nil
                onCapture(image, frame)
            }
        } onCancel: { [weak self] in
            guard let self, self.session == session else { return }
            self.dismiss()
            onCapture(nil, .none)
        }.frame(width: screenFrame.width, height: screenFrame.height))
        // 覆盖层的尺寸由屏幕决定，不能让 HostingController 按内容固有尺寸缩窗。
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setFrame(screenFrame, display: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func dismiss() {
        session = UUID()
        if let captureProcess, captureProcess.isRunning { captureProcess.terminate() }
        captureProcess = nil
        window?.orderOut(nil)
        window = nil
    }
}

/// Borderless NSWindow 默认不能接收键盘，需显式允许 Enter/Escape。
private final class RatioCaptureWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// 覆盖层：四块暗色遮罩围出选区，选区白描边可拖动，控制条浮在底部。
private struct RatioCaptureOverlayView: View {
    let screenFrame: CGRect
    let onCapture: (CGRect, PresetFrameStyle) -> Void
    let onCancel: () -> Void
    @State private var ratio: CaptureRatio = CaptureRatio.load()
    @State private var origin: CGPoint?
    @State private var dragBaseline: CGPoint?
    @ObservedObject private var l10n = L10n.shared

    /// 选区尺寸：屏幕可用区的 78% 在受限维度上取齐，其余维度按比例推导。
    private var selectionSize: CGSize {
        let available = CGSize(width: screenFrame.width * 0.78,
                               height: screenFrame.height * 0.78)
        let r = ratio.ratio
        if available.width / available.height > r {
            return CGSize(width: (available.height * r).rounded(),
                          height: available.height.rounded())
        }
        return CGSize(width: available.width.rounded(),
                      height: (available.width / r).rounded())
    }

    private var selectionOrigin: CGPoint {
        get {
            if let origin { return origin }
            return CGPoint(x: ((screenFrame.width - selectionSize.width) / 2).rounded(),
                           y: ((screenFrame.height - selectionSize.height) / 2).rounded())
        }
        nonmutating set { origin = newValue }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            GeometryReader { proxy in
                let rect = CGRect(origin: selectionOrigin, size: selectionSize)
                // 四块暗色遮罩围出"洞"，选区内保持透亮可见。
                Rectangle().fill(Color.black.opacity(0.34))
                    .frame(width: proxy.size.width, height: max(0, rect.minY))
                Rectangle().fill(Color.black.opacity(0.34))
                    .frame(width: proxy.size.width,
                           height: max(0, proxy.size.height - rect.maxY))
                    .offset(y: rect.maxY)
                Rectangle().fill(Color.black.opacity(0.34))
                    .frame(width: max(0, rect.minX), height: rect.height)
                    .offset(y: rect.minY)
                Rectangle().fill(Color.black.opacity(0.34))
                    .frame(width: max(0, proxy.size.width - rect.maxX), height: rect.height)
                    .offset(x: rect.maxX, y: rect.minY)
                // 选区描边与四角标记
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                if dragBaseline == nil { dragBaseline = rect.origin }
                                let base = dragBaseline ?? rect.origin
                                let size = selectionSize
                                selectionOrigin = CGPoint(
                                    x: min(max(0, base.x + value.translation.width),
                                           proxy.size.width - size.width),
                                    y: min(max(0, base.y + value.translation.height),
                                           proxy.size.height - size.height))
                            }
                            .onEnded { _ in dragBaseline = nil })
                VStack(spacing: 3) {
                    Text("\(l10n.t(ratio.l10nKey)) · \(Int(rect.width))×\(Int(rect.height))")
                        .font(.system(size: 11, weight: .semibold))
                    Text(l10n.t("shot.ratio.hint"))
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.8))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.black.opacity(0.55)))
                .offset(x: rect.minX, y: max(8, rect.minY - 44))
            }
        }
        .overlay(alignment: .bottom) { controlBar }
    }

    private var controlBar: some View {
        HStack(spacing: 14) {
            // 比例模板选择：迷你比例预览 + 数值标签，点选即切换。
            PillPicker(items: CaptureRatio.allCases.map { l10n.t($0.l10nKey) },
                       selection: Binding(get: {
                           CaptureRatio.allCases.firstIndex(of: ratio) ?? 0
                       }, set: { index in
                           ratio = CaptureRatio.allCases[index]
                           ratio.store()
                           origin = nil
                       }))
            Spacer(minLength: 10)
            Button(role: .cancel) {
                onCancel()
            } label: {
                Text(l10n.t("common.cancel"))
            }
            .keyboardShortcut(.cancelAction)
            Button {
                onCapture(CGRect(origin: selectionOrigin, size: selectionSize), ratio.frameStyle)
            } label: {
                Label(l10n.t("shot.ratio.confirm"), systemImage: "camera.viewfinder")
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .padding(.bottom, 28)
    }

}
