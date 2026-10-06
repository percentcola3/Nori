import Darwin
import Foundation

/// Each analysis section owns its inventory. The directory index detects added
/// and removed names; file fingerprints detect edits that do not touch a parent
/// directory's modification date.
enum AnalysisInventoryKind: String, Codable, CaseIterable {
    case disk, largeFiles, images, videos

    func acceptsName(_ path: String) -> Bool {
        switch self {
        case .disk, .largeFiles: return true
        case .images: return MediaSlimPolicy.kind(forPath: path) == .image
        case .videos: return MediaSlimPolicy.kind(forPath: path) == .video
        }
    }

    var minimumBytes: UInt64 {
        switch self {
        case .disk: return 0
        case .largeFiles: return 100 << 20
        case .images: return MediaSlimPolicy.imageMinimumBytes
        case .videos: return MediaSlimPolicy.videoMinimumBytes
        }
    }
}

struct AnalysisFileFingerprint: Codable, Equatable {
    let device: UInt64
    let inode: UInt64
    let mode: UInt32
    let bytes: UInt64
    let allocated: UInt64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64

    init(_ info: stat) {
        device = UInt64(UInt32(bitPattern: info.st_dev))
        inode = UInt64(info.st_ino)
        mode = UInt32(info.st_mode)
        bytes = UInt64(max(0, info.st_size))
        allocated = UInt64(max(0, info.st_blocks)) * 512
        modifiedSeconds = Int64(info.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
        changedSeconds = Int64(info.st_ctimespec.tv_sec)
        changedNanoseconds = Int64(info.st_ctimespec.tv_nsec)
    }

    static func read(_ path: String) -> AnalysisFileFingerprint? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return .init(info)
    }

    var isDirectory: Bool { mode & UInt32(S_IFMT) == UInt32(S_IFDIR) }
    var isRegularFile: Bool { mode & UInt32(S_IFMT) == UInt32(S_IFREG) }
}

private struct AnalysisFileIdentity: Hashable {
    let device: UInt64
    let inode: UInt64
    init(_ fingerprint: AnalysisFileFingerprint) {
        device = fingerprint.device
        inode = fingerprint.inode
    }
}

/// Explicit disk-accounting scopes. The overview path is a navigation key only;
/// it is never enumerated or offered to a filesystem mutation.
enum AnalysisDiskScopes {
    static let overviewPath = "nori://disk-scopes"
    static let systemRoots = ["/private/var/log", "/private/var/folders", "/private/tmp",
                              "/private/var/tmp", "/private/var/vm", "/System/Volumes/VM",
                              "/private/var/db/powerlog", "/private/var/db/diagnostics", "/Library/Caches"]

    static func physicalPath(_ path: String) -> String {
        // Foundation's standardization shortens /private/var and /private/tmp
        // back into their symlink aliases. POSIX realpath preserves the actual
        // directory chain used by the no-follow cleanup executor.
        if let resolved = path.withCString({ realpath($0, nil) }) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        for alias in ["/var", "/tmp", "/etc"] {
            if standardized == alias || standardized.hasPrefix(alias + "/") {
                return "/private" + standardized
            }
        }
        return standardized
    }

    static func normalizedRoots(_ roots: [String], home: String) -> [String] {
        let homePath = URL(fileURLWithPath: home).standardizedFileURL.path
        let physicalHome = physicalPath(homePath)
        let normalizedPaths: [String] = roots.map { path -> String in
            let physical = physicalPath(path)
            // Preserve persisted home keys, even when the caller's fixture or
            // home lives below /var rather than its /private/var spelling.
            if physical == physicalHome { return homePath }
            if physical.hasPrefix(physicalHome + "/") {
                return homePath + String(physical.dropFirst(physicalHome.count))
            }
            return physical
        }
        let uniquePaths = Set(normalizedPaths)
        let candidates = uniquePaths.sorted { lhs, rhs in
            let lhsLength = lhs.utf8.count
            let rhsLength = rhs.utf8.count
            return lhsLength == rhsLength ? lhs < rhs : lhsLength < rhsLength
        }
        var identities = Set<AnalysisFileIdentity>()
        var accepted: [(path: String, fingerprint: AnalysisFileFingerprint?)] = []
        for path in candidates {
            let fingerprint = AnalysisFileFingerprint.read(path)
            if let fingerprint, fingerprint.isDirectory {
                guard identities.insert(AnalysisFileIdentity(fingerprint)).inserted else { continue }
                // An ancestor covers this root only on the same device. An
                // explicitly listed mounted scope remains its own traversal.
                if accepted.contains(where: {
                    path.hasPrefix($0.path + "/") && $0.fingerprint?.device == fingerprint.device
                }) { continue }
            }
            accepted.append((path, fingerprint))
        }
        return accepted.map(\.path)
    }
}

