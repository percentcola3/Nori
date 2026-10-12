import AppKit
import ImageIO

/// Cache a single display-sized bitmap, rather than retaining an application's
/// complete icon representations or a clipboard image's original bytes.
enum ImageMemoryCache {
    static func rasterized(_ image: NSImage, maximumPixelSize: Int = 96) -> NSImage? {
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = CGFloat(maximumPixelSize) / max(image.size.width, image.size.height)
        let width = max(1, Int((image.size.width * scale).rounded()))
        let height = max(1, Int((image.size.height * scale).rounded()))
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height),
                   from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let result = NSImage(size: image.size)
        result.addRepresentation(bitmap)
        result.isTemplate = image.isTemplate
        return result
    }

    static func cost(_ image: NSImage) -> Int {
        image.representations.compactMap { $0 as? NSBitmapImageRep }
            .reduce(0) { $0 + $1.bytesPerRow * $1.pixelsHigh }
    }
}

enum ClipboardImageThumbnailLoader {
    private static let queue = DispatchQueue(label: "com.nori.clipboard-thumbnails", qos: .utility)
    private static let lock = NSLock()
    private static var generation = 0
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 24
        cache.totalCostLimit = 4 * 1024 * 1024
        return cache
    }()

    static func image(url: URL?, fallbackData: Data?, maximumPixelSize: Int) async -> NSImage? {
        let token = currentGeneration()
        return await withCheckedContinuation { continuation in
            queue.async {
                let image: NSImage? = autoreleasepool {
                    let key = url.map { ($0.path + "#\(maximumPixelSize)") as NSString }
                    if let key, let existing = cache.object(forKey: key) { return existing }
                    let options = [kCGImageSourceShouldCache: false] as CFDictionary
                    let source = url.flatMap { CGImageSourceCreateWithURL($0 as CFURL, options) }
                        ?? fallbackData.flatMap { CGImageSourceCreateWithData($0 as CFData, options) }
                    guard let source, let bitmap = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceShouldCacheImmediately: true,
                        kCGImageSourceThumbnailMaxPixelSize: min(512, maximumPixelSize)
                    ] as CFDictionary) else { return nil }
                    let result = NSImage(cgImage: bitmap, size: .zero)
                    lock.lock()
                    if let key, generation == token { cache.setObject(result, forKey: key, cost: bitmap.bytesPerRow * bitmap.height) }
                    lock.unlock()
                    return result
                }
                continuation.resume(returning: image)
            }
        }
    }

    private static func currentGeneration() -> Int {
        lock.lock(); defer { lock.unlock() }; return generation
    }
    static func clear() {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1
        cache.removeAllObjects()
    }
}
