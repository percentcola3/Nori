import SwiftUI
import WebKit

/// Larger operation states play the bundled SVG artwork, including its CSS ribbons.
/// The small header keeps using the lightweight native Canvas mascot.
struct NoriStatusAnimation: View {
    let mood: NoriMood
    var size: CGFloat = 76
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var active = NSApp.isActive
    @State private var settled = false

    private var asset: String {
        reduceMotion || !active || settled ? "nori-static" : "nori-\(mood.rawValue)"
    }
    var body: some View {
        Group {
            if let url = Bundle.main.url(forResource: asset, withExtension: "svg", subdirectory: "Nori") {
                NoriSVGCanvas(url: url)
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

private struct NoriSVGCanvas: NSViewRepresentable {
    let url: URL
    final class Coordinator { var loadedURL: URL? }
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
        guard context.coordinator.loadedURL != url, let data = try? Data(contentsOf: url) else { return }
        context.coordinator.loadedURL = url
        let html = """
        <html><head><meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'"><style>
        html,body{margin:0;background:transparent;overflow:hidden;color-scheme:normal}img{width:100%;height:100%;display:block}
        </style></head><body><img alt="" src="data:image/svg+xml;base64,\(data.base64EncodedString())"></body></html>
        """
        view.loadHTMLString(html, baseURL: nil)
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading()
        view.loadHTMLString("", baseURL: nil)
    }
}