struct AnalysisInventorySnapshot: Codable {
    struct Directory: Codable {
        var fingerprint: AnalysisFileFingerprint
        /// Physical child directories and this section's relevant file names.
        var directories: [String]
        var files: [String]
    }

    let kind: AnalysisInventoryKind
    let home: String
    let roots: [String]
    var scannedAt: Date
    var directories: [String: Directory]
    /// Small files remain indexed so a later edit can promote them into results.
    var files: [String: AnalysisFileFingerprint]
    var issues: [AnalyzeReport.ScanIssue] = []
    var issueCount = 0
    /// Failed memberships must be listed again even when directory metadata is unchanged.
    /// Optional for compatibility with existing independent category cache files.
    var unreadableDirectories: Set<String>? = nil

    /// Repair known keys using the cached membership tree. A single file
    /// deletion visits only that file and its parent, not every indexed path.
    @discardableResult
    mutating func removeKnownPaths(_ requested: Set<String>) -> Set<String> {
        guard !requested.isEmpty else { return [] }
        var pending = Array(requested)
        for root in roots where requested.contains(where: { $0 == "/" || root.hasPrefix($0 + "/") }) {
            pending.append(root)
        }
        var removed = Set<String>()
        var parents = Set<String>()
        while let path = pending.popLast() {
            guard removed.insert(path).inserted else { continue }
            if let directory = directories.removeValue(forKey: path) {
                pending.append(contentsOf: directory.directories)
                pending.append(contentsOf: directory.files)
            }
            files.removeValue(forKey: path)
            parents.insert((path as NSString).deletingLastPathComponent)
        }
        for parent in parents where directories[parent] != nil {
            directories[parent]?.files.removeAll(where: removed.contains)
            directories[parent]?.directories.removeAll(where: removed.contains)
        }
        return removed
    }

    var report: AnalyzeReport {
        if kind == .disk { return AnalysisDiskBrowserInventory(snapshot: self).report(for: self) }
        struct Identity: Hashable {
            let device: UInt64
            let inode: UInt64
        }
        var seen = Set<Identity>()
        let candidates = files.filter { $0.value.allocated >= kind.minimumBytes }
            .sorted {
                if $0.value.allocated != $1.value.allocated {
                    return $0.value.allocated > $1.value.allocated
                }
                return $0.key < $1.key
            }
            .filter { seen.insert(.init(device: $0.value.device, inode: $0.value.inode)).inserted }
        var result = AnalyzeReport(path: "/", overview: true, entries: [],
            largeFiles: kind == .largeFiles ? candidates.map {
                .init(name: ($0.key as NSString).lastPathComponent,
                      path: $0.key, size: $0.value.allocated)
            } : [],
            totalSize: candidates.reduce(0) { $0 + $1.value.allocated },
            totalFiles: files.count, isPartial: issueCount > 0)
        if kind != .largeFiles {
            let mediaKind: MediaKind = kind == .images ? .image : .video
            result.media = candidates.map {
                .init(name: ($0.key as NSString).lastPathComponent,
                      path: $0.key, size: $0.value.allocated, kind: mediaKind)
            }
            var summary = MediaSummary()
            for candidate in candidates { summary.add(mediaKind, bytes: candidate.value.allocated) }
            result.mediaSummary = summary
        }
        result.scanIssues = issues
        result.scanIssueCount = issueCount
        return result
    }
}

struct AnalysisInventoryScanStatistics {
    var listedDirectories = 0
    var reusedDirectories = 0
    var inspectedFiles = 0
    var reusedFiles = 0
    var changedFiles = 0
}

struct AnalysisInventoryScanResult {
    var snapshot: AnalysisInventorySnapshot
    var report: AnalyzeReport
    var statistics: AnalysisInventoryScanStatistics
    var canReuse: Bool
    var cacheRevision: UInt64 = 0
    var cachedSnapshots: [AnalysisInventoryKind: AnalysisInventorySnapshot] = [:]
    var cachedReports: [AnalysisInventoryKind: AnalyzeReport] = [:]
    var diskBrowser: AnalysisDiskBrowserInventory? = nil
}

struct AnalysisInventoryCacheState {
    var snapshots: [AnalysisInventoryKind: AnalysisInventorySnapshot]
    var revision: UInt64
    var reports: [AnalysisInventoryKind: AnalyzeReport] = [:]
    var diskBrowser: AnalysisDiskBrowserInventory? = nil
}

