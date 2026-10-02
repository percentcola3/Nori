import Foundation
import AppKit
import SwiftUI

/// Window chrome fits the owning screen; the preview fits the space left by its controls.
enum ScreenshotEditorSizing {
    static let defaultWindowSize = CGSize(width: 900, height: 700)
    static let minimumWindowSize = CGSize(width: 520, height: 360)

    static func windowFrame(visibleFrame: CGRect,
                            preferredSize: CGSize = defaultWindowSize,
                            minimumSize: CGSize = minimumWindowSize,
                            preferredOrigin: CGPoint? = nil) -> CGRect {
        let margin = min(24, max(0, min(visibleFrame.width, visibleFrame.height) / 10))
        let bounds = visibleFrame.insetBy(dx: margin, dy: margin)
        let size = CGSize(width: min(max(1, minimumSize.width, preferredSize.width), max(1, bounds.width)),
                          height: min(max(1, minimumSize.height, preferredSize.height), max(1, bounds.height)))
        let origin = preferredOrigin ?? CGPoint(x: bounds.midX - size.width / 2,
                                               y: bounds.midY - size.height / 2)
        return CGRect(x: min(max(origin.x, bounds.minX), bounds.maxX - size.width),
                      y: min(max(origin.y, bounds.minY), bounds.maxY - size.height),
                      width: size.width, height: size.height)
    }

    /// AppKit owns the resizable window; ScrollView/GeometryReader content has no
    /// useful intrinsic window size. Preserve its geometry before swapping hosts.
    @MainActor
    static func replaceContent<Content: View>(_ content: Content, in window: NSWindow,
                                             visibleFrame: CGRect?, center: Bool) {
        let previousFrame = window.frame
        let preferredSize = center ? defaultWindowSize : previousFrame.size
        let frame: CGRect
        if let visibleFrame {
            frame = windowFrame(visibleFrame: visibleFrame, preferredSize: preferredSize,
                                preferredOrigin: center ? nil : previousFrame.origin)
        } else {
            frame = CGRect(origin: previousFrame.origin,
                           size: CGSize(width: max(minimumWindowSize.width, preferredSize.width),
                                        height: max(minimumWindowSize.height, preferredSize.height)))
        }
        let host = NSHostingController(rootView: content)
        host.sizingOptions = []
        window.contentViewController = host
        window.minSize = CGSize(width: min(minimumWindowSize.width, frame.width),
                                height: min(minimumWindowSize.height, frame.height))
        window.setFrame(frame, display: true)
    }

    static func previewContentSize(imageSize: CGSize, available: CGSize,
                                   composition: ScreenshotComposition) -> CGSize {
        let source = CGSize(width: max(1, imageSize.width), height: max(1, imageSize.height))
        let bounds = CGSize(width: max(1, available.width), height: max(1, available.height))
        func content(at scale: CGFloat) -> CGSize {
            CGSize(width: max(1, floor(source.width * scale)),
                   height: max(1, floor(source.height * scale)))
        }
        func fits(_ content: CGSize) -> Bool {
            let canvas = PresetLayout.compute(contentSize: content, composition: composition).canvasSize
            return canvas.width <= bounds.width && canvas.height <= bounds.height
        }
        var lower: CGFloat = 0
        var upper: CGFloat = min(1, bounds.width / source.width, bounds.height / source.height)
        if fits(content(at: upper)) { return content(at: upper) }
        // The frame has minimum-size chrome, so a single proportional step is insufficient
        // on short screens or for tall captures. Keep the largest content that actually fits.
        for _ in 0..<24 {
            let middle = (lower + upper) / 2
            if fits(content(at: middle)) { lower = middle } else { upper = middle }
        }
        return content(at: lower)
    }
}
