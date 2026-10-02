import Darwin
import Foundation

/// Enumerate the selected folder's actual children and measure allocated blocks.
/// Analysis has no cleanup time budget. Unreadable/cancelled trees are lower bounds.
enum DiskAnalysisWorker {
    private struct Identity: Hashable {
        let device: dev_t
        let inode: ino_t
    }

    private struct Directory {
        let path: String
        var bytes: UInt64
        var entries: [AnalyzeEntry] = []
        var files = 0
        var partial = false
        var largeFiles: [AnalyzeReport.LargeFile] = []
        var media: [MediaFile] = []
        var mediaSummary = MediaSummary()
    }

    /// 顶层子目录的遍历结果汇入这里的全局累加器。硬链接按 (device, inode)
    /// 全局去重，top-N 截断与进度快照也都是跨子目录状态；锁只出现在低频
    /// 事件（硬链接命中、媒体/大文件命中、目录收尾、进度节流）上。
    private final class SharedState {
        let lock = NSLock()
        var seen = Set<Identity>()
        var rows: [AnalyzeEntry] = []
        var largeFiles: [AnalyzeReport.LargeFile] = []
        var media: [MediaFile] = []
        var mediaSummary = MediaSummary()
        var directoryReports: [String: AnalyzeReport] = [:]
        var totalFiles = 0
        var incomplete = false
        var lastProgress = -Double.infinity
        var scanIssues: [AnalyzeReport.ScanIssue] = []
        var scanIssueCount = 0
    }

    /// Keep the largest files per kind; trimming lazily keeps appends cheap.
    static func trimMedia(_ list: inout [MediaFile], slack: Int = 1) {
        let cap = MediaSlimPolicy.perKindCap
        guard list.count > cap * slack else { return }
        var trimmed: [MediaFile] = []
        for kind in MediaKind.allCases {
            trimmed += list.filter { $0.kind == kind }.sorted { $0.size > $1.size }.prefix(cap)
        }
        list = trimmed.sorted { $0.size > $1.size }
    }

    static func failureDetails(for report: AnalyzeReport,
                               using localize: (String) -> String) -> [String] {
        var details = (report.scanIssues ?? []).map { issue in
            let key: String
            switch issue.kind {
            case .otherVolume: key = "scan.reason.otherVolume"
            case .cancelled: key = "scan.reason.cancelled"
            case .readFailure:
                switch issue.errorCode {
                case EACCES, EPERM: key = "scan.reason.access"
                case ENOENT, ENOTDIR: key = "scan.reason.changed"
                default: key = "scan.reason.read"
                }
            }
            var text = localize(key) + "\n" + issue.path
            if let code = issue.errorCode, code != 0 {
                text += "\n" + String(cString: strerror(code)) + " (" + String(code) + ")"
            }
            return text
        }
        if let error = report.error, !error.isEmpty { details.append(error) }
        let omitted = (report.scanIssueCount ?? 0) - (report.scanIssues?.count ?? 0)
        if omitted > 0 { details.append(String(format: localize("scan.reason.more"), omitted)) }
        if details.isEmpty { details.append(localize("scan.reason.unknown") + "\n" + report.path) }
        return details
    }