enum AnalysisInventoryWorker {
    static func defaultRoots(home: String = NSHomeDirectory(), kind: AnalysisInventoryKind = .largeFiles) -> [String] {
        if kind == .disk {
            return AnalysisDiskScopes.normalizedRoots([home] + AnalysisDiskScopes.systemRoots, home: home)
        }
        var roots = [URL(fileURLWithPath: home).standardizedFileURL.path]
        if let volumes = try? FileManager.default.contentsOfDirectory(atPath: "/Volumes") {
            roots += volumes.sorted().compactMap { name in
                let path = "/Volumes/" + name
                guard AnalysisFileFingerprint.read(path)?.isDirectory == true else { return nil }
                return path
            }
        }
        return roots
    }

    static func scan(_ kind: AnalysisInventoryKind, roots: [String],
                     home: String = NSHomeDirectory(), previous: AnalysisInventorySnapshot? = nil,
                     forceFull: Bool = false, control: CleanupScanControl,
                     progressInterval: TimeInterval = 0.15,
                     progress: ((String, UInt64) -> Void)? = nil) -> AnalysisInventoryScanResult {
        let normalizedHome = URL(fileURLWithPath: home).standardizedFileURL.path
        let normalizedRoots = kind == .disk ? AnalysisDiskScopes.normalizedRoots(roots, home: normalizedHome)
            : Array(Set(roots.map { URL(fileURLWithPath: $0).standardizedFileURL.path })).sorted()
        let retained = previous?.home == normalizedHome && previous?.kind == kind ? previous : nil
        let old = forceFull ? nil : retained
        var snapshot = AnalysisInventorySnapshot(kind: kind, home: normalizedHome,
            roots: normalizedRoots, scannedAt: Date(), directories: [:], files: [:])
        var statistics = AnalysisInventoryScanStatistics()
        var nextProgress = -Double.infinity
        var candidateBytes: UInt64 = 0
        var failedRoots = 0
        var unreadable = Set<String>()
        var visitedDirectories = Set<AnalysisFileIdentity>()
        var countedFiles = Set<AnalysisFileIdentity>()
        func retainUnreadableSubtree(_ path: String, fingerprint: AnalysisFileFingerprint) {
            unreadable.insert(path)
            guard let cached = retained?.directories[path], cached.fingerprint.device == fingerprint.device,
                  cached.fingerprint.inode == fingerprint.inode else {
                snapshot.directories[path] = .init(fingerprint: fingerprint, directories: [], files: [])
                return
            }
            var pending = [path]
            while let child = pending.popLast() {
                guard let directory = retained?.directories[child] else { continue }
                snapshot.directories[child] = directory
                for file in directory.files { snapshot.files[file] = retained?.files[file] }
                pending.append(contentsOf: directory.directories)
            }
        }
        func issue(_ path: String, code: Int32) {
            // A scope or indexed folder losing access must not silently become
            // an empty, apparently complete result.
            snapshot.issueCount += 1
            if snapshot.issues.count < 32 {
                snapshot.issues.append(.init(path: path, kind: .readFailure, errorCode: code))
            }
        }
        func publish(_ path: String) {
            let now = ProcessInfo.processInfo.systemUptime
            guard now >= nextProgress else { return }
            nextProgress = now + progressInterval
            progress?(path, candidateBytes)
        }
        for root in normalizedRoots {
            if control.isCancelled { break }
            guard let rootInfo = AnalysisFileFingerprint.read(root), rootInfo.isDirectory else {
                let code = errno
                failedRoots += 1
                issue(root, code: code)
                if kind == .disk, code != ENOENT, let cached = retained?.directories[root] {
                    retainUnreadableSubtree(root, fingerprint: cached.fingerprint)
                }
                continue
            }
            var pending = [root]
            while let path = pending.popLast(), !control.isCancelled {
                publish(path)
                guard let current = AnalysisFileFingerprint.read(path) else {
                    if errno != ENOENT {
                        issue(path, code: errno)
                        if kind == .disk, let cached = retained?.directories[path] {
                            retainUnreadableSubtree(path, fingerprint: cached.fingerprint)
                        }
                    }
                    continue
                }
                guard current.isDirectory, current.device == rootInfo.device else { continue }
                guard visitedDirectories.insert(AnalysisFileIdentity(current)).inserted else { continue }
                let directory: AnalysisInventorySnapshot.Directory
                if let cached = old?.directories[path], cached.fingerprint == current,
                   old?.unreadableDirectories?.contains(path) != true {
                    directory = cached
                    statistics.reusedDirectories += 1
                } else {
                    let names: [String]
                    do {
                        names = try FileManager.default.contentsOfDirectory(atPath: path)
                    } catch {
                        if path == root { failedRoots += 1 }
                        let posix = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
                        issue(path, code: posix.map { Int32($0.code) } ?? EIO)
                        if kind == .disk { retainUnreadableSubtree(path, fingerprint: current) }
                        continue
                    }
                    statistics.listedDirectories += 1
                    var children: [String] = []
                    var files: [String] = []
                    for name in names.sorted() {
                        if control.isCancelled { break }
                        // Own a native Swift string once at the filesystem edge.
                        // NSPathStore2-backed full paths make Unicode comparison
                        // and hashing disproportionately expensive in large indexes.
                        let foundationPath = (path as NSString).appendingPathComponent(name)
                        let child = String(decoding: foundationPath.utf8, as: UTF8.self)
                        // A probe below a directory lets the common eligibility
                        // policy reject package/hidden/dependency directory roots.
                        let directoryEligible = kind == .disk || MediaSlimPolicy.isEligible(
                            (child as NSString).appendingPathComponent("analysis-probe"), home: normalizedHome)
                        let fileEligible = kind.acceptsName(child) &&
                            (kind == .disk || MediaSlimPolicy.isEligible(child, home: normalizedHome))
                        guard directoryEligible || fileEligible else { continue }
                        guard let info = AnalysisFileFingerprint.read(child) else {
                            let code = errno
                            if code != ENOENT {
                                issue(child, code: code)
                                unreadable.insert(path)
                                if kind == .disk {
                                    if retained?.directories[child] != nil { children.append(child) }
                                    else if let cached = retained?.files[child] {
                                        files.append(child)
                                        snapshot.files[child] = cached
                                    }
                                }
                            }
                            continue
                        }
                        if info.isDirectory, directoryEligible, info.device == rootInfo.device {
                            children.append(child)
                        } else if info.isRegularFile, fileEligible, info.device == rootInfo.device {
                            files.append(child)
                        }
                    }
                    // If listing raced with a directory change, leave its earlier signature so next scan
                    // lists it again rather than treating the partial names as fresh.
                    directory = .init(fingerprint: current, directories: children, files: files)
                }
                snapshot.directories[path] = directory
                pending.append(contentsOf: directory.directories.reversed())
                for file in directory.files {
                    if control.isCancelled { break }
                    statistics.inspectedFiles += 1
                    guard let fingerprint = AnalysisFileFingerprint.read(file) else {
                        if errno != ENOENT {
                            issue(file, code: errno)
                            unreadable.insert(path)
                            if kind == .disk { snapshot.files[file] = retained?.files[file] }
                        }
                        continue
                    }
                    guard fingerprint.isRegularFile, fingerprint.device == rootInfo.device else { continue }
                    if old?.files[file] == fingerprint {
                        statistics.reusedFiles += 1
                        snapshot.files[file] = old!.files[file]
                    } else {
                        statistics.changedFiles += 1
                        snapshot.files[file] = fingerprint
                    }
                    if fingerprint.allocated >= kind.minimumBytes,
                       countedFiles.insert(AnalysisFileIdentity(fingerprint)).inserted {
                        candidateBytes += fingerprint.allocated
                    }
                    publish(file)
                }
            }
        }
        snapshot.unreadableDirectories = unreadable.isEmpty ? nil : unreadable
        let diskBrowser = kind == .disk ? AnalysisDiskBrowserInventory(snapshot: snapshot) : nil
        var report = diskBrowser?.report(for: snapshot) ?? snapshot.report
        if control.isCancelled {
            report.isPartial = true
            report.scanIssues = (report.scanIssues ?? []) + [.init(path: "/", kind: .cancelled)]
            report.scanIssueCount = (report.scanIssueCount ?? 0) + 1
        } else if !normalizedRoots.isEmpty && failedRoots == normalizedRoots.count {
            report.error = "Analysis roots could not be read."
        }
        // Disk accounting can retain useful partial data with explicit retry markers.
        // Failed/cancelled scans still preserve the previous usable inventory.
        return .init(snapshot: snapshot, report: report, statistics: statistics,
                     canReuse: !control.isCancelled && report.error == nil && (kind == .disk || snapshot.issueCount == 0),
                     diskBrowser: diskBrowser)
    }
}

