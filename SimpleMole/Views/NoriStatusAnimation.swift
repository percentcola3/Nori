import SwiftUI
import WebKit

/// Larger operation states play the bundled SVG artwork and abstract loading accents.
/// The small header keeps using the lightweight native Canvas mascot.
struct NoriStatusAnimation: View {
    let mood: NoriMood
    var size: CGFloat = 76
    var assetName: String? = nil
    /// Floating surfaces (the island) stay visible while another app is active.
    var ignoresAppActivity = false
    /// Business-neutral loops for tab placeholders and the island. `nori-static`
    /// is only the fallback when no scene was picked.
    static let idleScenes = ["nori-coffee", "nori-doze", "nori-humming", "nori-bubble"]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appActive = NSApp.isActive
    @State private var settled = false

    private var active: Bool { ignoresAppActivity || appActive }

    private var asset: String {
        if let assetName { return assetName }
        if reduceMotion || !active || settled {
            if mood == .success || mood == .attention { return "nori-\(mood.rawValue)" }
            return "nori-static"
        }
        switch mood {
        // Resting moods share the single blinking placeholder.
        case .idle, .bored, .blink: return "nori-static"
        case .working, .success, .attention, .tidying: return "nori-\(mood.rawValue)"
        }
    }
    var body: some View {
        Group {
            if let url = Bundle.main.url(forResource: asset, withExtension: "svg", subdirectory: "Nori") {
                NoriSVGCanvas(url: url, animates: !reduceMotion && active && !settled,
                              retainsResultBadge: mood == .success || mood == .attention)
            } else {
                NoriMascotView(mood: mood, size: size)
            }
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in appActive = true }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in appActive = false }
        .task(id: mood) {
            settled = false
            guard mood == .success || mood == .attention else { return }
            let duration = mood == .success ? NoriMotion.celebrationDuration : NoriMotion.failureDuration
            do { try await Task.sleep(nanoseconds: UInt64((duration + 0.1) * 1_000_000_000)) }
            catch { return }
            settled = true
        }
    }
}

/// 固定舞台中保留离场视图，按页面阶段交叉淡化；路径/扫描进度不触发重建。
struct NoriPageTransition<Phase: Hashable, Content: View>: View {
    let phase: Phase
    @ViewBuilder var content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            content()
                .id(phase)
                .transition(.opacity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: reduceMotion ? 0.12 : 0.30), value: phase)
    }
}

/// All tab placeholders share the same available-space sizing and center.
struct NoriPlaceholderStage<Content: View>: View {
    @ViewBuilder var content: (CGFloat) -> Content

    var body: some View {
        GeometryReader { geometry in
            let size = min(240, max(160, min(geometry.size.width * 0.3, geometry.size.height * 0.38)))
            VStack(spacing: 20) {
                content(size)
            }
            .frame(width: max(0, geometry.size.width - 48))
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A single centered mascot replaces the empty inventory while a scan runs.
/// `quiet` drops the caption and spinner: the animated SVG alone carries the state.
struct NoriScanActivity: View {
    let text: String
    var assetName: String? = nil
    var quiet: Bool = false

    var body: some View {
        NoriPlaceholderStage { size in
            NoriStatusAnimation(mood: .working, size: size, assetName: assetName)
            if !quiet {
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                ProgressView().controlSize(.small)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

/// The idle mascot every tab shows before its first task starts. All tabs share
/// the scene picked when the window opened, so switching tabs keeps it consistent.
struct NoriIdlePlaceholder: View {
    @ObservedObject var state: AppState
    var size: CGFloat = 200

    var body: some View {
        NoriStatusAnimation(mood: .idle, size: size, assetName: state.placeholderScene)
            .id(state.placeholderScene)
    }
}

/// The resting placeholder with a caption underneath.
struct NoriRestingPlaceholder: View {
    @ObservedObject var state: AppState
    let text: String

    var body: some View {
        NoriPlaceholderStage { size in
            NoriIdlePlaceholder(state: state, size: size)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}

private struct NoriSVGCanvas: NSViewRepresentable {
    let url: URL
    let animates: Bool
    let retainsResultBadge: Bool
    final class Coordinator { var loadedURL: URL?; var animates: Bool?; var retainsResultBadge: Bool? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        view.underPageBackgroundColor = .clear
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.loadedURL != url || context.coordinator.animates != animates
                || context.coordinator.retainsResultBadge != retainsResultBadge,
              let data = try? Data(contentsOf: url), var svg = String(data: data, encoding: .utf8) else { return }
        context.coordinator.loadedURL = url
        context.coordinator.animates = animates
        context.coordinator.retainsResultBadge = retainsResultBadge
        if !animates {
            let hidden = retainsResultBadge
                ? ".steam,.confetti0,.confetti1,.confetti2,.confetti3,.confetti4,.confetti5,.confetti6,.confetti7,.confetti8"
                : ".steam,.orbit-prop"
            let resultBadge = retainsResultBadge ? ".orbit-prop{display:inline!important}" : ""
            svg = svg.replacingOccurrences(of: "</svg>",
                with: "<style>*{animation:none!important}\(resultBadge)\(hidden){display:none!important}</style></svg>")
        }
        let html = """
        <html><head><meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'"><style>
        html,body{margin:0;background:transparent;overflow:hidden;color-scheme:normal}img{width:100%;height:100%;display:block}
        </style></head><body><img alt="" src="data:image/svg+xml;base64,\(Data(svg.utf8).base64EncodedString())"></body></html>
        """
        view.loadHTMLString(html, baseURL: nil)
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading()
        // 淡出期间 SwiftUI 可能已拆除 representable 的关联。
        // 不导航到空白页，保留最后一帧，随过渡结束后释放 WebView。
    }
}
