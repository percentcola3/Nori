import AVFoundation
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 哪些文件属于"用户自己管理的媒体"，可以被瘦身。扫描与执行共用这一份判定。
enum MediaSlimPolicy {
    /// RAW/PSD 不收：重新编码会丢掉用户保留它们的编辑数据。
    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "webp", "tif", "tiff", "bmp", "gif"
    ]
    static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "mkv", "avi", "wmv", "flv", "webm", "mpg", "mpeg", "3gp", "mts", "m2ts"
    ]
    static let imageMinimumBytes: UInt64 = 1 << 20
    static let videoMinimumBytes: UInt64 = 20 << 20
    static let perKindCap = 300

    /// 应用、图库与工程包内部的媒体由各自的 App 引用，改动会破坏它们的索引。
    private static let packageExtensions: Set<String> = [
        "app", "appex", "framework", "bundle", "plugin", "photoslibrary", "photolibrary",
        "aplibrary", "migratedphotolibrary", "imovielibrary", "fcpbundle", "tvlibrary",
        "musiclibrary", "logicx", "band", "xcassets", "xcodeproj", "xcworkspace", "sketch"
    ]
    private static let excludedComponents: Set<String> = ["node_modules", "Pods", "DerivedData"]

    static func kind(forPath path: String) -> MediaKind? {
        let ext = (path as NSString).pathExtension.lowercased()
        if imageExtensions.contains(ext) { return .image }
        if videoExtensions.contains(ext) { return .video }
        return nil
    }

    static func minimumBytes(for kind: MediaKind) -> UInt64 {
        kind == .image ? imageMinimumBytes : videoMinimumBytes
    }

    /// 只接受家目录（不含 ~/Library）与外接卷下、没有隐藏目录和包目录的普通路径。
    static func isEligible(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard standardized == path else { return false }
        let homeRoot = URL(fileURLWithPath: home).standardizedFileURL.path
        var relative: [String]
        if standardized.hasPrefix(homeRoot + "/") {
            relative = String(standardized.dropFirst(homeRoot.count + 1)).components(separatedBy: "/")
            guard relative.first != "Library" else { return false }
        } else if standardized.hasPrefix("/Volumes/") {
            relative = String(standardized.dropFirst("/Volumes/".count)).components(separatedBy: "/")
            guard relative.count >= 2 else { return false }
            relative.removeFirst()
        } else {
            return false
        }
        guard !relative.isEmpty else { return false }
        for component in relative {
            if component.isEmpty || component.hasPrefix(".") { return false }
            if excludedComponents.contains(component) { return false }
            let ext = (component as NSString).pathExtension.lowercased()
            if component != relative.last, packageExtensions.contains(ext) { return false }
        }
        return true
    }
}

struct SlimOptions: Equatable {
    enum ImageFormat: String, CaseIterable { case keep, heic }
    enum Quality: String, CaseIterable {
        case high, medium, low
        var value: Double {
            switch self {
            case .high: return 0.85
            case .medium: return 0.72
            case .low: return 0.55
            }
        }
    }
    enum VideoPreset: String, CaseIterable { case original, p1080 }

    var imageFormat: ImageFormat = .keep
    var quality: Quality = .medium
    var limitLongEdge = false
    var videoPreset: VideoPreset = .p1080
    var replaceOriginal = true

    static let longEdgeLimit = 4096
    /// 结果至少要比原件小 10% 才保留，否则视为"已经足够小"。
    static let minimumSavingRatio = 0.9
}

enum SlimOperation: Equatable {
    case compressImage, transcodeVideo, archive

    static func operation(for path: String) -> SlimOperation {
        switch MediaSlimPolicy.kind(forPath: path) {
        case .image: return .compressImage
        case .video: return .transcodeVideo
        case nil: return .archive
        }
    }
}

struct SlimOutcome: Equatable {
    enum Status: Equatable { case slimmed, notSmaller, unsupported, failed, cancelled }
    let path: String
    let status: Status
    let originalBytes: UInt64
    let newBytes: UInt64
    let outputPath: String?
    let message: String?
    let replaced: Bool

    /// 替换模式下释放（原件进废纸篓后）的空间；副本模式不释放空间。
    var savedBytes: UInt64 {
        guard status == .slimmed, replaced, originalBytes > newBytes else { return 0 }
        return originalBytes - newBytes
    }
}

/// 文件瘦身执行器：结果先写到同目录的隐藏临时文件，确认变小且原件未被改动后
/// 才落地；替换模式下原件移入废纸篓（有损压缩不可逆，必须可找回）。
final class MediaSlimmer {
    typealias Trash = (URL) throws -> Void

    private let trash: Trash
    private let home: String
    private let fileManager = FileManager.default

    init(home: String = NSHomeDirectory(),
         trash: @escaping Trash = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        self.home = home
        self.trash = trash
    }

    private struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t
        let mtime: timespec
        let size: off_t