/// Disk persistence and mutation repair run on the utility executor. Restoration
/// is a display snapshot; cleanup still validates the live file at the final edge.
final class AnalysisInventoryCache: @unchecked Sendable {
    private let lock = NSLock()
    private let directory: URL
    private let home: String
    private var loaded = false
    private var revision: UInt64 = 0
    private var snapshots: [AnalysisInventoryKind: AnalysisInventorySnapshot] = [:]
    private var reports: [AnalysisInventoryKind: AnalyzeReport] = [:]
    private var diskBrowser: AnalysisDiskBrowserInventory?
    private static let version = 2

    private struct Payload: Codable {
        let version: Int
        let snapshot: AnalysisInventorySnapshot
    }

    init(directory: URL? = nil, home: String = NSHomeDirectory()) {
        self.home = URL(fileURLWithPath: home).standardizedFileURL.path
        self.directory = directory ?? URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Application Support/Nori/Analysis")
    }

    func restore() -> [AnalysisInventoryKind: AnalysisInventorySnapshot] {
        restoreState().snapshots
    }

    /// The cleanup pipeline deleted the Analysis inventory. The revision bump
    /// rejects results from scans already in flight, so they cannot persist
    /// stale snapshots again; only this cache's own *.json files are removed.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        snapshots = [:]
        reports = [:]
        diskBrowser = nil
        revision &+= 1
        loaded = true
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            where name.hasSuffix(".json") || name.hasSuffix(".cache") {
            discard(name)
        }
    }

    private func discard(_ name: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }

    var currentRevision: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return revision
    }

    func restoreState() -> AnalysisInventoryCacheState {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        return .init(snapshots: snapshots, revision: revision, reports: reports, diskBrowser: diskBrowser)
    }

    func scan(_ kind: AnalysisInventoryKind, forceFull: Bool = false,
              roots: [String]? = nil, control: CleanupScanControl,
              progress: ((String, UInt64) -> Void)? = nil) -> AnalysisInventoryScanResult {
        let initial = restoreState()
        var result = AnalysisInventoryWorker.scan(kind,
            roots: roots ?? AnalysisInventoryWorker.defaultRoots(home: home, kind: kind), home: home,
            previous: initial.snapshots[kind], forceFull: forceFull, control: control, progress: progress)
        lock.lock()
        defer { lock.unlock() }
        // Cancellation and cleanup can arrive after the final filesystem read.
        // Neither is allowed to overwrite a newer mutation repair on disk.
        guard revision == initial.revision, !control.isCancelled else {
            result.canReuse = false
            result.cacheRevision = initial.revision
            return result
        }
        if result.canReuse {
            snapshots[kind] = result.snapshot
            reports[kind] = result.report
            if kind == .disk { diskBrowser = result.diskBrowser }
            revision &+= 1
            persist(result.snapshot)
        }
        result.cacheRevision = revision
        result.cachedSnapshots = snapshots
        result.cachedReports = reports
        result.diskBrowser = diskBrowser
        return result
    }

    /// Repair only known mutations. No directory walk is needed after a cleanup
    /// or compression, and all previously scanned sections receive the same edit.
    func refresh(removedPaths: Set<String>, changedPaths: Set<String>)
        -> [AnalysisInventoryKind: AnalysisInventorySnapshot] {
        refreshState(removedPaths: removedPaths, changedPaths: changedPaths).snapshots
    }

    func refreshState(removedPaths: Set<String>, changedPaths: Set<String>) -> AnalysisInventoryCacheState {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        revision &+= 1
        // Read each confirmed changed file once, shared by all classifications.
        let changedFiles = changedPaths.reduce(into: [String: AnalysisFileFingerprint]()) { result, path in
            if let fingerprint = AnalysisFileFingerprint.read(path), fingerprint.isRegularFile {
                result[path] = fingerprint
            }
        }
        for kind in Array(snapshots.keys) {
            guard var snapshot = snapshots[kind] else { continue }
            let previous = snapshot
            let actualRemoved = snapshot.removeKnownPaths(removedPaths)
            var changedIdentities: [AnalysisFileIdentity: AnalysisFileFingerprint] = [:]
            for path in changedPaths where !actualRemoved.contains(path) {
                let parent = (path as NSString).deletingLastPathComponent
                snapshot.files.removeValue(forKey: path)
                guard kind.acceptsName(path),
                      (kind == .disk || MediaSlimPolicy.isEligible(path, home: home)),
                      snapshot.roots.contains(where: { path.hasPrefix($0 + "/") }),
                      let fingerprint = changedFiles[path],
                      snapshot.directories[parent]?.fingerprint.device == fingerprint.device else {
                    snapshot.directories[parent]?.files.removeAll { $0 == path }
                    continue
                }
                snapshot.files[path] = fingerprint
                changedIdentities[AnalysisFileIdentity(fingerprint)] = fingerprint
                if snapshot.directories[parent]?.files.contains(path) == false {
                    snapshot.directories[parent]?.files.append(path)
                }
            }
            if !changedIdentities.isEmpty {
                // One in-memory pass covers all changed physical objects, rather
                // than scanning every indexed alias once per selected file.
                var aliases: [(String, AnalysisFileFingerprint)] = []
                for (path, fingerprint) in snapshot.files {
                    if let replacement = changedIdentities[AnalysisFileIdentity(fingerprint)], replacement != fingerprint {
                        aliases.append((path, replacement))
                    }
                }
                for (path, fingerprint) in aliases { snapshot.files[path] = fingerprint }
            }
            if kind == .disk {
                if diskBrowser == nil { diskBrowser = AnalysisDiskBrowserInventory(snapshot: previous) }
                diskBrowser?.repair(from: previous, to: snapshot, removed: actualRemoved.contains, changedPaths: changedPaths)
                reports[kind] = diskBrowser?.report(for: snapshot)
            } else { reports[kind] = snapshot.report }
            snapshots[kind] = snapshot
            persist(snapshot)
        }
        return .init(snapshots: snapshots, revision: revision, reports: reports, diskBrowser: diskBrowser)
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        for kind in AnalysisInventoryKind.allCases {
            // 旧版明文 JSON（含全盘逐文件的 disk.json）不再解码，直接移除。
            discard(kind.rawValue + ".json")
            guard Self.persists(kind),
                  let compressed = try? Data(contentsOf: fileURL(kind)),
                  let data = try? (compressed as NSData).decompressed(using: .lzfse) as Data,
                  let payload = try? JSONDecoder().decode(Payload.self, from: data),
                  payload.version == Self.version, payload.snapshot.kind == kind,
                  payload.snapshot.home == home else { continue }
            snapshots[kind] = payload.snapshot
            reports[kind] = payload.snapshot.report
        }
    }

    /// 全盘清单逐文件记录整个家目录，体积与文件数成正比：只保留在会话
    /// 内存里，重启后重新扫描。分类清单体积有界，压缩后落盘。
    private static func persists(_ kind: AnalysisInventoryKind) -> Bool { kind != .disk }

    private func fileURL(_ kind: AnalysisInventoryKind) -> URL {
        directory.appendingPathComponent(kind.rawValue + ".cache")
    }

    private func persist(_ snapshot: AnalysisInventorySnapshot) {
        guard Self.persists(snapshot.kind),
              let data = try? JSONEncoder().encode(Payload(version: Self.version, snapshot: snapshot)),
              let compressed = try? (data as NSData).compressed(using: .lzfse) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? (compressed as Data).write(to: fileURL(snapshot.kind), options: .atomic)
    }
}

