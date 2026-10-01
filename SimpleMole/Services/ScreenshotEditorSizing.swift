import Foundation

/// Window chrome fits the owning screen; the preview fits the space left by its controls.
enum ScreenshotEditorSizing {
    static func windowFrame(visibleFrame: CGRect,
                            preferredSize: CGSize = CGSize(width: 900, height: 700),
                            preferredOrigin: CGPoint? = nil) -> CGRect {
        let margin = min(24, max(0, min(visibleFrame.width, visibleFrame.height) / 10))
        let bounds = visibleFrame.insetBy(dx: margin, dy: margin)
        let size = CGSize(width: min(max(1, preferredSize.width), max(1, bounds.width)),
                          height: min(max(1, preferredSize.height), max(1, bounds.height)))
        let origin = preferredOrigin ?? CGPoint(x: bounds.midX - size.width / 2,
                                               y: bounds.midY - size.height / 2)
        return CGRect(x: min(max(origin.x, bounds.minX), bounds.maxX - size.width),
                      y: min(max(origin.y, bounds.minY), bounds.maxY - size.height),
                      width: size.width, height: size.height)
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
