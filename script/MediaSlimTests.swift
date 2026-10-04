import AVFoundation
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main
struct MediaSlimTests {
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() {
            FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
            exit(1)
        }
    }

    static let fm = FileManager.default

    static func main() async throws {
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL.resolvingSymlinksInPath()
        let home = fixture.appendingPathComponent("home")
        let trashDir = fixture.appendingPathComponent("trash")
        try fm.createDirectory(at: trashDir, withIntermediateDirectories: true)

        try testPolicy(home: home.path)
        try testScanCollectsMedia(home: home)

        var trashed: [String] = []
        let slimmer = MediaSlimmer(home: home.path) { url in
            let target = trashDir.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
            try fm.moveItem(at: url, to: target)
            trashed.append(url.path)
        }
        try await testImageReplace(home: home, slimmer: slimmer, trashed: { trashed })
        try await testImageCopy(home: home, slimmer: slimmer)
        try await testImageNotSmaller(home: home, slimmer: slimmer)
        try await testLosslessFormats(home: home, slimmer: slimmer, trashed: { trashed })
        try await testLongEdgeLimit(home: home, slimmer: slimmer)
        try await testArchive(home: home, slimmer: slimmer, trashed: { trashed })
        try await testRefusals(home: home, slimmer: slimmer)
        try await testVideo(home: home, slimmer: slimmer, trashed: { trashed })
        print("Media slimming: eligibility, scan index, image/video/archive outcomes and guards passed")
    }

    // MARK: 资格

    static func testPolicy(home: String) throws {
        let eligible = ["\(home)/Pictures/a.jpg", "\(home)/Desktop/clip.MOV",
                        "\(home)/Documents/Project/big.bin", "/Volumes/Ext/Footage/a.mp4"]
        for path in eligible {
            expect(MediaSlimPolicy.isEligible(path, home: home), "eligible path rejected: \(path)")
        }
        let refused = ["\(home)/Library/Caches/a.jpg", "\(home)/.cache/a.jpg",
                       "\(home)/Pictures/Photos Library.photoslibrary/originals/a.heic",
                       "\(home)/Apps/Foo.app/Contents/Resources/a.png",
                       "\(home)/code/web/node_modules/pkg/a.png",
                       "\(home)/Movies/Show.fcpbundle/media/a.mov",
                       "\(home)/Pictures/../Library/a.jpg", "\(home)", "/tmp/a.jpg",
                       "/Volumes/Ext", "/Volumes/Ext/.Trashes/a.mov", "/Users/Shared/a.jpg"]
        for path in refused {
            expect(!MediaSlimPolicy.isEligible(path, home: home), "ineligible path accepted: \(path)")
        }
        expect(MediaSlimPolicy.kind(forPath: "/x/A.HEIC") == .image, "uppercase image extension")
        expect(MediaSlimPolicy.kind(forPath: "/x/a.mkv") == .video, "video extension")
        expect(MediaSlimPolicy.kind(forPath: "/x/a.cr3") == nil, "RAW files must not be re-encoded")
        expect(SlimOperation.operation(for: "/x/a.dmg") == .archive, "non-media files are zipped")
    }

    // MARK: 扫描

    static func write(_ url: URL, bytes: Int, random: Bool = true) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data(count: bytes)
        if random {
            data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, bytes) }
        }
        try data.write(to: url)
    }

    static func testScanCollectsMedia(home: URL) throws {
        let root = home.appendingPathComponent("ScanRoot")
        try write(root.appendingPathComponent("Pictures/big.jpg"), bytes: 1_600_000)
        try write(root.appendingPathComponent("Pictures/small.jpg"), bytes: 20_000)
        try write(root.appendingPathComponent("Movies/clip.mov"), bytes: 21 * 1_048_576)
        try write(root.appendingPathComponent("Movies/short.mp4"), bytes: 2 * 1_048_576)
        try write(root.appendingPathComponent("Old.photoslibrary/originals/p.jpg"), bytes: 2_000_000)
        try write(root.appendingPathComponent(".hidden/h.jpg"), bytes: 2_000_000)
        try write(root.appendingPathComponent("top.png"), bytes: 1_200_000)

        let report = DiskAnalysisWorker.scan(root.path, control: CleanupScanControl(mode: .deep),
                                             home: home.path)
        let paths = Set((report.media ?? []).map(\.path))
        expect(paths == [root.appendingPathComponent("Pictures/big.jpg").path,
                         root.appendingPathComponent("Movies/clip.mov").path,
                         root.appendingPathComponent("top.png").path],
               "scan media index mismatch: \(paths.sorted())")
        let summary = report.mediaSummary ?? MediaSummary()
        expect(summary.imageCount == 2 && summary.videoCount == 1, "media summary counts: \(summary)")
        expect(summary.videoBytes >= 21 * 1_048_576, "video bytes use allocated size")
        let pictures = report.directoryReports?[root.appendingPathComponent("Pictures").path]
        expect(pictures?.media?.map(\.name) == ["big.jpg"], "per-directory media index")
        expect(pictures?.mediaSummary?.imageCount == 1, "per-directory summary")

        var many: [MediaFile] = (0..<(MediaSlimPolicy.perKindCap * 5)).map {
            MediaFile(name: "\($0)", path: "/p/\($0).jpg", size: UInt64($0), kind: .image)
        }
        many.append(MediaFile(name: "v", path: "/p/v.mov", size: 1, kind: .video))
        DiskAnalysisWorker.trimMedia(&many)
        expect(many.filter { $0.kind == .image }.count == MediaSlimPolicy.perKindCap,
               "per-kind cap not enforced")
        expect(many.contains { $0.kind == .video }, "a small video was evicted by images")
        expect(many.first?.size == UInt64(MediaSlimPolicy.perKindCap * 5 - 1), "trim keeps the largest")
        try fm.removeItem(at: root)
    }

    // MARK: 图片夹具

    static func makeImage(_ url: URL, width: Int, height: Int, type: UTType, quality: Double = 1.0,
                          noise: Bool = true) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                let n: UInt8 = noise ? UInt8.random(in: 0...40) : 0
                pixels[offset] = UInt8(truncatingIfNeeded: x / 8) &+ n
                pixels[offset + 1] = UInt8(truncatingIfNeeded: y / 8) &+ n
                pixels[offset + 2] = UInt8(truncatingIfNeeded: (x + y) / 16) &+ n
                pixels[offset + 3] = 255
            }
        }
        let space = CGColorSpaceCreateDeviceRGB()
        let image = pixels.withUnsafeMutableBytes { raw -> CGImage? in
            let context = CGContext(data: raw.baseAddress, width: width, height: height,
                                    bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: space,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            return context?.makeImage()
        }
        guard let image,
              let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)
        else { throw NSError(domain: "fixture", code: 1) }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        expect(CGImageDestinationFinalize(destination), "fixture image encode failed")
    }

    static func size(_ url: URL) -> UInt64 {
        ((try? fm.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.uint64Value ?? 0
    }

    static func noTemporaryFiles(in directory: URL) -> Bool {
        let names = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        return !names.contains { $0.contains(".nori-slim-") }
    }

    static func pixelSize(_ url: URL) -> (Int, Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return (0, 0) }
        return (props[kCGImagePropertyPixelWidth] as? Int ?? 0, props[kCGImagePropertyPixelHeight] as? Int ?? 0)
    }

    // MARK: 图片

    static func testImageReplace(home: URL, slimmer: MediaSlimmer, trashed: () -> [String]) async throws {
        let photo = home.appendingPathComponent("Pictures/photo.jpg")
        try makeImage(photo, width: 2400, height: 1600, type: .jpeg)
        let past = Date(timeIntervalSince1970: 1_600_000_000)
        try fm.setAttributes([.modificationDate: past], ofItemAtPath: photo.path)
        let before = size(photo)
        let outcome = await slimmer.slim(path: photo.path, options: SlimOptions())
        expect(outcome.status == .slimmed, "JPEG was not slimmed: \(outcome)")
        expect(outcome.outputPath == photo.path && outcome.replaced, "replace mode did not keep the name")
        expect(size(photo) == outcome.newBytes && outcome.newBytes < before, "replaced file is not smaller")
        expect(outcome.savedBytes == before - outcome.newBytes, "saved bytes accounting")
        expect(trashed().contains(photo.path), "original was not moved to the Trash")
        let modified = (try fm.attributesOfItem(atPath: photo.path)[.modificationDate] as? Date)
        expect(modified == past, "modification date not preserved")
        expect(pixelSize(photo) == (2400, 1600), "keep-size compression changed dimensions")
        expect(noTemporaryFiles(in: photo.deletingLastPathComponent()), "temporary output left behind")
    }

    static func testImageCopy(home: URL, slimmer: MediaSlimmer) async throws {
        let photo = home.appendingPathComponent("Pictures/copy.jpg")
        try makeImage(photo, width: 2000, height: 1400, type: .jpeg)
        let before = size(photo)
        var options = SlimOptions()
        options.replaceOriginal = false
        let outcome = await slimmer.slim(path: photo.path, options: options)
        let copy = home.appendingPathComponent("Pictures/copy-slim.jpg")
        expect(outcome.status == .slimmed && outcome.outputPath == copy.path, "copy mode output: \(outcome)")
        expect(size(photo) == before && fm.fileExists(atPath: copy.path), "copy mode touched the original")
        expect(outcome.savedBytes == 0 && !outcome.replaced, "copy mode reports freed space")
        let again = await slimmer.slim(path: photo.path, options: options)
        expect(again.outputPath == home.appendingPathComponent("Pictures/copy-slim-2.jpg").path,
               "copy mode overwrote an existing copy: \(again)")
    }

    static func testImageNotSmaller(home: URL, slimmer: MediaSlimmer) async throws {
        let photo = home.appendingPathComponent("Pictures/already.jpg")
        try makeImage(photo, width: 1600, height: 1200, type: .jpeg, quality: 0.3)
        let before = size(photo)
        var options = SlimOptions()
        options.quality = .high
        let outcome = await slimmer.slim(path: photo.path, options: options)
        expect(outcome.status == .notSmaller, "low-quality JPEG re-encoded upward: \(outcome)")
        expect(size(photo) == before, "not-smaller result replaced the original")
        expect(noTemporaryFiles(in: photo.deletingLastPathComponent()), "discarded result left a temp file")
    }

    static func testLosslessFormats(home: URL, slimmer: MediaSlimmer, trashed: () -> [String]) async throws {
        let png = home.appendingPathComponent("Desktop/shot.png")
        try makeImage(png, width: 1600, height: 1000, type: .png)
        let keep = await slimmer.slim(path: png.path, options: SlimOptions())
        expect(keep.status == .unsupported && keep.message == "slim.reason.lossless",
               "PNG keep-format should be unsupported: \(keep)")
        expect(fm.fileExists(atPath: png.path), "unsupported PNG was modified")

        let writable = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        guard writable.contains(UTType.heic.identifier) else {
            print("note: HEIC encoder unavailable; skipped PNG→HEIC")
            return
        }
        var options = SlimOptions()
        options.imageFormat = .heic
        let converted = await slimmer.slim(path: png.path, options: options)
        let heic = home.appendingPathComponent("Desktop/shot.heic")
        expect(converted.status == .slimmed && converted.outputPath == heic.path, "PNG→HEIC: \(converted)")
        expect(!fm.fileExists(atPath: png.path) && trashed().contains(png.path), "PNG original not trashed")

        let animated = home.appendingPathComponent("Desktop/anim.gif")
        try makeImage(animated, width: 64, height: 64, type: .gif)
        let gif = await slimmer.slim(path: animated.path, options: SlimOptions())
        expect(gif.status == .unsupported, "GIF keep-format should be unsupported")
    }

    static func testLongEdgeLimit(home: URL, slimmer: MediaSlimmer) async throws {
        let big = home.appendingPathComponent("Pictures/huge.jpg")
        try makeImage(big, width: 5000, height: 3000, type: .jpeg)
        var options = SlimOptions()
        options.limitLongEdge = true
        let outcome = await slimmer.slim(path: big.path, options: options)
        expect(outcome.status == .slimmed, "long-edge limit: \(outcome)")
        let (width, height) = pixelSize(big)
        expect(max(width, height) == SlimOptions.longEdgeLimit && width > height,
               "long edge not limited: \(width)x\(height)")
    }

    // MARK: 打包

    static func testArchive(home: URL, slimmer: MediaSlimmer, trashed: () -> [String]) async throws {
        let log = home.appendingPathComponent("Documents/server.log")
        try fm.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try String(repeating: "2026-09-29 INFO request handled in 12ms\n", count: 60_000)
            .write(to: log, atomically: true, encoding: .utf8)
        let outcome = await slimmer.slim(path: log.path, options: SlimOptions())
        let zip = home.appendingPathComponent("Documents/server.log.zip")
        expect(outcome.status == .slimmed && outcome.outputPath == zip.path, "archive: \(outcome)")
        expect(!fm.fileExists(atPath: log.path) && trashed().contains(log.path), "archived original not trashed")
        let listing = Process()
        listing.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        listing.arguments = ["-l", zip.path]
        let pipe = Pipe()
        listing.standardOutput = pipe
        try listing.run()
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        listing.waitUntilExit()
        expect(text.contains("server.log"), "zip does not contain the original file")

        let random = home.appendingPathComponent("Documents/blob.bin")
        try write(random, bytes: 2 * 1_048_576)
        let incompressible = await slimmer.slim(path: random.path, options: SlimOptions())
        expect(incompressible.status == .notSmaller, "random data zip should be discarded: \(incompressible)")
        expect(fm.fileExists(atPath: random.path)
               && !fm.fileExists(atPath: random.path + ".zip")
               && noTemporaryFiles(in: random.deletingLastPathComponent()), "discarded zip left behind")
    }

    // MARK: 拒绝

    static func testRefusals(home: URL, slimmer: MediaSlimmer) async throws {
        let library = home.appendingPathComponent("Library/Caches/cache.jpg")
        try makeImage(library, width: 800, height: 600, type: .jpeg)
        let refused = await slimmer.slim(path: library.path, options: SlimOptions())
        expect(refused.status == .failed && refused.message == "slim.reason.location", "Library file accepted")
        expect(fm.fileExists(atPath: library.path), "refused file was touched")

        let target = home.appendingPathComponent("Pictures/photo.jpg")
        let link = home.appendingPathComponent("Pictures/link.jpg")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
        let symlink = await slimmer.slim(path: link.path, options: SlimOptions())
        expect(symlink.status == .failed && symlink.message == "slim.reason.notFile", "symlink accepted")

        let originalFolder = home.appendingPathComponent("Pictures/cached-folder")
        let movedFolder = home.appendingPathComponent("Pictures/moved-folder")
        let cachedPhoto = originalFolder.appendingPathComponent("cached.jpg")
        try makeImage(cachedPhoto, width: 800, height: 600, type: .jpeg)
        let originalData = try Data(contentsOf: cachedPhoto)
        try fm.moveItem(at: originalFolder, to: movedFolder)
        try fm.createSymbolicLink(at: originalFolder, withDestinationURL: movedFolder)
        let replacedParent = await slimmer.slim(path: cachedPhoto.path, options: SlimOptions())
        expect(replacedParent.status == .failed && replacedParent.message == "slim.reason.notFile",
               "a cached path with a replaced parent must not be compressed")
        let remainingData = try Data(contentsOf: movedFolder.appendingPathComponent("cached.jpg"))
        expect(remainingData == originalData,
               "refusing a replaced parent must preserve the original bytes")

        let staleOutcome = await slimmer.slim(path: target.path, options: SlimOptions(), validateSource: { false })
        expect(staleOutcome.status == .failed && staleOutcome.message == "slim.reason.changed",
               "a stale scan identity must be rejected before compression")

        let failingTrash = MediaSlimmer(home: home.path) { _ in
            throw NSError(domain: "trash", code: 1)
        }
        let photo = home.appendingPathComponent("Pictures/keep.jpg")
        try makeImage(photo, width: 2000, height: 1400, type: .jpeg)
        let before = size(photo)
        let blocked = await failingTrash.slim(path: photo.path, options: SlimOptions())
        expect(blocked.status == .failed && blocked.message == "slim.reason.trash", "trash failure: \(blocked)")
        expect(size(photo) == before && noTemporaryFiles(in: photo.deletingLastPathComponent()),
               "trash failure left the original changed or a temp file behind")
    }

    // MARK: 视频

    static func makeVideo(_ url: URL, width: Int, height: Int, frames: Int) async throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 40_000_000]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                          kCVPixelBufferWidthKey as String: width,
                                          kCVPixelBufferHeightKey as String: height])
        writer.add(input)
        expect(writer.startWriting(), "video writer failed to start")
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 5_000_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            guard let buffer else { throw NSError(domain: "fixture", code: 2) }
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let row = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<height {
                for x in 0..<width {
                    let offset = y * row + x * 4
                    base[offset] = UInt8(truncatingIfNeeded: x + frame * 4)
                    base[offset + 1] = UInt8(truncatingIfNeeded: y + frame * 2)
                    base[offset + 2] = UInt8(truncatingIfNeeded: (x ^ y) + frame)
                    base[offset + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        expect(writer.status == .completed, "video fixture failed: \(String(describing: writer.error))")
    }

    static func testVideo(home: URL, slimmer: MediaSlimmer, trashed: () -> [String]) async throws {
        let bogus = home.appendingPathComponent("Movies/old.mkv")
        try write(bogus, bytes: 1_048_576)
        let unsupported = await slimmer.slim(path: bogus.path, options: SlimOptions())
        expect(unsupported.status == .unsupported && unsupported.message == "slim.reason.container",
               "unreadable container: \(unsupported)")
        expect(fm.fileExists(atPath: bogus.path) && noTemporaryFiles(in: bogus.deletingLastPathComponent()),
               "unsupported video was touched")

        let clip = home.appendingPathComponent("Movies/clip.mov")
        try await makeVideo(clip, width: 1920, height: 1080, frames: 60)
        let before = size(clip)
        var progressSeen = false
        let outcome = await slimmer.slim(path: clip.path, options: SlimOptions(), progress: { _ in progressSeen = true })
        print("note: video outcome \(outcome.status) \(before) -> \(outcome.newBytes)")
        expect(outcome.status == .slimmed || outcome.status == .notSmaller, "video transcode: \(outcome)")
        if outcome.status == .slimmed {
            expect(outcome.outputPath == clip.path && size(clip) < before, "transcoded video not smaller")
            expect(trashed().contains(clip.path), "video original not trashed")
            let tracks = try await AVURLAsset(url: clip).loadTracks(withMediaType: .video)
            expect(!tracks.isEmpty, "transcoded video has no video track")
        } else {
            expect(size(clip) == before, "not-smaller video was replaced")
        }
        expect(progressSeen, "video progress was never reported")
        expect(noTemporaryFiles(in: clip.deletingLastPathComponent()), "video temp output left behind")
    }
}