/// Background projection of the physical directory inventory. Browsing is a
/// dictionary lookup; confirmed mutations update only affected ancestor totals
/// and columns, without listing the filesystem again.
struct AnalysisDiskBrowserInventory {
    private typealias Identity = AnalysisFileIdentity

    let rootPath: String
    let homePath: String
    private let scopePaths: [String]
    private(set) var entriesByPath: [String: [AnalyzeEntry]] = [:]
    private var sizesByPath: [String: UInt64] = [:]
    private var owners: [Identity: String] = [:]
    private var partialPaths: Set<String> = []
    private(set) var repairedDirectoryCount = 0

    init(snapshot: AnalysisInventorySnapshot) {
        rootPath = AnalysisDiskScopes.overviewPath
        homePath = snapshot.home
        scopePaths = Self.cachedScopes(for: snapshot)
        sizesByPath.reserveCapacity(snapshot.directories.count + snapshot.files.count)
        owners.reserveCapacity(snapshot.files.count)
        entriesByPath.reserveCapacity(snapshot.directories.count + 1)
        // Only hardlinks require a path comparison. A streamed minimum keeps
        // deterministic ownership without sorting every long filesystem path.
        for (path, file) in snapshot.files {
            let identity = Identity(file)
            if let owner = owners[identity] {
                if path < owner { owners[identity] = path }
            } else { owners[identity] = path }
        }
        var directoryOrder: [(path: String, parent: String, length: Int)] = []
        directoryOrder.reserveCapacity(snapshot.directories.count)
        for (path, directory) in snapshot.directories {
            var bytes = directory.fingerprint.allocated
            // The membership index already knows the parent. This avoids a
            // Foundation parent-path operation for every indexed file.
            for filePath in directory.files {
                guard let file = snapshot.files[filePath] else { continue }
                let allocated = owners[Identity(file)] == filePath ? file.allocated : 0
                sizesByPath[filePath] = allocated
                bytes &+= allocated
            }
            sizesByPath[path] = bytes
            directoryOrder.append((path, (path as NSString).deletingLastPathComponent, path.utf8.count))
        }
        // Compute lengths once; descendant paths always have greater byte length.
        directoryOrder.sort { $0.length > $1.length }
        for directory in directoryOrder {
            if let parentBytes = sizesByPath[directory.parent], let bytes = sizesByPath[directory.path] {
                sizesByPath[directory.parent] = parentBytes &+ bytes
            }
        }
        partialPaths = Self.partialPaths(for: snapshot)
        for path in snapshot.directories.keys { rebuildColumn(path, snapshot: snapshot) }
        rebuildOverview(snapshot: snapshot)
    }

