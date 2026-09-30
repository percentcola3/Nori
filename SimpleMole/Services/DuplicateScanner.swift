import CryptoKit
import Darwin
import Foundation

struct DuplicateFileIdentity: Hashable, Sendable {
    let device: UInt64
    let inode: UInt64
    let size: UInt64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64

    init(_ value: stat) {
        device = UInt64(bitPattern: Int64(value.st_dev))
        inode = UInt64(value.st_ino)
        size = UInt64(max(0, value.st_size))
        modifiedSeconds = Int64(value.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
        changedSeconds = Int64(value.st_ctimespec.tv_sec)
        changedNanoseconds = Int64(value.st_ctimespec.tv_nsec)
    }
}

struct DuplicateFile: Identifiable, Hashable, Sendable {
    let path: String
    let name: String
    let size: UInt64
    let identity: DuplicateFileIdentity
    /// Empty until the complete data fork has been hashed successfully.
    let sha256: String
    var id: String { path }
}

struct DuplicateGroup: Identifiable, Sendable {
    let id: String
    let files: [DuplicateFile]
    /// Logical duplicate bytes, not a prediction of physical space reclaimed.
    var reclaimableBytes: UInt64 { files.dropFirst().reduce(0) { $0 + $1.size } }
}

final class DuplicateScanControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

struct DuplicateScanProgress: Sendable {
    let phase: String
    let currentPath: String
    let scannedFiles: Int
    let processedFiles: Int
    let totalCandidates: Int
    let bytesRead: UInt64
}

struct DuplicateScanResult: Sendable {
    var roots: [String] = []
    var groups: [DuplicateGroup] = []
    var files: [DuplicateFile] = []
    var skippedFiles = 0
    var isPartial = false
    var cancelled = false
    var error: String?
}

enum DuplicateScanError: Error, LocalizedError {
    case cancelled, unsafePath, unavailable, changed, unhashed, differentContent
    var errorDescription: String? {
        switch self {
        case .cancelled: return "扫描已取消"
        case .unsafePath: return "文件路径不在允许扫描的普通目录内"
        case .unavailable: return "文件不可读取、尚未下载或包含资源分叉"
        case .changed: return "文件在扫描后发生变化，请重新扫描"
        case .unhashed: return "文件尚未完成完整内容校验"
        case .differentContent: return "文件内容与扫描结果不一致，请重新扫描"
        }
    }
}

/// Exact duplicates in explicitly selected ordinary folders. This service never
/// follows symlinks, downloads cloud placeholders, or modifies a file.
enum DuplicateScanner {
    private static let chunkSize = 1024 * 1024
    private static let sampleSize = 64 * 1024
    private static let datalessFlag: UInt32 = 0x40000000 // SF_DATALESS
    private static let managedNames: Set<String> = [
        ".git", ".svn", ".hg", "node_modules", ".build", ".swiftpm",
        ".trash", ".trashes", ".spotlight-v100", ".fseventsd", ".documentrevisions-v100",
        "pods", "deriveddata"
    ]
    private static let packageExtensions: Set<String> = [
        "app", "bundle", "framework", "plugin", "appex", "xpc", "kext",
        "photoslibrary", "photolibrary", "aplibrary", "musiclibrary", "imovielibrary",
        "fcpbundle", "band", "logicx", "garageband", "xcodeproj", "xcworkspace",
        "sparsebundle", "backupbundle", "rtfd", "xcassets"
    ]

    private struct Inode: Hashable {
        let device: UInt64
        let inode: UInt64
        init(_ value: DuplicateFileIdentity) { device = value.device; inode = value.inode }
    }

    private final class Progress {
        let callback: ((DuplicateScanProgress) -> Void)?
        var phase = "enumerating"
        var currentPath = ""
        var scannedFiles = 0
        var processedFiles = 0
        var totalCandidates = 0
        var bytesRead: UInt64 = 0
        private var lastUpdate = -Double.infinity
        init(_ callback: ((DuplicateScanProgress) -> Void)?) { self.callback = callback }
        func emit(force: Bool = false) {
            let now = ProcessInfo.processInfo.systemUptime
            guard force || now - lastUpdate >= 0.15 else { return }
            lastUpdate = now
            callback?(DuplicateScanProgress(phase: phase, currentPath: currentPath,
                                           scannedFiles: scannedFiles, processedFiles: processedFiles,
                                           totalCandidates: totalCandidates, bytesRead: bytesRead))
        }
    }

    static func enumerate(roots: [String], control: DuplicateScanControl,
                          home: String = NSHomeDirectory(),
                          progress: ((DuplicateScanProgress) -> Void)? = nil) -> DuplicateScanResult {
        enumerate(roots: roots, control: control, home: home, state: Progress(progress))
    }

