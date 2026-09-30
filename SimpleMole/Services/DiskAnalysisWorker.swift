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

    static func scan(_ path: String, control: CleanupScanControl,
                     home: String = NSHomeDirectory(),
                     progressInterval: TimeInterval = 0.15,
                     progress: ((AnalyzeReport) -> Void)? = nil) -> AnalyzeReport {
        let root = URL(fileURLWithPath: path).standardizedFileURL
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
            return report
        }
        var rootStat = stat()
        let rootBytes = lstat(root.path, &rootStat) == 0 ? UInt64(max(0, rootStat.st_blocks)) * 512 : 0
        var seen = Set<Identity>()
        var rows: [AnalyzeEntry] = []
        var totalFiles = 0
        var largeFiles: [AnalyzeReport.LargeFile] = []
        var directoryReports: [String: AnalyzeReport] = [:]
        var media: [MediaFile] = []
        var mediaSummary = MediaSummary()
        var incomplete = false
        var lastProgress = -Double.infinity

        func snapshot(partial: Bool, currentEntry: AnalyzeEntry? = nil,
                      currentPath: String? = nil) -> AnalyzeReport {
            var trimmed = media
            trimMedia(&trimmed)
            var entries = rows
            if let currentEntry { entries.append(currentEntry) }
            var report = AnalyzeReport(path: root.path, overview: root.path == "/",
                                       entries: entries.sorted(by: AnalyzeEntry.analysisOrder),
                                       largeFiles: largeFiles.sorted { $0.size > $1.size },
                                       totalSize: rootBytes + entries.reduce(0) { $0 + $1.size },
                                       totalFiles: totalFiles, isPartial: partial)
            report.media = trimmed.sorted { $0.size > $1.size }
            report.mediaSummary = mediaSummary
            report.currentPath = currentPath
            return report
        }

        for child in children {
            if control.isCancelled { incomplete = true; break }
            var metadata = stat()
            let available = lstat(child.path, &metadata) == 0
            let directory = available && (metadata.st_mode & S_IFMT) == S_IFDIR
            var bytes: UInt64 = 0
            var partial = !available
            var stack: [Directory] = []
            func publishProgress(at path: String) {
                guard let progress else { return }
                let now = ProcessInfo.processInfo.systemUptime
                guard now - lastProgress >= progressInterval else { return }
                lastProgress = now
                // Include the active subtree's measured bytes. Waiting for its
                // final FTS_DP can leave a large Library/developer tree silent
                // for minutes even though files are still being visited.
                let current = AnalyzeEntry(name: child.lastPathComponent, path: child.path,
                                           size: bytes, isDir: directory, cleanable: false,
                                           isPartial: true)
                progress(snapshot(partial: true, currentEntry: current, currentPath: path))
            }
            func append(_ row: AnalyzeEntry, files: Int) {
                guard !stack.isEmpty else { return }
                stack[stack.count - 1].entries.append(row)
                stack[stack.count - 1].bytes += row.size
                stack[stack.count - 1].files += files
                stack[stack.count - 1].partial = stack.last!.partial || row.isPartial == true
            }
            func finishDirectory(interrupted: Bool = false) {
                guard var directory = stack.popLast() else { return }
                let partial = interrupted || directory.partial
                trimMedia(&directory.media)
                var directoryReport = AnalyzeReport(
                    path: directory.path, overview: false,
                    entries: directory.entries.sorted(by: AnalyzeEntry.analysisOrder),
                    largeFiles: directory.largeFiles, totalSize: directory.bytes, totalFiles: directory.files,
                    isPartial: partial)
                directoryReport.media = directory.media.sorted { $0.size > $1.size }
                directoryReport.mediaSummary = directory.mediaSummary
                directoryReports[directory.path] = directoryReport
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
                            if errno != 0 { partial = true }
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
                            guard let info = item.fts_statp?.pointee else { partial = true; continue }
                            if Int32(item.fts_info) == FTS_D && info.st_dev != metadata.st_dev {
                                partial = true
                                append(AnalyzeEntry(name: itemName, path: itemPath, size: 0,
                                                    isDir: true, cleanable: false, isPartial: true), files: 0)
                                continue
                            }
                            var allocated = UInt64(max(0, info.st_blocks)) * 512
                            if info.st_nlink > 1 && Int32(item.fts_info) == FTS_F {
                                if !seen.insert(Identity(device: info.st_dev, inode: info.st_ino)).inserted {
                                    allocated = 0
                                }
                            }
                            bytes += allocated
                            if Int32(item.fts_info) == FTS_D {
                                stack.append(Directory(path: itemPath, bytes: allocated))
                            } else {
                                append(AnalyzeEntry(name: itemName, path: itemPath, size: allocated,
                                                    isDir: false, cleanable: false, isPartial: false),
                                       files: Int32(item.fts_info) == FTS_F ? 1 : 0)
                            }
                            if Int32(item.fts_info) == FTS_F,
                               let kind = MediaSlimPolicy.kind(forPath: itemName),
                               allocated >= MediaSlimPolicy.minimumBytes(for: kind),
                               MediaSlimPolicy.isEligible(itemPath, home: home) {
                                let file = MediaFile(name: itemName, path: itemPath, size: allocated, kind: kind)
                                mediaSummary.add(kind, bytes: allocated)
                                media.append(file)
                                trimMedia(&media, slack: 4)
                                if !stack.isEmpty {
                                    stack[stack.count - 1].media.append(file)
                                    trimMedia(&stack[stack.count - 1].media, slack: 4)
                                    stack[stack.count - 1].mediaSummary.add(kind, bytes: allocated)
                                }
                            }
                            if Int32(item.fts_info) == FTS_F {
                                totalFiles += 1
                                if allocated >= 100 * 1024 * 1024 {
                                    let filePath = String(cString: item.fts_path)
                                    largeFiles.append(.init(name: URL(fileURLWithPath: filePath).lastPathComponent,
                                                            path: filePath, size: allocated))
                                    if !stack.isEmpty {
                                        stack[stack.count - 1].largeFiles.append(largeFiles.last!)
                                        if stack.last!.largeFiles.count > 100 {
                                            stack[stack.count - 1].largeFiles.sort { $0.size > $1.size }
                                            stack[stack.count - 1].largeFiles.removeLast()
                                        }
                                    }
                                    if largeFiles.count > 100 {
                                        largeFiles.sort { $0.size > $1.size }
                                        largeFiles.removeLast()
                                    }
                                }
                            }
                        default: break
                        }
                        publishProgress(at: itemPath)
                    }
                } else { partial = true }
            } else { partial = true }
            while !stack.isEmpty { finishDirectory(interrupted: true) }
            // Analysis never promotes a directory to a cleanup target merely
            // because its name resembles a cache or build output directory.
            rows.append(AnalyzeEntry(name: child.lastPathComponent, path: child.path,
                                     size: bytes, isDir: directory, cleanable: false,
                                     isPartial: partial))
            incomplete = incomplete || partial
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastProgress >= progressInterval {
                lastProgress = now
                progress?(snapshot(partial: true, currentPath: child.path))
            }
        }
        var result = snapshot(partial: incomplete || control.isCancelled)
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
        let root = URL(fileURLWithPath: path).standardizedFileURL.path
        func contains(_ ancestor: String, _ descendant: String) -> Bool {
            ancestor == "/" || ancestor == descendant || descendant.hasPrefix(ancestor + "/")
        }
        reports = reports.filter { !contains(root, $0.key) && !contains($0.key, root) }
    }

    mutating func clear() { reports.removeAll() }
}