    func report(for snapshot: AnalysisInventorySnapshot) -> AnalyzeReport {
        var report = AnalyzeReport(path: rootPath, overview: true,
            entries: entriesByPath[rootPath] ?? [], largeFiles: [],
            totalSize: scopePaths.reduce(0) { $0 &+ (sizesByPath[$1] ?? 0) },
            totalFiles: snapshot.files.count, isPartial: snapshot.issueCount > 0)
        report.scanIssues = snapshot.issues
        report.scanIssueCount = snapshot.issueCount
        return report
    }

    mutating func repair(from old: AnalysisInventorySnapshot, to updated: AnalysisInventorySnapshot,
                         removed: (String) -> Bool, changedPaths: Set<String>) {
        var touched = Set<String>()
        var affectedIdentities = Set<Identity>()
        var adjustedFiles = changedPaths
        for (path, fingerprint) in old.files where removed(path) {
            adjustedFiles.insert(path)
            affectedIdentities.insert(Identity(fingerprint))
        }
        for path in changedPaths {
            if let before = old.files[path] { affectedIdentities.insert(Identity(before)) }
            if let after = updated.files[path] { affectedIdentities.insert(Identity(after)) }
        }
        // Reassign blocks if an owning hardlink was removed or replaced. This is
        // an in-memory lookup over known files, never another filesystem scan.
        var newOwners: [Identity: String] = [:]
        if !affectedIdentities.isEmpty {
            for (path, fingerprint) in updated.files {
                let identity = Identity(fingerprint)
                guard affectedIdentities.contains(identity) else { continue }
                if newOwners[identity].map({ path < $0 }) ?? true { newOwners[identity] = path }
            }
        }
        for identity in affectedIdentities {
            if let previous = owners[identity] { adjustedFiles.insert(previous) }
            if let next = newOwners[identity] { adjustedFiles.insert(next) }
            owners[identity] = newOwners[identity]
        }
        for path in adjustedFiles {
            let before = sizesByPath[path] ?? 0
            let after: UInt64
            if let file = updated.files[path] {
                after = owners[Identity(file)] == path ? file.allocated : 0
                sizesByPath[path] = after
            } else {
                after = 0
                sizesByPath.removeValue(forKey: path)
            }
            adjustAncestors(of: path, before: before, after: after, touched: &touched)
        }
        for (path, directory) in old.directories where updated.directories[path] == nil {
            sizesByPath.removeValue(forKey: path)
            entriesByPath.removeValue(forKey: path)
            adjustAncestors(of: path, before: directory.fingerprint.allocated, after: 0, touched: &touched)
        }
        for (path, directory) in updated.directories where old.directories[path] == nil {
            sizesByPath[path] = directory.fingerprint.allocated
            touched.insert(path)
            adjustAncestors(of: path, before: 0, after: directory.fingerprint.allocated, touched: &touched)
        }
        // Unknown subtrees retain their partial marker until a successful retry.
        // Removing one never turns the remaining cached entries into trusted data.
        partialPaths = Self.partialPaths(for: updated)
        let available = touched.filter { updated.directories[$0] != nil }
        repairedDirectoryCount = available.count
        for path in available { rebuildColumn(path, snapshot: updated) }
        rebuildOverview(snapshot: updated)
    }

