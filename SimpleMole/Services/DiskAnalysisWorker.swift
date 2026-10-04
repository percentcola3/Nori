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
        var rows: [String: AnalyzeEntry] = [:]
        var visibleOwners = Set<String>()
        var active: [String: (owner: String, bytes: UInt64)] = [:]
        var temporaryProjects: [AnalyzeEntry] = []
        var largeFiles: [AnalyzeReport.LargeFile] = []
        var media: [MediaFile] = []
        var mediaSummary = MediaSummary()
        var directoryReports: [String: AnalyzeReport] = [:]
        var totalFiles = 0
        var incomplete = false
        var nextJob = 0
        var lastProgress = -Double.infinity
        var scanIssues: [AnalyzeReport.ScanIssue] = []
        var scanIssueCount = 0
    }

    /// Failed reads are left for FTS to produce an actionable diagnostic.
    static func partition(_ root: URL, expanding: Set<String>, control: CleanupScanControl)
        -> (paths: [URL], directoryBytes: UInt64) {
        var paths: [URL] = []
        var directoryBytes: UInt64 = 0
        func visit(_ url: URL, device: dev_t? = nil) {
            guard !control.isCancelled else { return }
            var info = stat()
            let available = lstat(url.path, &info) == 0
            if available, let device, (info.st_mode & S_IFMT) == S_IFDIR,
               info.st_dev != device { return }
            guard expanding.contains(url.path), available,
                  (info.st_mode & S_IFMT) == S_IFDIR,
                  let children = try? FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: nil) else {
                paths.append(url)
                return
            }
            directoryBytes += UInt64(max(0, info.st_blocks)) * 512
            for child in children.sorted(by: { $0.path < $1.path }) {
                visit(url.appendingPathComponent(child.lastPathComponent), device: info.st_dev)
            }
        }
        visit(root)
        return (paths, directoryBytes)
    }

    static func isTemporaryProjectPath(_ path: String) -> Bool {
        let canonical = URL(fileURLWithPath: path).standardizedFileURL.path
        let roots = ["/tmp", "/private/tmp", "/var/tmp", "/private/var/tmp",
                     FileManager.default.temporaryDirectory.standardizedFileURL.path,
                     FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path]
        return roots.contains { canonical.hasPrefix($0 + "/") }
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

    enum Completion { case complete, partial, cancelled, failed }

    /// Permission refusals within the tree are expected scan boundaries and
    /// remain silent. A root read failure, cancellation, or other I/O failures
    /// still have distinct outcomes. Internal partial sizes remain lower bounds.
    static func completion(for report: AnalyzeReport) -> Completion {
        if report.error != nil { return .failed }
        if report.scanIssues?.contains(where: { $0.kind == .cancelled }) == true { return .cancelled }
        if report.isPartial == true {
            let issues = report.scanIssues ?? []
            let onlyExpectedSkips = report.scanIssueCount == issues.count && issues.allSatisfy {
                $0.kind == .otherVolume || ($0.kind == .readFailure &&
                    ($0.errorCode == EACCES || $0.errorCode == EPERM))
            }
            if !onlyExpectedSkips { return .partial }
        }
        return .complete
    }

    static func failureDetails(for report: AnalyzeReport,
                               using localize: (String) -> String) -> [String] {
        guard completion(for: report) != .complete else { return [] }
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
                     overviewSplits: Set<String>? = nil,
                     progress: ((AnalyzeReport) -> Void)? = nil) -> AnalyzeReport {
        let root = URL(fileURLWithPath: path).standardizedFileURL
        // Root scans feed only the aggregated categories; drilling into the
        // directory index is not offered there, so per-directory reports and
        // their entry buffers are not accumulated for the whole filesystem.
        let collectDirectoryReports = root.path != "/" && overviewSplits == nil
        var report = AnalyzeReport(path: root.path, overview: root.path == "/", entries: [],
                                   largeFiles: [], totalSize: 0, totalFiles: 0)
        if root.path == "/dev" || root.path.hasPrefix("/dev/") {
            report.isPartial = false
            return report
        }
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
            // Full Disk Access does not override ownership, ACLs, or system
            // protection. Do not prompt or surface expected access refusals.
            // Root listing failures bypass this helper and remain fatal.
            if kind == .readFailure && (errorCode == EACCES || errorCode == EPERM) { return }
            shared.lock.lock()
            defer { shared.lock.unlock() }
            shared.scanIssueCount += 1
            let issue = AnalyzeReport.ScanIssue(path: path, kind: kind, errorCode: errorCode)
            if shared.scanIssues.count < 32 {
                shared.scanIssues.append(issue)
            } else if kind == .cancelled {
                // Completion must retain the terminal reason even after the
                // bounded examples are filled by other read failures.
                shared.scanIssues[shared.scanIssues.count - 1] = issue
            }
        }

        func makeSnapshot(partial: Bool,
                          currentPath: String? = nil) -> AnalyzeReport {
            shared.lock.lock()
            defer { shared.lock.unlock() }
            var trimmed = shared.media
            trimMedia(&trimmed)
            var entries = shared.rows
            for active in shared.active.values {
                if let row = entries[active.owner] {
                    entries[active.owner] = AnalyzeEntry(name: row.name, path: row.path,
                        size: row.size + active.bytes, isDir: row.isDir,
                        cleanable: false, isPartial: true)
                }
            }
            let rows = entries.values.filter { shared.visibleOwners.contains($0.path) }
            var snapshot = AnalyzeReport(path: root.path, overview: root.path == "/",
                                         entries: rows.sorted(by: AnalyzeEntry.analysisOrder),
                                         largeFiles: shared.largeFiles.sorted { $0.size > $1.size },
                                         totalSize: rootBytes + rows.reduce(0) { $0 + $1.size },
                                         totalFiles: shared.totalFiles, isPartial: partial)
            snapshot.media = trimmed.sorted { $0.size > $1.size }
            snapshot.mediaSummary = shared.mediaSummary
            snapshot.scanIssues = shared.scanIssues.sorted { $0.path < $1.path }
            snapshot.scanIssueCount = shared.scanIssueCount
            snapshot.temporaryProjects = shared.temporaryProjects.sorted(by: AnalyzeEntry.analysisOrder)
            snapshot.currentPath = currentPath
            return snapshot
        }

        func scanChild(_ child: URL, owner: URL) {
            if control.isCancelled {
                shared.lock.lock()
                shared.incomplete = true
                shared.lock.unlock()
                return
            }
            var metadata = stat()
            let available = lstat(child.path, &metadata) == 0
            if !available { recordIssue(child.path, errorCode: errno) }
            var bytes: UInt64 = 0
            var partial = !available
            var stack: [Directory] = []
            // 文件数按小批增量汇入全局计数：进度快照需要在遍历中看到
            // totalFiles 增长（中途取消依赖它），但又不必逐文件抢锁。
            var pendingFiles = 0
            var nextProgressTime = -Double.infinity
            var projectRoots = Set<String>()
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
                guard now >= nextProgressTime else { return }
                nextProgressTime = now + progressInterval
                var due = false
                shared.lock.lock()
                shared.visibleOwners.insert(owner.path)
                shared.active[child.path] = (owner.path, bytes)
                if now - shared.lastProgress >= progressInterval {
                    shared.lastProgress = now
                    due = true
                }
                shared.lock.unlock()
                guard due else { return }
                progress(makeSnapshot(partial: true, currentPath: path))
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
                if projectRoots.remove(directory.path) != nil {
                    shared.lock.lock()
                    shared.temporaryProjects.append(AnalyzeEntry(
                        name: URL(fileURLWithPath: directory.path).lastPathComponent,
                        path: directory.path, size: directory.bytes, isDir: true,
                        cleanable: false, isPartial: partial))
                    shared.temporaryProjects.sort(by: AnalyzeEntry.analysisOrder)
                    if shared.temporaryProjects.count > 100 { shared.temporaryProjects.removeLast() }
                    shared.lock.unlock()
                }
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
                if collectDirectoryReports && !stack.isEmpty {
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
                                // Intentional mount boundary: FTS_XDEV prevents descent.
                                append(AnalyzeEntry(name: itemName, path: itemPath, size: 0,
                                                    isDir: true, cleanable: false, isPartial: false), files: 0)
                                continue
                            }
                            if itemName == ".git", [FTS_D, FTS_F].contains(Int32(item.fts_info)) {
                                let parent = (itemPath as NSString).deletingLastPathComponent
                                if Self.isTemporaryProjectPath(parent) { projectRoots.insert(parent) }
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
                                if collectDirectoryReports && !stack.isEmpty {
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
                                    if collectDirectoryReports && !stack.isEmpty {
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
            shared.visibleOwners.insert(owner.path)
            shared.active.removeValue(forKey: child.path)
            let row = shared.rows[owner.path]!
            shared.rows[owner.path] = AnalyzeEntry(name: row.name, path: row.path,
                size: row.size + bytes, isDir: row.isDir, cleanable: false,
                isPartial: row.isPartial == true || partial)
            shared.totalFiles += pendingFiles
            pendingFiles = 0
            shared.incomplete = shared.incomplete || partial
            shared.lock.unlock()
        }

        // Split dominant overview trees into disjoint jobs; inode deduplication
        // and owner rows remain global, preserving exact final totals.
        let userTemp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let splitRoots: Set<String> = overviewSplits ?? (root.path == "/" ? [
            "/Users", home, home + "/Library", home + "/Code", home + "/Projects",
            home + "/Developer", home + "/Library/Application Support",
            home + "/Library/Developer", home + "/Library/Caches", home + "/Library/Containers",
            "/private", "/private/var", "/private/tmp", "/private/var/tmp", "/private/var/folders",
            userTemp.path, userTemp.deletingLastPathComponent().path,
            userTemp.deletingLastPathComponent().deletingLastPathComponent().path
        ] : [])
        var jobs: [(path: URL, owner: URL)] = []
        for child in children where child.path != "/dev" {
            var info = stat()
            let directory = lstat(child.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
            let plan = partition(child, expanding: splitRoots, control: control)
            shared.rows[child.path] = AnalyzeEntry(name: child.lastPathComponent,
                path: child.path, size: plan.directoryBytes, isDir: directory,
                cleanable: false, isPartial: false)
            if plan.directoryBytes > 0 { shared.visibleOwners.insert(child.path) }
            jobs += plan.paths.map { ($0, child) }
        }
        // Bound filesystem walkers to avoid oversubscribing storage.
        let workers = min(jobs.count, min(8, max(2, ProcessInfo.processInfo.activeProcessorCount)))
        if workers > 0 {
            DispatchQueue.concurrentPerform(iterations: workers) { _ in
                while !control.isCancelled {
                    shared.lock.lock()
                    let index = shared.nextJob
                    shared.nextJob += 1
                    shared.lock.unlock()
                    guard index < jobs.count else { break }
                    scanChild(jobs[index].path, owner: jobs[index].owner)
                }
            }
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

    /// 磁盘浏览器列布局：尾部两列完整显示，更早的层级折叠为窄条。
    /// 纯函数便于单测：navigation 深于两级时只保留最近两列展开。
    static func diskBrowserColumnLayout(_ nav: [String]) -> (collapsed: [String], expanded: [String]) {
        let expandedCount = min(2, nav.count)
        return (Array(nav.dropLast(expandedCount)), Array(nav.suffix(expandedCount)))
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