    static func scan(roots: [String], control: DuplicateScanControl,
                     home: String = NSHomeDirectory(),
                     progress: ((DuplicateScanProgress) -> Void)? = nil) -> DuplicateScanResult {
        let state = Progress(progress)
        var result = enumerate(roots: roots, control: control, home: home, state: state)
        guard !result.cancelled else { return result }
        let sameSizes = Dictionary(grouping: result.files.indices, by: { result.files[$0].size })
            .values.filter { $0.count > 1 }
        state.phase = "sampling"
        state.totalCandidates = sameSizes.reduce(0) { $0 + $1.count }
        state.processedFiles = 0
        state.emit(force: true)
        var sampleGroups: [String: [Int]] = [:]
        for indices in sameSizes {
            for index in indices {
                if control.isCancelled { break }
                let file = result.files[index]
                state.currentPath = file.path
                do {
                    let digest = try digest(file, allowedRoots: result.roots, control: control,
                                            home: home, sample: true) { count in
                        state.bytesRead += UInt64(count)
                        state.emit()
                    }
                    sampleGroups["\(file.size):\(digest)", default: []].append(index)
                } catch {
                    if !control.isCancelled { result.skippedFiles += 1; result.isPartial = true }
                }
                state.processedFiles += 1
                state.emit()
            }
            if control.isCancelled { break }
        }
        let candidates = sampleGroups.values.filter { $0.count > 1 }.flatMap { $0 }
        state.phase = "hashing"
        state.totalCandidates = candidates.count
        state.processedFiles = 0
        state.emit(force: true)
        var hashes: [String: [DuplicateFile]] = [:]
        for index in candidates {
            if control.isCancelled { break }
            let file = result.files[index]
            state.currentPath = file.path
            do {
                let value = try digest(file, allowedRoots: result.roots, control: control,
                                       home: home, sample: false) { count in
                    state.bytesRead += UInt64(count)
                    state.emit()
                }
                let complete = DuplicateFile(path: file.path, name: file.name, size: file.size,
                                             identity: file.identity, sha256: value)
                result.files[index] = complete
                hashes[value, default: []].append(complete)
            } catch {
                if !control.isCancelled { result.skippedFiles += 1; result.isPartial = true }
            }
            state.processedFiles += 1
            state.emit()
        }
        result.groups = hashes.compactMap { key, files in
            guard files.count > 1 else { return nil }
            return DuplicateGroup(id: key, files: files.sorted { $0.path < $1.path })
        }.sorted {
            $0.reclaimableBytes == $1.reclaimableBytes ? $0.id < $1.id : $0.reclaimableBytes > $1.reclaimableBytes
        }
        result.cancelled = control.isCancelled
        result.isPartial = result.isPartial || result.cancelled
        if result.cancelled { result.groups = [] }
        state.phase = result.cancelled ? "cancelled" : "finished"
        state.emit(force: true)
        return result
    }

    /// Hash only when the current file still has the enumerated identity.
    static func hash(_ file: DuplicateFile, allowedRoots: [String], control: DuplicateScanControl,
                     home: String = NSHomeDirectory()) throws -> DuplicateFile {
        let value = try digest(file, allowedRoots: allowedRoots, control: control, home: home, sample: false)
        return DuplicateFile(path: file.path, name: file.name, size: file.size,
                             identity: file.identity, sha256: value)
    }

    static func validateUnchanged(_ file: DuplicateFile, allowedRoots: [String],
                                  control: DuplicateScanControl = DuplicateScanControl(),
                                  home: String = NSHomeDirectory()) throws {
        let descriptor = try openVerified(file, allowedRoots: allowedRoots, control: control, home: home)
        defer { close(descriptor) }
        try verifyDescriptor(descriptor, file: file)
    }

    static func revalidate(_ file: DuplicateFile, allowedRoots: [String], control: DuplicateScanControl,
                           home: String = NSHomeDirectory()) throws {
        guard !file.sha256.isEmpty else { throw DuplicateScanError.unhashed }
        let current = try hash(file, allowedRoots: allowedRoots, control: control, home: home)
        guard current.sha256 == file.sha256 else { throw DuplicateScanError.differentContent }
    }

    static func isAllowedRoot(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        let root = URL(fileURLWithPath: path).standardized.path
        guard safePolicy(root, home: home), noSymlinkComponents(root),
              let info = metadata(root), (info.st_mode & S_IFMT) == S_IFDIR else { return false }
        return !isPackage(root) && !hasPackageAncestor(root)
    }