        static func == (lhs: Identity, rhs: Identity) -> Bool {
            lhs.device == rhs.device && lhs.inode == rhs.inode && lhs.size == rhs.size
                && lhs.mtime.tv_sec == rhs.mtime.tv_sec && lhs.mtime.tv_nsec == rhs.mtime.tv_nsec
        }
    }

    private enum SlimError: Error {
        case unsupported(String)
        case failed(String)
    }

    private func identity(of path: String) -> Identity? {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return Identity(device: info.st_dev, inode: info.st_ino, mtime: info.st_mtimespec, size: info.st_size)
    }

    func slim(path: String, options: SlimOptions,
              progress: ((Double) -> Void)? = nil) async -> SlimOutcome {
        func outcome(_ status: SlimOutcome.Status, original: UInt64 = 0, new: UInt64 = 0,
                     output: String? = nil, message: String? = nil) -> SlimOutcome {
            SlimOutcome(path: path, status: status, originalBytes: original, newBytes: new,
                        outputPath: output, message: message,
                        replaced: status == .slimmed && options.replaceOriginal)
        }
        guard MediaSlimPolicy.isEligible(path, home: home) else {
            return outcome(.failed, message: "slim.reason.location")
        }
        guard let before = identity(of: path) else {
            return outcome(.failed, message: "slim.reason.notFile")
        }
        let original = URL(fileURLWithPath: path)
        let originalBytes = UInt64(max(0, before.size))
        let operation = SlimOperation.operation(for: path)
        let stem = original.deletingPathExtension().lastPathComponent
        let token = UUID().uuidString.prefix(8)
        let directory = original.deletingLastPathComponent()

        let produced: (temp: URL, ext: String)
        do {
            switch operation {
            case .compressImage:
                let ext = try imageOutputExtension(for: original, options: options)
                let temp = directory.appendingPathComponent(".\(stem).nori-slim-\(token).\(ext)")
                try compressImage(original, to: temp, ext: ext, options: options)
                produced = (temp, ext)
            case .transcodeVideo:
                let ext = original.pathExtension.lowercased() == "mov" ? "mov" : "mp4"
                let temp = directory.appendingPathComponent(".\(stem).nori-slim-\(token).\(ext)")
                try await transcodeVideo(original, to: temp, ext: ext, options: options, progress: progress)
                produced = (temp, ext)
            case .archive:
                let temp = directory.appendingPathComponent(".\(original.lastPathComponent).nori-slim-\(token).zip")
                try archive(original, to: temp)
                produced = (temp, original.pathExtension.isEmpty ? "zip" : "\(original.pathExtension).zip")
            }
        } catch is CancellationError {
            removeTemporaryArtifacts(in: directory, token: String(token))
            return outcome(.cancelled, original: originalBytes)
        } catch SlimError.unsupported(let reason) {
            removeTemporaryArtifacts(in: directory, token: String(token))
            return outcome(.unsupported, original: originalBytes, message: reason)
        } catch SlimError.failed(let reason) {
            removeTemporaryArtifacts(in: directory, token: String(token))
            return outcome(.failed, original: originalBytes, message: reason)
        } catch {
            removeTemporaryArtifacts(in: directory, token: String(token))
            return outcome(.failed, original: originalBytes, message: error.localizedDescription)
        }

        let temp = produced.temp
        guard let tempIdentity = identity(of: temp.path) else {
            return outcome(.failed, original: originalBytes, message: "slim.reason.noOutput")
        }
        let newBytes = UInt64(max(0, tempIdentity.size))
        guard Double(newBytes) <= Double(originalBytes) * SlimOptions.minimumSavingRatio else {
            try? fileManager.removeItem(at: temp)
            return outcome(.notSmaller, original: originalBytes, new: newBytes)
        }
        guard identity(of: path) == before else {
            try? fileManager.removeItem(at: temp)
            return outcome(.failed, original: originalBytes, message: "slim.reason.changed")
        }
        if let attributes = try? fileManager.attributesOfItem(atPath: path) {
            var dates: [FileAttributeKey: Any] = [:]
            dates[.creationDate] = attributes[.creationDate]
            dates[.modificationDate] = attributes[.modificationDate]
            try? fileManager.setAttributes(dates, ofItemAtPath: temp.path)
        }

        let destination: URL
        if options.replaceOriginal {
            let sameName = operation != .archive
                && produced.ext.lowercased() == original.pathExtension.lowercased()
            destination = sameName
                ? original
                : uniqueURL(directory.appendingPathComponent(
                    operation == .archive ? "\(original.lastPathComponent).zip" : "\(stem).\(produced.ext)"))
            do {
                try trash(original)
            } catch {
                try? fileManager.removeItem(at: temp)
                return outcome(.failed, original: originalBytes,
                               message: "slim.reason.trash")
            }
        } else {
            destination = uniqueURL(directory.appendingPathComponent(
                operation == .archive ? "\(original.lastPathComponent).zip" : "\(stem)-slim.\(produced.ext)"))
        }
        do {
            try fileManager.moveItem(at: temp, to: destination)
        } catch {
            try? fileManager.removeItem(at: temp)
            return outcome(.failed, original: originalBytes,
                           message: options.replaceOriginal ? "slim.reason.placeFailed" : error.localizedDescription)
        }
        return outcome(.slimmed, original: originalBytes, new: newBytes, output: destination.path)
    }

    private func uniqueURL(_ url: URL) -> URL {
        guard fileManager.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let directory = url.deletingLastPathComponent()
        var index = 2
        while true {
            let name = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            let candidate = directory.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    private func removeTemporaryArtifacts(in directory: URL, token: String) {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasPrefix(".") && name.contains(".nori-slim-\(token)") {
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    // MARK: 图片

    private func imageOutputExtension(for url: URL, options: SlimOptions) throws -> String {
        if options.imageFormat == .heic { return "heic" }
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "heic", "heif": return ext
        default:
            throw SlimError.unsupported("slim.reason.lossless")
        }
    }

    private func compressImage(_ url: URL, to temp: URL, ext: String, options: SlimOptions) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { throw SlimError.failed("slim.reason.unreadable") }
        guard CGImageSourceGetCount(source) == 1 else {
            throw SlimError.unsupported("slim.reason.animated")
        }
        let outputType: String
        switch ext {
        case "heic", "heif": outputType = UTType.heic.identifier
        default: outputType = UTType.jpeg.identifier
        }
        let writable = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        guard writable.contains(outputType) else { throw SlimError.unsupported("slim.reason.encoder") }
        guard let destination = CGImageDestinationCreateWithURL(temp as CFURL, outputType as CFString, 1, nil)
        else { throw SlimError.failed("slim.reason.createOutput") }

        let properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let quality = options.quality.value
        if options.limitLongEdge, max(width, height) > SlimOptions.longEdgeLimit {
            let thumbnailOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: SlimOptions.longEdgeLimit,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary)
            else { throw SlimError.failed("slim.reason.resize") }
            // The transform is baked into the pixels, so the orientation tag must reset.
            var metadata = properties
            metadata[kCGImagePropertyOrientation] = 1
            if var tiff = metadata[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff[kCGImagePropertyTIFFOrientation] = 1
                metadata[kCGImagePropertyTIFFDictionary] = tiff
            }
            metadata[kCGImagePropertyPixelWidth] = nil
            metadata[kCGImagePropertyPixelHeight] = nil
            metadata[kCGImageDestinationLossyCompressionQuality] = quality
            CGImageDestinationAddImage(destination, image, metadata as CFDictionary)
        } else {
            let addOptions: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
            CGImageDestinationAddImageFromSource(destination, source, 0, addOptions as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw SlimError.failed("slim.reason.encode") }
    }

    // MARK: 视频

    private func transcodeVideo(_ url: URL, to temp: URL, ext: String, options: SlimOptions,
                                progress: ((Double) -> Void)?) async throws {
        let asset = AVURLAsset(url: url)
        let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        let exportable = (try? await asset.load(.isExportable)) ?? false
        guard !tracks.isEmpty, exportable else {
            throw SlimError.unsupported("slim.reason.container")
        }
        let preset = options.videoPreset == .original
            ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHEVC1920x1080
        let fileType: AVFileType = ext == "mov" ? .mov : .mp4
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw SlimError.unsupported("slim.reason.hevc")
        }
        guard session.supportedFileTypes.contains(fileType) else {
            throw SlimError.unsupported("slim.reason.hevc")
        }
        session.outputURL = temp
        session.outputFileType = fileType
        session.shouldOptimizeForNetworkUse = true

        let poller = Task {
            while !Task.isCancelled {
                progress?(Double(session.progress))
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        defer { poller.cancel() }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                session.exportAsynchronously { continuation.resume() }
            }
        } onCancel: { [cancel = ExportCancellation(session)] in
            cancel.run()
        }
        switch session.status {
        case .completed: return
        case .cancelled: throw CancellationError()
        default: throw SlimError.failed(session.error?.localizedDescription ?? "slim.reason.export")
        }
    }

    // MARK: 打包

    private func archive(_ url: URL, to temp: URL) throws {
        guard run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", url.path, temp.path]) else {
            throw Task.isCancelled ? CancellationError() : SlimError.failed("slim.reason.archive")
        }
        guard run("/usr/bin/unzip", ["-tqq", temp.path]) else {
            throw SlimError.failed("slim.reason.verify")
        }
    }

    private func run(_ executable: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        while process.isRunning {
            if Task.isCancelled { process.terminate() }
            usleep(100_000)
        }
        return process.terminationStatus == 0 && !Task.isCancelled
    }
}

/// cancelExport is documented as callable from any thread; the session itself is not Sendable.
private final class ExportCancellation: @unchecked Sendable {
    private let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
    func run() { session.cancelExport() }
}