    static func scan(_ path: String, control: CleanupScanControl,
                     home: String = NSHomeDirectory(),
                     progressInterval: TimeInterval = 0.15,
                     progress: ((AnalyzeReport) -> Void)? = nil) -> AnalyzeReport {
        let root = URL(fileURLWithPath: path).standardizedFileURL
        // Root scans feed only the aggregated categories; drilling into the
        // directory index is not offered there, so per-directory reports and
        // their entry buffers are not accumulated for the whole filesystem.
        let collectDirectoryReports = root.path != "/"
        var report = AnalyzeReport(path: root.path, overview: root.path == "/", entries: [],
                                   largeFiles: [], totalSize: 0, totalFiles: 0)
        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil)
                .map { root.appendingPathComponent($0.lastPathComponent) }
                .sorted { $0.path < $1.path }
        } catch {
            report.isPartial = true
            report.error = error.localizedDescription
            let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
            report.scanIssues = [.init(path: root.path, kind: .readFailure,
                errorCode: underlying?.domain == NSPOSIXErrorDomain ? Int32(underlying!.code) : nil)]
            report.scanIssueCount = 1
            return report
        }
        var rootStat = stat()
        let rootBytes = lstat(root.path, &rootStat) == 0 ? UInt64(max(0, rootStat.st_blocks)) * 512 : 0
        let shared = SharedState()

        func recordIssue(_ path: String, kind: AnalyzeReport.ScanIssue.Kind = .readFailure,
                         errorCode: Int32? = nil) {
            shared.lock.lock()
            defer { shared.lock.unlock() }
            shared.scanIssueCount += 1
            if shared.scanIssues.count < 32 {
                shared.scanIssues.append(.init(path: path, kind: kind, errorCode: errorCode))
            }
        }

        func makeSnapshot(partial: Bool, currentEntry: AnalyzeEntry? = nil,
                          currentPath: String? = nil) -> AnalyzeReport {
            shared.lock.lock()
            defer { shared.lock.unlock() }
            var trimmed = shared.media
            trimMedia(&trimmed)
            var entries = shared.rows
            if let currentEntry { entries.append(currentEntry) }
            var snapshot = AnalyzeReport(path: root.path, overview: root.path == "/",
                                         entries: entries.sorted(by: AnalyzeEntry.analysisOrder),
                                         largeFiles: shared.largeFiles.sorted { $0.size > $1.size },
                                         totalSize: rootBytes + entries.reduce(0) { $0 + $1.size },
                                         totalFiles: shared.totalFiles, isPartial: partial)
            snapshot.media = trimmed.sorted { $0.size > $1.size }
            snapshot.mediaSummary = shared.mediaSummary
            snapshot.scanIssues = shared.scanIssues.sorted { $0.path < $1.path }
            snapshot.scanIssueCount = shared.scanIssueCount
            snapshot.currentPath = currentPath
            return snapshot
        }

        func scanChild(_ child: URL) {
            if control.isCancelled {
                shared.lock.lock()
                shared.incomplete = true
                shared.lock.unlock()
                return
            }
            var metadata = stat()
            let available = lstat(child.path, &metadata) == 0
            if !available { recordIssue(child.path, errorCode: errno) }
            let directory = available && (metadata.st_mode & S_IFMT) == S_IFDIR
            var bytes: UInt64 = 0
            var partial = !available
            var stack: [Directory] = []
            // 文件数按小批增量汇入全局计数：进度快照需要在遍历中看到
            // totalFiles 增长（中途取消依赖它），但又不必逐文件抢锁。
            var pendingFiles = 0
            func flushPendingFiles() {
                guard pendingFiles > 0 else { return }
                shared.lock.lock()
                shared.totalFiles += pendingFiles
                shared.lock.unlock()
                pendingFiles = 0
            }
            func publishProgress(at path: String) {
                guard let progress else { return }
                let now = ProcessInfo.processInfo.systemUptime
                var due = false
                shared.lock.lock()
                if now - shared.lastProgress >= progressInterval {
                    shared.lastProgress = now
                    due = true
                }
                shared.lock.unlock()
                guard due else { return }
                // Include the active subtree's measured bytes. Waiting for its
                // final FTS_DP can leave a large Library/developer tree silent
                // for minutes even though files are still being visited.
                let current = AnalyzeEntry(name: child.lastPathComponent, path: child.path,
                                           size: bytes, isDir: directory, cleanable: false,
                                           isPartial: true)
                progress(makeSnapshot(partial: true, currentEntry: current, currentPath: path))
            }
            func append(_ row: AnalyzeEntry, files: Int) {
                guard !stack.isEmpty else { return }
                if collectDirectoryReports { stack[stack.count - 1].entries.append(row) }
                stack[stack.count - 1].bytes += row.size
                stack[stack.count - 1].files += files
                stack[stack.count - 1].partial = stack.last!.partial || row.isPartial == true
            }
            func finishDirectory(interrupted: Bool = false) {
                guard var directory = stack.popLast() else { return }
                let partial = interrupted || directory.partial
                trimMedia(&directory.media)
                if collectDirectoryReports {
                    var directoryReport = AnalyzeReport(
                        path: directory.path, overview: false,
                        entries: directory.entries.sorted(by: AnalyzeEntry.analysisOrder),
                        largeFiles: directory.largeFiles, totalSize: directory.bytes, totalFiles: directory.files,
                        isPartial: partial)
                    directoryReport.media = directory.media.sorted { $0.size > $1.size }
                    directoryReport.mediaSummary = directory.mediaSummary
                    shared.lock.lock()
                    shared.directoryReports[directory.path] = directoryReport
                    shared.lock.unlock()
                }
                if !stack.isEmpty {
                    stack[stack.count - 1].media.append(contentsOf: directory.media)
                    trimMedia(&stack[stack.count - 1].media, slack: 4)
                    stack[stack.count - 1].mediaSummary.merge(directory.mediaSummary)
                }
                append(AnalyzeEntry(name: URL(fileURLWithPath: directory.path).lastPathComponent,
                                    path: directory.path, size: directory.bytes, isDir: true,
                                    cleanable: false, isPartial: partial), files: directory.files)
                if !stack.isEmpty && !directory.largeFiles.isEmpty {
                    stack[stack.count - 1].largeFiles.append(contentsOf: directory.largeFiles)
                    stack[stack.count - 1].largeFiles.sort { $0.size > $1.size }
                    if stack.last!.largeFiles.count > 100 {
                        stack[stack.count - 1].largeFiles.removeSubrange(100...)
                    }
                }
            }
            publishProgress(at: child.path)
            if available, let name = strdup(child.path) {
                defer { free(name) }
                var paths: [UnsafeMutablePointer<CChar>?] = [name, nil]
                // Do not follow symlinks or walk back into the Data volume via
                // /System/Volumes. A mounted child can be selected explicitly.
                if let tree = paths.withUnsafeMutableBufferPointer({
                    fts_open($0.baseAddress!, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil)
                }) {
                    defer { fts_close(tree) }
                    while true {
                        if control.isCancelled { partial = true; break }
                        errno = 0
                        guard let entry = fts_read(tree) else {
                            if errno != 0 {
                                let code = errno
                                partial = true
                                recordIssue(child.path, errorCode: code)
                            }
                            break
                        }
                        let item = entry.pointee
                        let itemPath = String(cString: item.fts_path)
                        let itemName = (itemPath as NSString).lastPathComponent
                        switch Int32(item.fts_info) {
                        case FTS_DP:
                            if stack.last?.path == itemPath { finishDirectory() }
                        case FTS_ERR, FTS_DNR, FTS_NS:
                            partial = true
                            recordIssue(itemPath, errorCode: item.fts_errno)
                            if stack.last?.path == itemPath {
                                // DNR/ERR terminate this directory without a later DP.
                                // Close it now so subsequent siblings keep their real parent.
                                finishDirectory(interrupted: true)
                            } else {
                                append(AnalyzeEntry(name: itemName, path: itemPath, size: 0,
                                                    isDir: Int32(item.fts_info) == FTS_DNR,
                                                    cleanable: false, isPartial: true), files: 0)
                            }
                        case FTS_F, FTS_D, FTS_SL, FTS_SLNONE:
                            guard let info = item.fts_statp?.pointee else {
                                partial = true
                                recordIssue(itemPath, errorCode: EIO)
                                continue
                            }
                            if Int32(item.fts_info) == FTS_D && info.st_dev != metadata.st_dev {
                                partial = true
                                recordIssue(itemPath, kind: .otherVolume)
                                append(AnalyzeEntry(name: itemName, path: itemPath, size: 0,
                                                    isDir: true, cleanable: false, isPartial: true), files: 0)
                                continue
                            }
                            var allocated = UInt64(max(0, info.st_blocks)) * 512
                            if info.st_nlink > 1 && Int32(item.fts_info) == FTS_F {
                                shared.lock.lock()
                                let doubleCounted = !shared.seen.insert(
                                    Identity(device: info.st_dev, inode: info.st_ino)).inserted
                                shared.lock.unlock()
                                if doubleCounted { allocated = 0 }
                            }
                            bytes += allocated
                            if Int32(item.fts_info) == FTS_D {
                                stack.append(Directory(path: itemPath, bytes: allocated))
                            } else {
                                append(AnalyzeEntry(name: itemName, path: itemPath, size: allocated,
                                                    isDir: false, cleanable: false, isPartial: false),
                                       files: Int32(item.fts_info) == FTS_F ? 1 : 0)
                                if Int32(item.fts_info) == FTS_F {
                                    pendingFiles += 1
                                    if pendingFiles >= 32 { flushPendingFiles() }
                                }
                            }
                            if Int32(item.fts_info) == FTS_F,
                               let kind = MediaSlimPolicy.kind(forPath: itemName),
                               allocated >= MediaSlimPolicy.minimumBytes(for: kind),
                               MediaSlimPolicy.isEligible(itemPath, home: home) {
                                let file = MediaFile(name: itemName, path: itemPath, size: allocated, kind: kind)
                                shared.lock.lock()
                                shared.mediaSummary.add(kind, bytes: allocated)
                                shared.media.append(file)
                                trimMedia(&shared.media, slack: 4)
                                shared.lock.unlock()
                                if !stack.isEmpty {
                                    stack[stack.count - 1].media.append(file)
                                    trimMedia(&stack[stack.count - 1].media, slack: 4)
                                    stack[stack.count - 1].mediaSummary.add(kind, bytes: allocated)
                                }
                            }
                            if Int32(item.fts_info) == FTS_F {
                                // Only user-managed locations qualify as "large
                                // files": system content cannot be cleaned here
                                // and would drown the useful rows.
                                if allocated >= 100 * 1024 * 1024,
                                   MediaSlimPolicy.isEligible(itemPath, home: home) {
                                    let large = AnalyzeReport.LargeFile(
                                        name: URL(fileURLWithPath: itemPath).lastPathComponent,
                                        path: itemPath, size: allocated)
                                    shared.lock.lock()
                                    shared.largeFiles.append(large)
                                    if shared.largeFiles.count > 100 {
                                        shared.largeFiles.sort { $0.size > $1.size }
                                        shared.largeFiles.removeLast()
                                    }
                                    shared.lock.unlock()
                                    if !stack.isEmpty {
                                        stack[stack.count - 1].largeFiles.append(large)
                                        if stack.last!.largeFiles.count > 100 {
                                            stack[stack.count - 1].largeFiles.sort { $0.size > $1.size }
                                            stack[stack.count - 1].largeFiles.removeLast()
                                        }
                                    }
                                }
                            }
                        default: break
                        }
                        publishProgress(at: itemPath)
                    }
                } else {
                    let code = errno
                    partial = true
                    recordIssue(child.path, errorCode: code)
                }
            } else {
                partial = true
                if available { recordIssue(child.path, errorCode: ENOMEM) }
            }
            while !stack.isEmpty { finishDirectory(interrupted: true) }
            // Analysis never promotes a directory to a cleanup target merely
            // because its name resembles a cache or build output directory.
            shared.lock.lock()
            shared.rows.append(AnalyzeEntry(name: child.lastPathComponent, path: child.path,
                                            size: bytes, isDir: directory, cleanable: false,
                                            isPartial: partial))
            shared.totalFiles += pendingFiles
            pendingFiles = 0
            shared.incomplete = shared.incomplete || partial
            shared.lock.unlock()
        }

        // 顶层子目录之间没有依赖：每个子目录一棵独立的 FTS 树，按子目录粒度
        // 并行（GCD 按可用核自适应调度），单个大目录不会被其他空目录阻塞。
        DispatchQueue.concurrentPerform(iterations: children.count) { index in
            scanChild(children[index])
        }

        shared.lock.lock()
        let incomplete = shared.incomplete
        let directoryReports = shared.directoryReports
        shared.lock.unlock()
        if control.isCancelled { recordIssue(root.path, kind: .cancelled) }
        var result = makeSnapshot(partial: incomplete || control.isCancelled)
        result.directoryReports = directoryReports
        return result
    }
}

/// Session snapshot: navigation only reads reports, never touches the disk.
struct DiskAnalysisCache {
    private var reports: [String: AnalyzeReport] = [:]

    func report(for path: String) -> AnalyzeReport? {
        reports[URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path]
    }

    mutating func store(_ report: AnalyzeReport) {
        guard report.error == nil else { return }
        reports.merge(report.directoryReports ?? [:]) { _, new in new }
        var root = report
        root.directoryReports = nil
        reports[root.path] = root
    }

    mutating func invalidate(_ path: String) {
        let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
        func contains(_ ancestor: String, _ descendant: String) -> Bool {
            ancestor == "/" || ancestor == descendant || descendant.hasPrefix(ancestor + "/")
        }
        reports = reports.filter { !contains(root, $0.key) && !contains($0.key, root) }
    }

    mutating func clear() { reports.removeAll() }
}