    private static func enumerate(roots: [String], control: DuplicateScanControl,
                                  home: String, state: Progress) -> DuplicateScanResult {
        var result = DuplicateScanResult()
        var seen = Set<Inode>()
        for root in roots.map({ URL(fileURLWithPath: $0).standardized.path }).sorted() {
            if control.isCancelled { break }
            if result.roots.contains(where: { contains($0, root) }) { continue }
            guard isAllowedRoot(root, home: home), let metadata = metadata(root) else {
                result.skippedFiles += 1
                result.isPartial = true
                result.error = "部分目录不是可扫描的普通目录，或无法读取"
                continue
            }
            result.roots.append(root)
            guard let name = strdup(root) else { result.isPartial = true; continue }
            defer { free(name) }
            var paths: [UnsafeMutablePointer<CChar>?] = [name, nil]
            guard let tree = paths.withUnsafeMutableBufferPointer({
                fts_open($0.baseAddress!, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil)
            }) else { result.isPartial = true; continue }
            defer { fts_close(tree) }
            while !control.isCancelled {
                errno = 0
                guard let entry = fts_read(tree) else {
                    if errno != 0 { result.isPartial = true }
                    break
                }
                let item = entry.pointee
                let path = String(cString: item.fts_path)
                state.currentPath = path
                state.emit()
                switch Int32(item.fts_info) {
                case FTS_D:
                    if !safePolicy(path, home: home) || isPackage(path)
                        || item.fts_statp?.pointee.st_dev != metadata.st_dev {
                        fts_set(tree, entry, FTS_SKIP)
                        result.skippedFiles += 1
                    }
                case FTS_F:
                    guard let info = item.fts_statp?.pointee else {
                        result.skippedFiles += 1; result.isPartial = true; continue
                    }
                    state.scannedFiles += 1
                    guard safePolicy(path, home: home), info.st_size > 0,
                          availableLocally(path, info: info), resourceForkIsEmpty(path) else {
                        result.skippedFiles += 1; continue
                    }
                    let identity = DuplicateFileIdentity(info)
                    guard seen.insert(Inode(identity)).inserted else { continue }
                    result.files.append(DuplicateFile(path: path, name: (path as NSString).lastPathComponent,
                                                      size: identity.size, identity: identity, sha256: ""))
                case FTS_ERR, FTS_DNR, FTS_NS:
                    result.skippedFiles += 1
                    result.isPartial = true
                case FTS_SL, FTS_SLNONE:
                    result.skippedFiles += 1
                default: break
                }
            }
        }
        result.files.sort { $0.path < $1.path }
        result.cancelled = control.isCancelled
        result.isPartial = result.isPartial || result.cancelled
        state.totalCandidates = result.files.count
        if result.cancelled { state.phase = "cancelled" }
        state.emit(force: true)
        return result
    }

    private static func contains(_ root: String, _ path: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }

    private static func safePolicy(_ path: String, home: String) -> Bool {
        let selectedHome = URL(fileURLWithPath: home).standardized.path
        guard (contains(selectedHome, path) || path.hasPrefix("/Volumes/")), path != "/" else { return false }
        if contains(selectedHome + "/Library", path) { return false }
        let relative = contains(selectedHome, path) ? String(path.dropFirst(selectedHome.count))
            : String(path.dropFirst("/Volumes/".count))
        if relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { return false }
        for root in ["/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/dev",
                     "/private/etc", "/private/var", "/Network"] where contains(root, path) { return false }
        for part in path.split(separator: "/").map(String.init) {
            if managedNames.contains(part.lowercased()) { return false }
            if packageExtensions.contains((part as NSString).pathExtension.lowercased()) { return false }
        }
        return !(path as NSString).lastPathComponent.lowercased().hasSuffix(".icloud")
    }

    private static func metadata(_ path: String) -> stat? {
        var info = stat()
        return lstat(path, &info) == 0 ? info : nil
    }

    private static func noSymlinkComponents(_ path: String) -> Bool {
        var prefix = ""
        for component in path.split(separator: "/") {
            prefix += "/" + component
            guard let info = metadata(prefix), (info.st_mode & S_IFMT) != S_IFLNK else { return false }
        }
        return true
    }