    private mutating func adjustAncestors(of path: String, before: UInt64, after: UInt64,
                                         touched: inout Set<String>) {
        var ancestor = (path as NSString).deletingLastPathComponent
        while !ancestor.isEmpty {
            if let bytes = sizesByPath[ancestor] {
                sizesByPath[ancestor] = (bytes >= before ? bytes - before : 0) &+ after
                touched.insert(ancestor)
            }
            let parent = (ancestor as NSString).deletingLastPathComponent
            if parent == ancestor { break }
            ancestor = parent
        }
    }

    private mutating func rebuildColumn(_ path: String, snapshot: AnalysisInventorySnapshot) {
        guard let directory = snapshot.directories[path] else { return }
        let children = directory.directories.filter { snapshot.directories[$0] != nil }
            .map { entry($0, isDirectory: true) }
        let files = directory.files.filter { snapshot.files[$0] != nil }
            .map { entry($0, isDirectory: false) }
        entriesByPath[path] = (children + files).sorted {
            // Every entry shares this column's parent; comparing just names
            // preserves path order without repeatedly comparing the long prefix.
            $0.size == $1.size ? $0.name < $1.name : $0.size > $1.size
        }
    }

    private mutating func rebuildOverview(snapshot: AnalysisInventorySnapshot) {
        entriesByPath[rootPath] = scopePaths.map { path in
            // Full physical paths distinguish log, folders, tmp, swap and
            // system caches without pretending they cover the entire disk.
            AnalyzeEntry(name: path == homePath ? (path as NSString).lastPathComponent : path,
                         path: path, size: sizesByPath[path] ?? 0, isDir: true,
                         isPartial: partialPaths.contains(path) || snapshot.directories[path] == nil)
        }.sorted { lhs, rhs in
            // 用户数据在前，系统日志/临时/交换/缓存排在后面；组内按容量。
            let lhsSystem = !isUserScope(lhs.path), rhsSystem = !isUserScope(rhs.path)
            if lhsSystem != rhsSystem { return rhsSystem }
            return lhs.size == rhs.size ? lhs.name < rhs.name : lhs.size > rhs.size
        }
        for path in scopePaths where snapshot.directories[path] == nil {
            entriesByPath[path] = []
        }
    }

