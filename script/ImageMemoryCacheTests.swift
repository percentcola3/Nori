import AppKit

@main
struct ImageMemoryCacheTests {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nori-images-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let large = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2048, pixelsHigh: 1024,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 2048 * 4, bitsPerPixel: 32)!
        let source = NSImage(size: NSSize(width: 2048, height: 1024))
        source.addRepresentation(large)
        let icon = ImageMemoryCache.rasterized(source)!
        precondition(icon.representations.count == 1 && icon.representations[0].pixelsWide == 96
                     && icon.representations[0].pixelsHigh == 48 && ImageMemoryCache.cost(icon) == 96 * 48 * 4,
                     "Icon caches must retain a single bounded bitmap with the original aspect ratio")
        let url = root.appendingPathComponent("source.tiff")
        try large.representation(using: .tiff, properties: [:])!.write(to: url)
        let thumbnail = await ClipboardImageThumbnailLoader.image(url: url, fallbackData: nil, maximumPixelSize: 256)!
        let bitmap = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        precondition(bitmap.width == 256 && bitmap.height == 128,
                     "Clipboard previews must downsample before decoding the full source")
        ClipboardImageThumbnailLoader.clear()
        print("Image retention: 8 MiB source → 18 KiB icon; clipboard preview capped at 256 × 128")
    }
}