    private static func isPackage(_ path: String) -> Bool {
        autoreleasepool {
            (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isPackageKey]).isPackage) == true
        }
    }

    private static func hasPackageAncestor(_ path: String) -> Bool {
        var url = URL(fileURLWithPath: path).deletingLastPathComponent()
        while url.path != "/" {
            if isPackage(url.path) { return true }
            url.deleteLastPathComponent()
        }
        return false
    }

    private static func availableLocally(_ path: String, info: stat) -> Bool {
        guard info.st_flags & datalessFlag == 0 else { return false }
        return autoreleasepool {
            guard let resources = try? URL(fileURLWithPath: path).resourceValues(
                forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]) else { return false }
            return resources.isUbiquitousItem != true
                || resources.ubiquitousItemDownloadingStatus == .current
                || resources.ubiquitousItemDownloadingStatus == .downloaded
        }
    }

    private static func resourceForkIsEmpty(_ path: String) -> Bool {
        errno = 0
        let length = getxattr(path, "com.apple.ResourceFork", nil, 0, 0, XATTR_NOFOLLOW)
        return length == 0 || (length < 0 && errno == ENOATTR)
    }

    private static func openVerified(_ file: DuplicateFile, allowedRoots: [String],
                                     control: DuplicateScanControl, home: String) throws -> Int32 {
        guard !control.isCancelled else { throw DuplicateScanError.cancelled }
        let path = URL(fileURLWithPath: file.path).standardized.path
        guard path == file.path, file.size == file.identity.size, safePolicy(path, home: home),
              allowedRoots.contains(where: {
                  let root = URL(fileURLWithPath: $0).standardized.path
                  return safePolicy(root, home: home) && contains(root, path) && path != root
              }), !hasPackageAncestor(path) else { throw DuplicateScanError.unsafePath }
        guard let info = metadata(path), (info.st_mode & S_IFMT) == S_IFREG,
              DuplicateFileIdentity(info) == file.identity else { throw DuplicateScanError.changed }
        guard availableLocally(path, info: info) else { throw DuplicateScanError.unavailable }
        var directory = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw DuplicateScanError.unavailable }
        defer { close(directory) }
        let components = path.split(separator: "/").map(String.init)
        for component in components.dropLast() {
            if control.isCancelled { throw DuplicateScanError.cancelled }
            let next = openat(directory, component, O_RDONLY | O_NOFOLLOW | O_DIRECTORY | O_CLOEXEC)
            guard next >= 0 else { throw DuplicateScanError.unsafePath }
            close(directory)
            directory = next
        }
        guard let leaf = components.last else { throw DuplicateScanError.unsafePath }
        let descriptor = openat(directory, leaf, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw DuplicateScanError.unavailable }
        do { try verifyDescriptor(descriptor, file: file) }
        catch { close(descriptor); throw error }
        return descriptor
    }

    private static func verifyDescriptor(_ descriptor: Int32, file: DuplicateFile) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              DuplicateFileIdentity(info) == file.identity else { throw DuplicateScanError.changed }
        guard info.st_flags & datalessFlag == 0 else { throw DuplicateScanError.unavailable }
        errno = 0
        let length = fgetxattr(descriptor, "com.apple.ResourceFork", nil, 0, 0, 0)
        guard length == 0 || (length < 0 && errno == ENOATTR) else { throw DuplicateScanError.unavailable }
    }

    private static func digest(_ file: DuplicateFile, allowedRoots: [String], control: DuplicateScanControl,
                               home: String, sample: Bool, didRead: ((Int) -> Void)? = nil) throws -> String {
        let descriptor = try openVerified(file, allowedRoots: allowedRoots, control: control, home: home)
        defer { close(descriptor) }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: sample ? sampleSize : chunkSize)
        let ranges: [(UInt64, UInt64)] = sample && file.size > UInt64(sampleSize * 2)
            ? [(UInt64(0), UInt64(sampleSize)), (file.size - UInt64(sampleSize), UInt64(sampleSize))]
            : [(UInt64(0), file.size)]
        for (start, length) in ranges {
            var consumed: UInt64 = 0
            while consumed < length {
                guard !control.isCancelled else { throw DuplicateScanError.cancelled }
                let amount = min(buffer.count, Int(min(UInt64(Int.max), length - consumed)))
                let readCount = buffer.withUnsafeMutableBytes {
                    pread(descriptor, $0.baseAddress!, amount, off_t(start + consumed))
                }
                if readCount < 0 && errno == EINTR { continue }
                guard readCount > 0 else { throw DuplicateScanError.unavailable }
                buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0.prefix(readCount))) }
                consumed += UInt64(readCount)
                didRead?(readCount)
            }
        }
        guard !control.isCancelled else { throw DuplicateScanError.cancelled }
        try verifyDescriptor(descriptor, file: file)
        // The descriptor can remain valid after a rename/replacement. Check that
        // the original path still names the same file before publishing a hash.
        guard noSymlinkComponents(file.path), let current = metadata(file.path),
              DuplicateFileIdentity(current) == file.identity else { throw DuplicateScanError.changed }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
