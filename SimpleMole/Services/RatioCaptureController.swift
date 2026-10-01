import AppKit
import SwiftUI

/// 按比例截取：盖在鼠标所在屏幕上的全屏覆盖层，选区比例固定、只允许拖动，
/// 底部控制条切换比例（iPhone / Stories / Instagram / 1:1 / X）并确认截取。
@MainActor
final class RatioCaptureController {
    static let shared = RatioCaptureController()
    private var window: NSWindow?

    func present(onCapture: @escaping (NSImage?) -> Void) {
        guard window == nil else { return }
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
            ?? NSScreen.main else { return }
        let window = NSWindow(contentRect: screen.frame,
                              styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = false
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let screenFrame = screen.frame
        window.contentViewController = NSHostingController(rootView: RatioCaptureOverlayView(
            screenFrame: screenFrame) { [weak self] localRect in
            // SwiftUI 视图坐标以上左为原点；换算成全局坐标（左下原点）。
            let global = CGRect(x: screenFrame.minX + localRect.minX,
                                y: screenFrame.maxY - localRect.maxY,
                                width: localRect.width, height: localRect.height)
            self?.dismiss()
            ScreenShotService.captureRegion(global) { image in
                onCapture(image)
            }
        } onCancel: { [weak self] in
            self?.dismiss()
            onCapture(nil)
        })
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func dismiss() {
        window?.orderOut(nil)
        window = nil
    }
}

/// 覆盖层：四块暗色遮罩围出选区，选区白描边可拖动，控制条浮在底部。
private struct RatioCaptureOverlayView: View {
    let screenFrame: CGRect
    let onCapture: (CGRect) -> Void
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
        HStack(spacing: 10) {
            Menu {
                ForEach(CaptureRatio.allCases) { candidate in
                    Button {
                        ratio = candidate
                        ratio.store()
                        origin = nil // 换比例回到居中
                    } label: {
                        if candidate == ratio {
                            Label(l10n.t(candidate.l10nKey), systemImage: "checkmark")
                        } else {
                            Text(l10n.t(candidate.l10nKey))
                        }
                    }
                }
            } label: {
                Label(l10n.t(ratio.l10nKey), systemImage: "aspectratio")
                    .frame(minWidth: 110)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .foregroundStyle(.primary)
            Button(role: .cancel) {
                onCancel()
            } label: {
                Text(l10n.t("common.cancel"))
            }
            .keyboardShortcut(.cancelAction)
            Button {
                onCapture(CGRect(origin: selectionOrigin, size: selectionSize))
            } label: {
                Label(l10n.t("shot.ratio.confirm"), systemImage: "camera.viewfinder")
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
        .padding(.bottom, 28)
    }
}
