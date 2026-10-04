import CoreGraphics
import Foundation
import ImageIO

struct SimilarImageFile: Identifiable, Hashable, Codable, Sendable {
    let file: DuplicateFile
    let pixelWidth: Int
    let pixelHeight: Int
    /// A thumbnail-based reference score, not a measure of artistic or original quality.
    let sharpnessScore: Double
    var id: String { file.id }
}

struct SimilarImageGroup: Identifiable, Sendable {
    let id: String
    let files: [SimilarImageFile]
}

struct SimilarImageScanResult: Sendable {
    var roots: [String] = []
    var groups: [SimilarImageGroup] = []
    var scannedFiles = 0
    var scannedPaths: Set<String> = []
    var processedImages = 0
    var reusedImages = 0
    var skippedFiles = 0
    var exactCopiesSkipped = 0
    var isPartial = false
    var cancelled = false
    var error: String?
}

/// Fingerprints are reusable only for the complete identity captured during
/// verified decoding. The bounded store avoids retaining every image thumbnail forever.
final class SimilarImageFeatureCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: SimilarImageScanner.Feature] = [:]
    private let maximumEntries = 12_000

    func encodedData() throws -> Data {
        lock.lock()
        let snapshot = entries
        lock.unlock()
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(snapshot)
    }

    func restore(from data: Data) {
        guard let saved = try? PropertyListDecoder().decode([String: SimilarImageScanner.Feature].self,
                                                           from: data) else { return }
        lock.lock()
        defer { lock.unlock() }
        for (path, feature) in saved where entries[path] == nil && entries.count < maximumEntries {
            // Corrupt cache data can never reach the matcher as an oversized vector.
            guard feature.image.file.path == path, feature.luminance.count == 1_024,
                  feature.meanColor.count == 3, feature.image.file.sha256.count == 64,
                  feature.aspectRatio.isFinite, feature.aspectRatio > 0 else { continue }
            entries[path] = feature
        }
    }

    func feature(for file: DuplicateFile) -> SimilarImageScanner.Feature? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[file.path], entry.image.file.identity == file.identity else { return nil }
        return entry
    }

    func remember(_ feature: SimilarImageScanner.Feature) {
        lock.lock()
        defer { lock.unlock() }
        let path = feature.image.file.path
        guard entries[path] != nil || entries.count < maximumEntries else { return }
        entries[path] = feature
    }

    func invalidate(paths: Set<String>) {
        guard !paths.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        entries = entries.filter { path, _ in
            !DuplicatePathMutation.contains(path, in: paths)
        }
    }

    func retainCurrentFiles(_ files: [DuplicateFile], roots: [String]) {
        let identities = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0.identity) })
        lock.lock()
        defer { lock.unlock() }
        entries = entries.filter { path, feature in
            !roots.contains { path.hasPrefix($0 + "/") } || identities[path] == feature.image.file.identity
        }
    }
}

