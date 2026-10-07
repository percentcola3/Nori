import Darwin
import Foundation

enum CleanupScanMode: String, Codable, Sendable {
    case quick, deep
}

/// A single cancellation/deadline shared by discovery and all sizing workers.
/// Deep scans have no per-directory cutoff; they remain user-cancellable.
final class CleanupScanControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var lastDirectory = ""
    private var lastDirectorySentAt = -Double.infinity
    private let onDirectory: (@Sendable (String) -> Void)?
    private let cancellationSource: CleanupScanControl?
    let startedAt = ProcessInfo.processInfo.systemUptime
    let totalBudget: TimeInterval
    let directoryBudget: TimeInterval

    init(mode: CleanupScanMode, totalBudget: TimeInterval? = nil,
         directoryBudget: TimeInterval? = nil,
         onDirectory: (@Sendable (String) -> Void)? = nil,
         cancellationSource: CleanupScanControl? = nil) {
        self.totalBudget = totalBudget ?? (mode == .quick ? 45 : .infinity)
        self.directoryBudget = directoryBudget ?? (mode == .quick ? 8 : .infinity)
        self.onDirectory = onDirectory
        self.cancellationSource = cancellationSource
    }

    /// Bounded delivery across concurrent workers; callbacks run outside the lock.
    func reportDirectory(_ path: String) {
        guard let onDirectory else { return }
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let deliver = path != lastDirectory && now - lastDirectorySentAt >= 0.12
        if deliver { lastDirectory = path; lastDirectorySentAt = now }
        lock.unlock()
        if deliver { onDirectory(path) }
    }

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool {
        lock.lock(); let local = cancelled; lock.unlock()
        return local || (cancellationSource?.isCancelled ?? false)
    }
    var elapsed: TimeInterval { ProcessInfo.processInfo.systemUptime - startedAt }
    var shouldStop: Bool { isCancelled || elapsed >= totalBudget }
}

/// Size-only traversal. FTS supplies type, inode and allocated blocks together;
/// the cleanup path does not build the analyzer's large-file report per file.
/// The same walk also collects the newest mtime/ctime/atime so activity gating
/// never needs a second traversal.
enum CleanupScanWorker {
    struct Measurement: Sendable {
        var bytes: UInt64 = 0
        var files: Int = 0
        var complete = true
        /// Newest file timestamps seen inside the tree. nil = no readable
        /// evidence at all; directories alone (empty tree) have no say.
        /// 只采集 mtime / atime：ctime 会被 chmod、备份等元数据操作刷新，
        /// 不能作为“内容仍在使用”的证据；创建时间在写入时已体现在 mtime。
        var newestModified: Date?
        var newestAccessed: Date?

        /// Combined activity evidence for the measured tree.
        var activityEvidence: Date? {
            CleanupAgePolicy.activityEvidence(modified: newestModified,
                                              accessed: newestAccessed)
        }
    }

    private struct Identity: Hashable {
        let device: dev_t
        let inode: ino_t
    }

    static func measure(_ path: String, control: CleanupScanControl) -> Measurement {
        control.reportDirectory(path)
        let began = ProcessInfo.processInfo.systemUptime
        guard !control.shouldStop, let name = strdup(path) else {
            return Measurement(complete: false)
        }
        defer { free(name) }
        var paths: [UnsafeMutablePointer<CChar>?] = [name, nil]
        guard let tree = paths.withUnsafeMutableBufferPointer({
            fts_open($0.baseAddress!, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil)
        }) else { return Measurement(complete: false) }
        defer { fts_close(tree) }
        var result = Measurement()
        var seen = Set<Identity>()
        while true {
            if control.shouldStop || ProcessInfo.processInfo.systemUptime - began >= control.directoryBudget {
                result.complete = false
                break
            }
            errno = 0
            guard let entry = fts_read(tree) else {
                if errno != 0 { result.complete = false }
                break
            }
            switch Int32(entry.pointee.fts_info) {
            case FTS_ERR, FTS_DNR, FTS_NS:
                result.complete = false
            case FTS_F, FTS_D:
                if Int32(entry.pointee.fts_info) == FTS_D,
                   let directory = entry.pointee.fts_path {
                    control.reportDirectory(String(cString: directory))
                }
                guard let metadata = entry.pointee.fts_statp?.pointee else {
                    result.complete = false
                    continue
                }
                // Only multiply-linked files require identity bookkeeping.
                if metadata.st_nlink > 1 && Int32(entry.pointee.fts_info) == FTS_F {
                    guard seen.insert(Identity(device: metadata.st_dev, inode: metadata.st_ino)).inserted else {
                        continue
                    }
                }
                result.bytes &+= UInt64(max(0, metadata.st_blocks)) * 512
                if Int32(entry.pointee.fts_info) == FTS_F {
                    result.files += 1
                    func newer(_ current: Date?, _ ts: timespec) -> Date {
                        let date = Date(timeIntervalSince1970: TimeInterval(ts.tv_sec))
                        return max(current ?? .distantPast, date)
                    }
                    result.newestModified = newer(result.newestModified, metadata.st_mtimespec)
                    result.newestAccessed = newer(result.newestAccessed, metadata.st_atimespec)
                }
            default:
                break // Never follow symlinks or count directory postorder twice.
            }
        }
        return result
    }

    /// Workers draw from one queue across all roots, keeping total I/O bounded.
    static func measure(_ paths: [String], control: CleanupScanControl,
                        progress: @escaping (Int, String) -> Void) -> [Measurement] {
        guard !paths.isEmpty else { return [] }
        let lock = NSLock()
        var next = 0
        var completed = 0
        var result = Array(repeating: Measurement(complete: false), count: paths.count)
        DispatchQueue.concurrentPerform(iterations: min(8, paths.count)) { _ in
            while true {
                lock.lock()
                guard next < paths.count, !control.shouldStop else { lock.unlock(); break }
                let index = next
                next += 1
                let before = completed
                lock.unlock()
                progress(before, paths[index])
                let measurement = measure(paths[index], control: control)
                lock.lock()
                result[index] = measurement
                completed += 1
                let after = completed
                lock.unlock()
                progress(after, paths[index])
            }
        }
        return result
    }
}
