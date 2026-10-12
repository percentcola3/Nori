import AppKit

/// NSWorkspace icon lookup is synchronous. Keep it off the UI actor, bounded
/// to one worker, and reuse images across tab visits. Callers never mutate the
/// cached image; SwiftUI supplies the display size.
enum UninstallIconLoader {
    private static let queue = DispatchQueue(label: "com.nori.uninstall-icons", qos: .utility)
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 256
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()

    static func image(path: String, identity: String) async -> NSImage {
        await withCheckedContinuation { continuation in
            queue.async {
                let key = "\(path)#\(identity)" as NSString
                if let image = cache.object(forKey: key) {
                    continuation.resume(returning: image)
                    return
                }
                let image = autoreleasepool {
                    let original = NSWorkspace.shared.icon(forFile: path)
                    return ImageMemoryCache.rasterized(original) ?? NSImage(size: NSSize(width: 32, height: 32))
                }
                cache.setObject(image, forKey: key, cost: ImageMemoryCache.cost(image))
                continuation.resume(returning: image)
            }
        }
    }
}