    private func isUserScope(_ path: String) -> Bool {
        path == homePath || path.hasPrefix(homePath + "/")
    }

    private func entry(_ path: String, isDirectory: Bool) -> AnalyzeEntry {
        AnalyzeEntry(name: (path as NSString).lastPathComponent, path: path,
                     size: sizesByPath[path] ?? 0, isDir: isDirectory,
                     isPartial: partialPaths.contains(path))
    }

    private static func partialPaths(for snapshot: AnalysisInventorySnapshot) -> Set<String> {
        var result = Set<String>()
        let failed = snapshot.unreadableDirectories ?? []
        guard !failed.isEmpty || !snapshot.issues.isEmpty else { return [] }
        // Only unreadable cached subtrees inherit an untrusted marker. A small
        // permission failure must not walk every unrelated file's ancestors.
        var pending = Array(failed)
        var visited = Set<String>()
        while let path = pending.popLast() {
            guard visited.insert(path).inserted else { continue }
            result.insert(path)
            guard let directory = snapshot.directories[path] else { continue }
            for file in directory.files where snapshot.files[file] != nil { result.insert(file) }
            pending.append(contentsOf: directory.directories)
        }
        // Ancestors expose a partial size, while their other children remain trusted.
        for path in failed.union(Set(snapshot.issues.map(\.path))) {
            var ancestor = path
            while !ancestor.isEmpty {
                result.insert(ancestor)
                let parent = (ancestor as NSString).deletingLastPathComponent
                if parent == ancestor { break }
                ancestor = parent
            }
        }
        return result
    }

    /// Restore defensively without touching the filesystem. Older or imported
    /// inventories may contain repeated aliases or nested scopes; cached
    /// directory identities already tell us whether their allocation overlaps.
    private static func cachedScopes(for snapshot: AnalysisInventorySnapshot) -> [String] {
        var identities = Set<Identity>()
        var result: [String] = []
        let uniqueRoots: Set<String> = Set(snapshot.roots)
        let sortedRoots = uniqueRoots.sorted { lhs, rhs in
            let lhsLength = lhs.utf8.count
            let rhsLength = rhs.utf8.count
            return lhsLength == rhsLength ? lhs < rhs : lhsLength < rhsLength
        }
        for path in sortedRoots {
            if let fingerprint = snapshot.directories[path]?.fingerprint {
                guard identities.insert(Identity(fingerprint)).inserted else { continue }
                if result.contains(where: {
                    path.hasPrefix($0 + "/") &&
                        snapshot.directories[$0]?.fingerprint.device == fingerprint.device
                }) { continue }
            }
            result.append(path)
        }
        return result
    }
}
