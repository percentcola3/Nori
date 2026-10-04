import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main
struct SimilarImageScannerTests {
    static let fm = FileManager.default

    static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() {
            FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
            exit(1)
        }
    }

    static func main() throws {
        let home = URL(fileURLWithPath: CommandLine.arguments[1]).standardized.appendingPathComponent("home")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        let representative = try testVariants(home: home)
        try testOrientation(home: home)
        try testUnsupported(home: home)
        try testCancellationAndChange(home: home)
        try testIncrementalReuse(home: home)
        testGrouping(representative)
        print("Similar images: recompression/resizing, orientation, exact-copy exclusion, format guards, cancellation, stale files and bounded representative grouping passed")
    }

    static func image(width: Int = 320, height: Int = 240, variant: Int = 0) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let u = Double(x) / Double(width)
                let v = Double(y) / Double(height)
                let offset = (y * width + x) * 4
                for channel in 0..<3 {
                    let c = Double(channel + 1)
                    let value = 120 + 35 * sin(u * 13 + v * 7 + c)
                        + 30 * cos(u * 3 - v * 17 + c * 2) + 25 * sin(u * 29 + v * 23 + c)
                    bytes[offset + channel] = variant == 0 ? UInt8(max(0, min(255, value)))
                        : (channel == 2 ? 230 : 10)
                }
            }
        }
        return bytes.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        }
    }

    static func write(_ image: CGImage, to url: URL, type: UTType = .png, quality: Double = 0.8,
                      orientation: Int = 1, frames: Int = 1) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, frames, nil)!
        for _ in 0..<frames {
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality,
                                                          kCGImagePropertyOrientation: orientation] as CFDictionary)
        }
        expect(CGImageDestinationFinalize(destination), "cannot encode fixture \(url.lastPathComponent)")
    }

    static func scan(_ root: URL, home: URL, control: DuplicateScanControl = DuplicateScanControl(),
                     progress: ((DuplicateScanProgress) -> Void)? = nil) -> SimilarImageScanResult {
        SimilarImageScanner.scan(roots: [root.path], control: control, home: home.path, progress: progress)
    }

    static func testVariants(home: URL) throws -> SimilarImageFile {
        let root = home.appendingPathComponent("Documents/Variants")
        let original = root.appendingPathComponent("original.png")
        try write(image(), to: original)
        try write(image(width: 160, height: 120), to: root.appendingPathComponent("smaller.jpg"), type: .jpeg, quality: 0.8)
        try write(image(), to: root.appendingPathComponent("compressed.jpg"), type: .jpeg, quality: 0.5)
        try fm.copyItem(at: original, to: root.appendingPathComponent("identical.png"))
        try write(image(variant: 1), to: root.appendingPathComponent("different.png"))
        try write(image(width: 320, height: 100), to: root.appendingPathComponent("different-ratio.png"))
        let result = scan(root, home: home)
        expect(result.error == nil && !result.cancelled && !result.isPartial,
               "ordinary scan must complete: error=\(result.error ?? "none"), partial=\(result.isPartial), skipped=\(result.skippedFiles), processed=\(result.processedImages)")
        expect(result.exactCopiesSkipped == 1, "exact bytes must not be added as similar copies")
        expect(result.groups.count == 1, "resized/recompressed image should form one group, got \(result.groups.count)")
        let files = result.groups[0].files
        expect(files.count == 3, "only three distinct encodings should be grouped: \(files.map { $0.file.name })")
        expect(!files.contains { $0.file.name.hasPrefix("different") }, "different image/aspect must stay out")
        expect(Set(files.map { $0.file.sha256 }).count == 3, "each image must retain distinct full SHA256")
        expect(files.allSatisfy { $0.file.sha256.count == 64 }, "missing deletion verification hash")
        expect(files.contains { $0.pixelWidth == 160 && $0.pixelHeight == 120 }, "dimensions missing")
        expect(files.allSatisfy { (0...100).contains($0.sharpnessScore) }, "invalid clarity reference")
        return files[0]
    }

    static func testOrientation(home: URL) throws {
        let root = home.appendingPathComponent("Pictures/Orientation")
        let tagged = root.appendingPathComponent("tagged.jpg")
        try write(image(), to: tagged, type: .jpeg, quality: 0.95, orientation: 6)
        let source = CGImageSourceCreateWithURL(tagged as CFURL, nil)!
        let normalized = CGImageSourceCreateThumbnailAtIndex(source, 0,
            [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
             kCGImageSourceThumbnailMaxPixelSize: 320] as CFDictionary)!
        try write(normalized, to: root.appendingPathComponent("normalized.png"))
        let result = scan(root, home: home)
        expect(result.groups.count == 1 && result.groups[0].files.count == 2, "EXIF rotation must be normalized")
        expect(result.groups[0].files.allSatisfy { $0.pixelWidth == 240 && $0.pixelHeight == 320 },
               "display dimensions should account for EXIF rotation")
    }

    static func testUnsupported(home: URL) throws {
        let root = home.appendingPathComponent("Pictures/Unsupported")
        try write(image(), to: root.appendingPathComponent("animated.jpg"), type: .gif, frames: 2)
        try write(image(), to: root.appendingPathComponent("multipage.png"), type: .tiff, frames: 2)
        try write(image(), to: root.appendingPathComponent("disguised-tiff.jpg"), type: .tiff)
        try write(image(), to: root.appendingPathComponent("Albums.photoslibrary/a.jpg"), type: .jpeg)
        try write(image(), to: root.appendingPathComponent("App.app/a.jpg"), type: .jpeg)
        try write(image(), to: home.appendingPathComponent("Library/Containers/chat/attachment.jpg"), type: .jpeg)
        let result = scan(root, home: home)
        expect(result.groups.isEmpty && result.processedImages == 0, "unsupported containers or packages decoded")
        expect(result.skippedFiles >= 3, "unsupported files should be counted")
        let privateResult = scan(home.appendingPathComponent("Library"), home: home)
        expect(privateResult.groups.isEmpty && privateResult.processedImages == 0, "private app data scanned")
    }

    static func testCancellationAndChange(home: URL) throws {
        let root = home.appendingPathComponent("Documents/Change")
        let target = root.appendingPathComponent("a.png")
        try write(image(), to: target)
        try write(image(), to: root.appendingPathComponent("b.jpg"), type: .jpeg)
        let cancelled = DuplicateScanControl()
        cancelled.cancel()
        expect(scan(root, home: home, control: cancelled).cancelled, "pre-cancelled scan continued")
        let during = DuplicateScanControl()
        let result = scan(root, home: home, control: during) { progress in
            if progress.phase == "similar-images" { during.cancel() }
        }
        expect(result.cancelled && result.groups.isEmpty, "cancellation should not publish actionable partial groups")
        var replaced = false
        let changed = scan(root, home: home) { progress in
            if progress.phase == "similar-images", progress.currentPath == target.path, !replaced {
                replaced = true
                try! write(image(variant: 1), to: target)
            }
        }
        expect(replaced && changed.isPartial && changed.groups.isEmpty, "changed image must fail scan identity verification")
    }

    static func testIncrementalReuse(home: URL) throws {
        let root = home.appendingPathComponent("Pictures/Cache")
        let first = root.appendingPathComponent("a.png")
        let second = root.appendingPathComponent("b.jpg")
        let copy = root.appendingPathComponent("c.png")
        try write(image(), to: first)
        try write(image(), to: second, type: .jpeg, quality: 0.7)
        try fm.copyItem(at: first, to: copy)
        let contentCache = DuplicateContentCache(), featureCache = SimilarImageFeatureCache()
        var reads: UInt64 = 0
        func scan() -> SimilarImageScanResult {
            SimilarImageScanner.scan(roots: [root.path], control: DuplicateScanControl(), home: home.path,
                contentCache: contentCache, featureCache: featureCache) { reads = $0.bytesRead }
        }
        let initial = scan()
        expect(initial.groups.count == 1 && initial.exactCopiesSkipped == 1 && initial.reusedImages == 0 && reads > 0,
               "first image scan must decode and hash every candidate, including excluded exact copies")
        let repeated = scan()
        expect(repeated.groups.count == 1 && repeated.exactCopiesSkipped == 1
               && repeated.reusedImages == 3 && reads == 0,
               "repeated image scan must reuse every verified fingerprint and complete hash")
        let restoredContent = DuplicateContentCache(), restoredFeatures = SimilarImageFeatureCache()
        restoredContent.restore(from: try contentCache.encodedData())
        restoredFeatures.restore(from: try featureCache.encodedData())
        let restored = SimilarImageScanner.scan(roots: [root.path], control: DuplicateScanControl(), home: home.path,
            contentCache: restoredContent, featureCache: restoredFeatures)
        expect(restored.reusedImages == 3 && restored.groups.count == 1 && restored.exactCopiesSkipped == 1,
               "persisted image fingerprints must remain reusable after reloading their complete identity")
        try write(image(variant: 1), to: first)
        let changed = scan()
        expect(changed.groups.count == 1 && changed.reusedImages == 2 && changed.exactCopiesSkipped == 0 && reads > 0,
               "a changed image must be decoded again while unchanged image fingerprints remain reusable")
        featureCache.invalidate(paths: [root.path])
        let invalidated = scan()
        expect(invalidated.reusedImages == 0 && reads == 0,
               "invalidating fingerprints must re-decode images while independent verified content hashes remain reusable")
    }

    static func testGrouping(_ sample: SimilarImageFile) {
        func feature(_ index: Int, hash: UInt64, ratio: Double = 1.0) -> SimilarImageScanner.Feature {
            let file = DuplicateFile(path: sample.file.path + "-\(index)", name: "\(index)", size: sample.file.size,
                                     identity: sample.file.identity, sha256: "\(index)")
            let image = SimilarImageFile(file: file, pixelWidth: 100, pixelHeight: 100, sharpnessScore: 1)
            return SimilarImageScanner.Feature(image: image, hash: hash, luminance: [UInt8](repeating: 100, count: 1_024),
                                               meanColor: [100, 100, 100], aspectRatio: ratio)
        }
        let a = feature(0, hash: 0)
        let b = feature(1, hash: 0b11_1111)
        let c = feature(2, hash: 0b1111_1111_1111)
        expect(SimilarImageScanner.matches(a, b) && SimilarImageScanner.matches(b, c), "chain fixture invalid")
        expect(!SimilarImageScanner.matches(a, c), "chain endpoints must differ")
        let chain = SimilarImageScanner.group([a, b, c], control: DuplicateScanControl())
        expect(chain.groups.count == 1 && chain.groups[0].files.count == 2, "transitive similarity joined unlike endpoints")
        let busy = (0..<530).map { feature($0, hash: 0, ratio: pow(1.08, Double($0))) }
        let limited = SimilarImageScanner.group(busy, control: DuplicateScanControl())
        expect(limited.limited && limited.groups.isEmpty, "comparison limit must be observable and not create false matches")
        let cancelled = DuplicateScanControl()
        cancelled.cancel()
        expect(SimilarImageScanner.group([a, b], control: cancelled).groups.isEmpty, "grouping ignores cancellation")
    }
}