/// Suggests visually similar still images. It never chooses files for deletion.
/// Full SHA-256 identities are retained so the normal deletion guard can reject stale results.
enum SimilarImageScanner {
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "webp", "bmp"]
    private static let sourceTypes: Set<String> = ["public.jpeg", "public.png", "public.heic", "public.heif",
                                                   "org.webmproject.webp", "com.microsoft.bmp"]
    static let maximumImageBytes: UInt64 = 128 * 1_024 * 1_024
    static let maximumPixels = 80_000_000
    static let thumbnailEdge = 128
    static let maximumComparisonsPerImage = 512
    static let maximumHashDistance = 6

    struct Feature: Codable, Sendable {
        let image: SimilarImageFile
        let hash: UInt64
        let luminance: [UInt8]
        let meanColor: [Double]
        let aspectRatio: Double
    }

    static func scan(roots: [String], control: DuplicateScanControl,
                     home: String = NSHomeDirectory(),
                     contentCache: DuplicateContentCache? = nil,
                     featureCache: SimilarImageFeatureCache? = nil,
                     progress: ((DuplicateScanProgress) -> Void)? = nil) -> SimilarImageScanResult {
        let discovery = DuplicateScanner.enumerate(roots: roots, control: control, home: home, progress: progress)
        var result = SimilarImageScanResult(roots: discovery.roots, scannedFiles: discovery.files.count,
                                           scannedPaths: Set(discovery.files.map(\.path)),
                                           skippedFiles: discovery.skippedFiles, isPartial: discovery.isPartial,
                                           cancelled: discovery.cancelled, error: discovery.error)
        guard !discovery.cancelled, discovery.error == nil else { return result }
        if !discovery.isPartial {
            contentCache?.retainCurrentFiles(discovery.files, roots: discovery.roots)
            featureCache?.retainCurrentFiles(discovery.files, roots: discovery.roots)
        }
        let candidates = discovery.files.filter { imageExtensions.contains(($0.path as NSString).pathExtension.lowercased()) }
            .sorted { $0.path < $1.path }
        var grouping = MatchingIndex()
        var seenDigests = Set<String>()
        var bytesRead: UInt64 = 0
        var lastProgress = -Double.infinity
        for (index, file) in candidates.enumerated() {
            if control.isCancelled { break }
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastProgress >= 0.15 {
                progress?(DuplicateScanProgress(phase: "similar-images", currentPath: file.path,
                                                scannedFiles: discovery.files.count, processedFiles: index,
                                                totalCandidates: candidates.count, bytesRead: bytesRead))
                lastProgress = now
            }
            do {
                try DuplicateScanner.validateUnchanged(file, allowedRoots: discovery.roots, control: control, home: home)
                if let cached = featureCache?.feature(for: file) {
                    guard !control.isCancelled else { break }
                    result.processedImages += 1
                    result.reusedImages += 1
                    guard seenDigests.insert(cached.image.file.sha256).inserted else {
                        result.exactCopiesSkipped += 1
                        continue
                    }
                    grouping.insert(cached)
                    continue
                }
                // Decode only a bounded thumbnail. Hashing afterwards also proves the decoded
                // file still has its enumerated identity, including nanosecond ctime/mtime.
                guard let decoded = autoreleasepool(invoking: { fingerprint(file) }) else {
                    result.skippedFiles += 1
                    result.isPartial = true
                    continue
                }
                let hashWasCached = contentCache?.digest(for: file, sample: false) != nil
                let verified = try DuplicateScanner.hash(file, allowedRoots: discovery.roots, control: control,
                                                         home: home, cache: contentCache)
                if !hashWasCached { bytesRead += verified.size }
                result.processedImages += 1
                let image = SimilarImageFile(file: verified, pixelWidth: decoded.width, pixelHeight: decoded.height,
                                             sharpnessScore: decoded.sharpness)
                let feature = Feature(image: image, hash: decoded.hash, luminance: decoded.luminance,
                                      meanColor: decoded.meanColor,
                                      aspectRatio: Double(decoded.width) / Double(decoded.height))
                featureCache?.remember(feature)
                guard seenDigests.insert(verified.sha256).inserted else {
                    result.exactCopiesSkipped += 1
                    continue
                }
                grouping.insert(feature)
            } catch {
                result.skippedFiles += 1
                result.isPartial = true
            }
        }
        if control.isCancelled {
            result.cancelled = true
            result.isPartial = true
            progress?(DuplicateScanProgress(phase: "cancelled", currentPath: "",
                                            scannedFiles: discovery.files.count, processedFiles: result.processedImages,
                                            totalCandidates: candidates.count, bytesRead: bytesRead))
            return result
        }
        progress?(DuplicateScanProgress(phase: "similar-grouping", currentPath: "",
                                        scannedFiles: discovery.files.count, processedFiles: candidates.count,
                                        totalCandidates: candidates.count, bytesRead: bytesRead))
        result.groups = grouping.groups
        result.isPartial = result.isPartial || grouping.limited
        if control.isCancelled {
            result.groups = []
            result.cancelled = true
            result.isPartial = true
        }
        progress?(DuplicateScanProgress(phase: result.cancelled ? "cancelled" : "finished", currentPath: "",
                                        scannedFiles: discovery.files.count, processedFiles: candidates.count,
                                        totalCandidates: candidates.count, bytesRead: bytesRead))
        return result
    }

    private struct Fingerprint {
        let width: Int
        let height: Int
        let hash: UInt64
        let luminance: [UInt8]
        let meanColor: [Double]
        let sharpness: Double
    }

    private static func fingerprint(_ file: DuplicateFile) -> Fingerprint? {
        guard file.size > 0, file.size <= maximumImageBytes,
              let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: file.path) as CFURL,
                                                      [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source), sourceTypes.contains(type as String),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let sourceWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let sourceHeight = properties[kCGImagePropertyPixelHeight] as? Int,
              sourceWidth > 0, sourceHeight > 0, sourceWidth <= 32_768, sourceHeight <= 32_768,
              sourceWidth <= maximumPixels / sourceHeight else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailEdge,
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              thumbnail.width <= thumbnailEdge, thumbnail.height <= thumbnailEdge,
              let pixels = rgba(thumbnail, width: 32, height: 32),
              let sharpPixels = rgba(thumbnail, width: 128, height: 128) else { return nil }
        let luma = luminance(pixels)
        var color = [Double](repeating: 0, count: 3)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            for channel in 0..<3 { color[channel] += Double(pixels[index + channel]) / 1_024 }
        }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let rotated = (5...8).contains(orientation)
        return Fingerprint(width: rotated ? sourceHeight : sourceWidth,
                           height: rotated ? sourceWidth : sourceHeight,
                           hash: perceptualHash(luma), luminance: luma, meanColor: color,
                           sharpness: sharpness(luminance(sharpPixels)))
    }

    /// Composite transparent images on white consistently, then normalize to sRGB.
    private static func rgba(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var data = [UInt8](repeating: 255, count: width * height * 4)
        let rendered = data.withUnsafeMutableBytes { bytes -> Bool in
            guard let color = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4, space: color,
                                          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                                            | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return rendered ? data : nil
    }

    private static func luminance(_ rgba: [UInt8]) -> [UInt8] {
        stride(from: 0, to: rgba.count, by: 4).map { index in
            let red = 77 * Int(rgba[index])
            let green = 150 * Int(rgba[index + 1])
            let blue = 29 * Int(rgba[index + 2])
            return UInt8((red + green + blue) >> 8)
        }
    }

    private static let cosine: [[Double]] = (0..<8).map { frequency in
        (0..<32).map { coordinate in cos(Double(2 * coordinate + 1) * Double(frequency) * .pi / 64) }
    }

    private static func perceptualHash(_ pixels: [UInt8]) -> UInt64 {
        // Separable 32x32 DCT: only the first eight frequencies are needed.
        var horizontal = [Double](repeating: 0, count: 32 * 8)
        for y in 0..<32 {
            for frequency in 0..<8 {
                var value = 0.0
                for x in 0..<32 { value += Double(pixels[y * 32 + x]) * cosine[frequency][x] }
                horizontal[y * 8 + frequency] = value
            }
        }
        var coefficients = [Double](repeating: 0, count: 64)
        for yFrequency in 0..<8 {
            for xFrequency in 0..<8 {
                for y in 0..<32 {
                    coefficients[yFrequency * 8 + xFrequency] += horizontal[y * 8 + xFrequency] * cosine[yFrequency][y]
                }
            }
        }
        let median = Array(coefficients.dropFirst()).sorted()[31]
        var hash: UInt64 = 0
        for index in 1..<64 where coefficients[index] > median { hash |= UInt64(1) << index }
        return hash
    }

    private static func sharpness(_ pixels: [UInt8]) -> Double {
        var sum = 0.0
        var squares = 0.0
        let count = Double(126 * 126)
        for y in 1..<127 {
            for x in 1..<127 {
                let index = y * 128 + x
                let value = Double(4 * Int(pixels[index]) - Int(pixels[index - 1]) - Int(pixels[index + 1])
                                   - Int(pixels[index - 128]) - Int(pixels[index + 128]))
                sum += value
                squares += value * value
            }
        }
        let variance = max(0, squares / count - pow(sum / count, 2))
        return 100 * variance / (variance + 500)
    }

    static func matches(_ lhs: Feature, _ rhs: Feature) -> Bool {
        guard (lhs.hash ^ rhs.hash).nonzeroBitCount <= maximumHashDistance,
              abs(log(lhs.aspectRatio / rhs.aspectRatio)) <= 0.04,
              lhs.luminance.count == 1_024, rhs.luminance.count == 1_024,
              lhs.meanColor.count == 3, rhs.meanColor.count == 3,
              zip(lhs.meanColor, rhs.meanColor).allSatisfy({ abs($0 - $1) <= 22 }) else { return false }
        let difference = zip(lhs.luminance, rhs.luminance).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        return difference <= 1_024 * 20
    }

    /// Seven disjoint bands guarantee an exact band for a Hamming distance <= 6.
    /// Index representatives only: B resembling A never makes C a member through B.
    static func group(_ features: [Feature], control: DuplicateScanControl) -> (groups: [SimilarImageGroup], limited: Bool) {
        var index = MatchingIndex()
        for feature in features {
            if control.isCancelled { return ([], index.limited) }
            index.insert(feature)
        }
        return (index.groups, index.limited)
    }

    /// Keep full fingerprints only for representatives; members retain their file identities.
    private struct MatchingIndex {
        var buckets: [UInt16: [Int]] = [:]
        var representatives: [Feature] = []
        var members: [[SimilarImageFile]] = []
        var limited = false

        mutating func insert(_ feature: Feature) {
            let keys = bandKeys(feature.hash)
            let candidates = keys.compactMap { buckets[$0] }.sorted { $0.count < $1.count }
            var checked = Set<Int>()
            var matched: Int?
            search: for bucket in candidates {
                for index in bucket where !checked.contains(index) {
                    if checked.count == maximumComparisonsPerImage {
                        limited = true
                        break search
                    }
                    checked.insert(index)
                    if matches(feature, representatives[index]) {
                        matched = index
                        break search
                    }
                }
            }
            if let matched {
                members[matched].append(feature.image)
            } else {
                let index = representatives.count
                representatives.append(feature)
                members.append([feature.image])
                for key in keys { buckets[key, default: []].append(index) }
            }
        }

        var groups: [SimilarImageGroup] {
            members.filter { $0.count > 1 }.map { SimilarImageGroup(id: $0[0].id, files: $0) }
        }
    }

    private static func bandKeys(_ hash: UInt64) -> [UInt16] {
        var offset = 0
        return (0..<7).map { band in
            let width = band == 0 ? 10 : 9
            let value = UInt16((hash >> offset) & ((UInt64(1) << width) - 1)) | UInt16(band << 10)
            offset += width
            return value
        }
    }
}
