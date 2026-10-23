import Darwin
import Foundation

/// Shared, read-only filesystem scanning. It never opens file contents or
/// caches identities. Callers own their inventories and cleanup decisions.
enum FileScanService {
    enum SizePolicy {
        /// Existing cleanup accounting: regular files/directories, hard-linked
        /// files once, symlinks excluded. Activity comes only from files.
        case cleanup
        /// Directory display: all physical entries, no followed links, mount
        /// and dataless skips reported as a lower bound, Int64 saturation.
        case directory
    }

    struct Measurement {
        var bytes: UInt64 = 0
        var files = 0
        var complete = true
        var newestModified: Date?
        var newestAccessed: Date?
    }

    private struct Identity: Hashable {
        let device: dev_t
        let inode: ino_t
    }

    /// lstat deliberately inspects the link itself. errno remains available
    /// on failure so callers can distinguish absence from access failures.
    static func metadata(at path: String) -> stat? {
        var info = stat()
        return lstat(path, &info) == 0 ? info : nil
    }

    /// Returns names only, avoiding an additional whole-directory metadata
    /// buffer. Hidden entries are included; filtering belongs to the caller.
    static func childNames(in path: String) throws -> [String] {
        guard let stream = opendir(path) else { throw readError(path) }
        defer { closedir(stream) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw readError(path) }
                return names
            }
            let length = Int(entry.pointee.d_namlen) + 1
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: length) {
                    String(cString: $0)
                }
            }
            if name != "." && name != ".." { names.append(name) }
        }
    }

    static func childPaths(in path: String, sorted: Bool = false) throws -> [String] {
        let names = try childNames(in: path)
        let prefix = path.hasSuffix("/") ? path : path + "/"
        return (sorted ? names.sorted() : names).map { prefix + $0 }
    }

    static func measure(_ path: String, policy: SizePolicy,
                        maximumSeconds: TimeInterval = .infinity,
                        shouldStop: () -> Bool = { false },
                        onDirectory: (String) -> Void = { _ in }) -> Measurement {
        onDirectory(path)
        let began = ProcessInfo.processInfo.systemUptime
        guard !shouldStop(), maximumSeconds > 0 else { return Measurement(complete: false) }
        var result = Measurement()
        var rootDevice: dev_t?
        var rootBytes: UInt64 = 0
        let limit = policy == .directory ? UInt64(Int64.max) : UInt64.max
        func allocated(_ info: stat) -> UInt64 {
            let count = UInt64(max(0, info.st_blocks))
            return count > limit / 512 ? limit : count * 512
        }
        // Check dataless roots before FTS opens them, so sizing cannot request
        // a File Provider download. Directory symlinks count only themselves.
        if policy == .directory {
            guard let root = metadata(at: path) else { return Measurement(complete: false) }
            rootDevice = root.st_dev
            rootBytes = allocated(root)
            if (root.st_mode & S_IFMT) != S_IFDIR {
                result.bytes = rootBytes
                result.files = (root.st_mode & S_IFMT) == S_IFREG ? 1 : 0
                return result
            }
            if (root.st_flags & UInt32(SF_DATALESS)) != 0 {
                return Measurement(bytes: rootBytes, complete: false)
            }
        }
        var seen = Set<Identity>()
        let finished = walk(path, shouldStop: {
            shouldStop() || ProcessInfo.processInfo.systemUptime - began >= maximumSeconds
        }) { entry, tree in
            let kind = Int32(entry.pointee.fts_info)
            if kind == FTS_DP { return }
            let failed = kind == FTS_ERR || kind == FTS_DNR || kind == FTS_NS || kind == FTS_DC
            if failed { result.complete = false }
            if policy == .cleanup && kind != FTS_F && kind != FTS_D { return }
            guard kind != FTS_NS, let info = entry.pointee.fts_statp?.pointee else {
                result.complete = false
                return
            }
            if rootDevice == nil { rootDevice = info.st_dev }
            if kind == FTS_D {
                // Construct a path only for directory progress. Size-only
                // walks do not allocate a full Swift path for every file.
                onDirectory(String(cString: entry.pointee.fts_path))
                if policy == .directory && info.st_dev != rootDevice {
                    result.complete = false
                    fts_set(tree, entry, FTS_SKIP)
                    return
                }
            }
            if policy == .directory || (kind == FTS_F && info.st_nlink > 1) {
                guard seen.insert(Identity(device: info.st_dev, inode: info.st_ino)).inserted else { return }
            }
            let addition = result.bytes.addingReportingOverflow(allocated(info))
            if addition.overflow || addition.partialValue > limit {
                result.bytes = limit
                result.complete = false
            } else { result.bytes = addition.partialValue }
            if kind == FTS_F {
                result.files += 1
                if policy == .cleanup {
                    let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
                    let accessed = Date(timeIntervalSince1970: TimeInterval(info.st_atimespec.tv_sec))
                    result.newestModified = max(result.newestModified ?? .distantPast, modified)
                    result.newestAccessed = max(result.newestAccessed ?? .distantPast, accessed)
                }
            }
            if policy == .directory && kind == FTS_D && (info.st_flags & UInt32(SF_DATALESS)) != 0 {
                result.complete = false
                fts_set(tree, entry, FTS_SKIP)
            }
        }
        if !finished {
            result.complete = false
            if policy == .directory && result.bytes == 0 { result.bytes = rootBytes }
        }
        return result
    }

    /// Unsafe FTS pointers stay inside this synchronous implementation and
    /// are consumed before the next fts_read; none escape to callers.
    private static func walk(_ path: String, shouldStop: () -> Bool,
                             visit: (UnsafeMutablePointer<FTSENT>, UnsafeMutablePointer<FTS>) -> Void) -> Bool {
        guard let name = strdup(path) else { return false }
        defer { free(name) }
        var roots: [UnsafeMutablePointer<CChar>?] = [name, nil]
        guard let tree = roots.withUnsafeMutableBufferPointer({
            fts_open($0.baseAddress!, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil)
        }) else { return false }
        defer { fts_close(tree) }
        while !shouldStop() {
            errno = 0
            guard let entry = fts_read(tree) else { return errno == 0 }
            visit(entry, tree)
        }
        return false
    }

    private static func readError(_ path: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: path])
    }
}
