import SwiftUI
import WebKit

/// Larger operation states play the bundled SVG artwork, including its CSS ribbons.
/// The small header keeps using the lightweight native Canvas mascot.
struct NoriStatusAnimation: View {
    let mood: NoriMood
    var size: CGFloat = 76
    var assetName: String? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var active = NSApp.isActive
    @State private var settled = false

    private var asset: String {
        if let assetName { return assetName }
        return reduceMotion || !active || settled ? "nori-static" : "nori-\(mood.rawValue)"
    }
    var body: some View {
        Group {
            if let url = Bundle.main.url(forResource: asset, withExtension: "svg", subdirectory: "Nori") {
                NoriSVGCanvas(url: url, animates: !reduceMotion && active && !settled)
            } else {
                NoriMascotView(mood: mood, size: size)
            }
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in active = true }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in active = false }
        .task(id: mood) {
            settled = false
            guard mood == .success || mood == .attention else { return }
            do { try await Task.sleep(nanoseconds: mood == .success ? 1_500_000_000 : 900_000_000) }
            catch { return }
            settled = true
        }
    }
}

/// A single centered mascot replaces the empty inventory while a scan runs.
/// `quiet` drops the caption and spinner: the animated SVG alone carries the state.
struct NoriScanActivity: View {
    let text: String
    var assetName: String? = nil
    var quiet: Bool = false

    var body: some View {
        VStack(spacing: 16) {
            NoriStatusAnimation(mood: .working, size: quiet ? 168 : 156, assetName: assetName)
            if !quiet {
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                ProgressView().controlSize(.small)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct NoriSVGCanvas: NSViewRepresentable {
    let url: URL
    let animates: Bool
    final class Coordinator { var loadedURL: URL?; var animates: Bool? }
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
        guard context.coordinator.loadedURL != url || context.coordinator.animates != animates,
              let data = try? Data(contentsOf: url), var svg = String(data: data, encoding: .utf8) else { return }
        context.coordinator.loadedURL = url
        context.coordinator.animates = animates
        if !animates {
            svg = svg.replacingOccurrences(of: "</svg>",
                with: "<style>*{animation:none!important}</style></svg>")
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
        view.loadHTMLString("", baseURL: nil)
    }
}
