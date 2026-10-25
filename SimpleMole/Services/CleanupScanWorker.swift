import Darwin
import Foundation
import CoreServices

enum CleanupScanMode: String, Codable, Sendable {
    case quick, deep
}

/// In-memory, display-only rule inventory. Watch before measuring, flush queued
/// events before reuse, and periodically recalibrate even an unchanged tree.
/// The deletion edge never consults this cache.
final class CleanupPathInventoryCache: @unchecked Sendable {
    private final class Context {
        weak var owner: CleanupPathInventoryCache?
        init(_ owner: CleanupPathInventoryCache) { self.owner = owner }
    }
    struct Ticket {
        fileprivate let revision: UInt64
        fileprivate let pathRevision: UInt64
        fileprivate let signature: String
        fileprivate let path: String
        let cached: CleanupScanWorker.MetadataInventory?
    }
    private struct Record {
        let signature: String
        let inventory: CleanupScanWorker.MetadataInventory
        let createdAt: TimeInterval
    }
    private let streamLock = NSLock()
    private let recordsLock = NSLock()
    private let queue = DispatchQueue(label: "nori.cleanup-inventory-events", qos: .utility)
    private let queueKey = DispatchSpecificKey<UInt8>()
    private var stream: FSEventStreamRef?
    private var watchedParent = ""
    private var revision: UInt64 = 0
    private var records: [String: Record] = [:]
    private var needsRestart = false
    private var pathRevisionSerial: UInt64 = 0
    private var lastExpirySweep: TimeInterval = -.infinity
    private var observedPaths: [String: (physical: String, revision: UInt64)] = [:]

    init() { queue.setSpecific(key: queueKey, value: 1) }

    deinit { stopStream() }

    func begin(_ path: String, metadata: stat, watching root: String? = nil) -> Ticket {
        streamLock.lock()
        defer { streamLock.unlock() }
        let parent = (root.map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: path).deletingLastPathComponent()).resolvingSymlinksInPath().path
        recordsLock.lock()
        let restart = needsRestart
        needsRestart = false
        recordsLock.unlock()
        if watchedParent != parent || restart {
            stopStream()
            invalidate()
            watchedParent = parent
            let owner = Context(self)
            var context = FSEventStreamContext(version: 0,
                info: Unmanaged.passUnretained(owner).toOpaque(), retain: { info in
                    guard let info else { return nil }
                    _ = Unmanaged<Context>.fromOpaque(info).retain()
                    return info
                }, release: { info in
                    guard let info else { return }
                    Unmanaged<Context>.fromOpaque(info).release()
                }, copyDescription: nil)
            stream = FSEventStreamCreate(kCFAllocatorDefault, { _, info, count, rawPaths, flags, _ in
                guard let info else { return }
                let context = Unmanaged<Context>.fromOpaque(info).takeUnretainedValue()
                let restartFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs
                    | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
                    | kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged
                    | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount)
                let paths = Unmanaged<CFArray>.fromOpaque(rawPaths).takeUnretainedValue() as! [String]
                for position in 0..<min(count, paths.count) {
                    if flags[position] & restartFlags != 0 { context.owner?.invalidate(restartWatcher: true) }
                    else if flags[position] & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) == 0 {
                        context.owner?.invalidate(changedPath: paths[position])
                    }
                }
            }, &context, [parent] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1,
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes))
            if let stream {
                FSEventStreamSetDispatchQueue(stream, queue)
                if !FSEventStreamStart(stream) { stopStream() }
            }
        }
        if let stream { FSEventStreamFlushSync(stream) }
        recordsLock.lock()
        defer { recordsLock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastExpirySweep >= 30 {
            records = records.filter { now - $0.value.createdAt < 300 }
            lastExpirySweep = now
        }
        if observedPaths[path] == nil {
            if observedPaths.count >= 2048 {
                // Uncached roots must not evict validated snapshots merely by
                // being observed. Retired in-flight tickets fail their revision
                // check if the same path is admitted again later.
                observedPaths = observedPaths.filter { records[$0.key] != nil }
            }
            pathRevisionSerial &+= 1
            observedPaths[path] = (URL(fileURLWithPath: path).resolvingSymlinksInPath().path, pathRevisionSerial)
        }
        let signature = Self.signature(metadata)
        let record = records[path]
        let age = record.map { ProcessInfo.processInfo.systemUptime - $0.createdAt } ?? .infinity
        let cached = stream != nil && record?.signature == signature && age >= 0 && age < 300
            ? record?.inventory : nil
        return Ticket(revision: revision, pathRevision: observedPaths[path]!.revision,
            signature: signature, path: path, cached: cached)
    }

    func store(_ inventory: CleanupScanWorker.MetadataInventory, ticket: Ticket) {
        guard inventory.isCacheable else { return }
        streamLock.lock()
        defer { streamLock.unlock() }
        guard let stream else { return }
        FSEventStreamFlushSync(stream)
        var current = stat()
        guard lstat(ticket.path, &current) == 0, Self.signature(current) == ticket.signature else { return }
        recordsLock.lock()
        defer { recordsLock.unlock() }
        guard revision == ticket.revision, observedPaths[ticket.path]?.revision == ticket.pathRevision else { return }
        // Admit within the fixed budget instead of clearing all snapshots at
        // capacity. A sequential scan larger than the cache can then reuse its
        // admitted roots on every pass rather than continuously thrashing.
        let replacing = records[ticket.path]?.inventory.paths.count ?? 0
        guard records[ticket.path] != nil || records.count < 1024,
              records.values.reduce(0, { $0 + $1.inventory.paths.count }) - replacing
                + inventory.paths.count <= 100_000 else { return }
        records[ticket.path] = Record(signature: ticket.signature, inventory: inventory,
            createdAt: ProcessInfo.processInfo.systemUptime)
    }

    /// All events, including dropped events, root changes and mounts, discard
    /// the snapshot. A failed watcher simply disables reuse.
    func invalidate(restartWatcher: Bool = false) {
        recordsLock.lock()
        revision &+= 1
        records.removeAll()
        observedPaths.removeAll()
        needsRestart = needsRestart || restartWatcher
        recordsLock.unlock()
    }

    private func invalidate(changedPath: String) {
        recordsLock.lock()
        defer { recordsLock.unlock() }
        for (path, observed) in observedPaths where changedPath == observed.physical
            || changedPath.hasPrefix(observed.physical + "/") || observed.physical.hasPrefix(changedPath + "/") {
            pathRevisionSerial &+= 1
            observedPaths[path] = (observed.physical, pathRevisionSerial)
            records.removeValue(forKey: path)
        }
    }

    private func stopStream() {
        guard let existing = stream else { return }
        stream = nil
        FSEventStreamStop(existing)
        FSEventStreamInvalidate(existing)
        FSEventStreamRelease(existing)
        // Drain old callbacks before starting a replacement subscription.
        if DispatchQueue.getSpecific(key: queueKey) == nil { queue.sync {} }
    }

    private static func signature(_ info: stat) -> String {
        "\(info.st_dev):\(info.st_ino):\(info.st_mode):\(info.st_flags):\(info.st_size):\(info.st_blocks):\(info.st_nlink):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
    }
}

/// A single cancellation/deadline shared by discovery and all sizing workers.
/// Deep scans have no per-directory cutoff; they remain user-cancellable.
final class CleanupScanControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var lastDirectory = ""
    private var lastDirectorySentAt = -Double.infinity
    private var discardedHits = 0
    private var discardedReads = 0
    private var ruleHits = 0
    private var ruleReads = 0
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

    func recordDiscardedPreview(cached: Bool) {
        lock.lock()
        if cached { discardedHits += 1 } else { discardedReads += 1 }
        lock.unlock()
    }

    var discardedPreviewCounts: (cached: Int, measured: Int) {
        lock.lock(); defer { lock.unlock() }
        return (discardedHits, discardedReads)
    }

    func recordRulePreview(cached: Bool) {
        lock.lock()
        if cached { ruleHits += 1 } else { ruleReads += 1 }
        lock.unlock()
    }

    var rulePreviewCounts: (cached: Int, measured: Int) {
        lock.lock(); defer { lock.unlock() }
        return (ruleHits, ruleReads)
    }
}

/// Size-only traversal. FTS supplies type, inode and allocated blocks together;
/// the cleanup path does not build the analyzer's large-file report per file.
/// The same walk also collects the newest file mtime/atime so activity gating
/// never needs a second traversal.
enum CleanupScanWorker {
    /// Age-gated rules recheck file activity from the saved flat inventory.
    /// Access-only changes need not emit FSEvents; no directory enumeration or
    /// file-content reads are needed to retain the existing age semantics.
    static func activity(in paths: [String], control: CleanupScanControl,
                         deadline: TimeInterval,
                         evidence: (String, stat) -> stat = { _, info in info }) -> (modified: Date?, accessed: Date?)? {
        var modified: Date?
        var accessed: Date?
        for path in paths {
            guard !control.shouldStop, control.elapsed < deadline else { return nil }
            var info = stat()
            guard lstat(path, &info) == 0 else { return nil }
            guard info.st_mode & S_IFMT == S_IFREG else { continue }
            info = evidence(path, info)
            modified = max(modified ?? .distantPast, Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)))
            accessed = max(accessed ?? .distantPast, Date(timeIntervalSince1970: TimeInterval(info.st_atimespec.tv_sec)))
        }
        return (modified, accessed)
    }

    struct NpmContentAgeScope: Sendable {
        let contentRoot: String
        let retention: TimeInterval
        let now: Date

        func contains(_ path: String) -> Bool { path == contentRoot || path.hasPrefix(contentRoot + "/") }
        func isStale(_ measurement: Measurement) -> Bool {
            measurement.complete && measurement.activityEvidenceIsComplete
                && CleanupAgePolicy.isStale(measurement.activityEvidence, now: now, retention: retention)
        }
    }

    /// Postorder nodes come from the already authenticated secure traversal.
    /// Cached activity refresh uses one lstat per node and no directory walk.
    struct AgeNode: Sendable {
        let path: String
        var measurement: Measurement
        let isDirectory: Bool
        let requiresAdministrator: Bool
        let hasHardlinks: Bool
    }

    struct NpmAgeTree {
        let nodes: [AgeNode]
        let scope: NpmContentAgeScope
        private let indices: [String: Int]
        private let children: [[Int]]
        private let containsStale: [Bool]

        init(nodes: [AgeNode], scope: NpmContentAgeScope) {
            let indices = Dictionary(uniqueKeysWithValues: nodes.indices.map { (nodes[$0].path, $0) })
            var children = Array(repeating: [Int](), count: nodes.count)
            var stale = Array(repeating: false, count: nodes.count)
            for index in nodes.indices {
                let node = nodes[index]
                stale[index] = stale[index] || (scope.contains(node.path) && scope.isStale(node.measurement))
                if let parent = indices[(node.path as NSString).deletingLastPathComponent] {
                    children[parent].append(index)
                    stale[parent] = stale[parent] || stale[index]
                }
            }
            self.nodes = nodes; self.scope = scope; self.indices = indices
            self.children = children; self.containsStale = stale
        }

        func frontier(under path: String) -> [AgeNode]? {
            guard scope.contains(path), let root = indices[path] else { return nil }
            // Avoid overstating independently counted allocation for shared
            // hardlinks. An entirely stale original unit still coalesces.
            guard !nodes[root].hasHardlinks || scope.isStale(nodes[root].measurement) else { return nil }
            var pending = [root]
            var result: [AgeNode] = []
            while let index = pending.popLast() {
                let node = nodes[index]
                if scope.isStale(node.measurement) || !containsStale[index] || children[index].isEmpty {
                    if node.measurement.files > 0 && node.measurement.bytes > 0 { result.append(node) }
                } else {
                    pending.append(contentsOf: children[index])
                }
            }
            return result
        }
    }

    static func refreshedAgeNodes(_ nodes: [AgeNode], control: CleanupScanControl,
                                  deadline: TimeInterval,
                                  evidence: (String, stat) -> stat) -> [AgeNode]? {
        var refreshed = nodes
        let indices = Dictionary(uniqueKeysWithValues: nodes.indices.map { (nodes[$0].path, $0) })
        for index in refreshed.indices {
            guard !control.shouldStop, control.elapsed < deadline else { return nil }
            var info = stat()
            guard lstat(nodes[index].path, &info) == 0,
                  info.st_mode & S_IFMT == (nodes[index].isDirectory ? S_IFDIR : S_IFREG) else { return nil }
            refreshed[index].measurement.newestModified = nil
            refreshed[index].measurement.newestAccessed = nil
            refreshed[index].measurement.activityEvidenceIsComplete = true
            if !nodes[index].isDirectory {
                info = evidence(nodes[index].path, info)
                refreshed[index].measurement.newestModified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
                refreshed[index].measurement.newestAccessed = Date(timeIntervalSince1970: TimeInterval(info.st_atimespec.tv_sec))
                refreshed[index].measurement.activityEvidenceIsComplete = info.st_mtimespec.tv_sec > 0 && info.st_atimespec.tv_sec > 0
            }
        }
        // Nodes are postorder, so every child updates its parent exactly once.
        for index in refreshed.indices {
            guard let parent = indices[(nodes[index].path as NSString).deletingLastPathComponent] else { continue }
            let child = refreshed[index].measurement
            if let date = child.newestModified {
                refreshed[parent].measurement.newestModified = max(refreshed[parent].measurement.newestModified ?? .distantPast, date)
            }
            if let date = child.newestAccessed {
                refreshed[parent].measurement.newestAccessed = max(refreshed[parent].measurement.newestAccessed ?? .distantPast, date)
            }
            refreshed[parent].measurement.activityEvidenceIsComplete = refreshed[parent].measurement.activityEvidenceIsComplete && child.activityEvidenceIsComplete
        }
        return refreshed
    }

    struct MetadataInventory: Sendable {
        var measurement: Measurement
        var paths: [String]
        var requiresAdministrator: Bool
        var isCacheable = true
        var validationContext: String? = nil
        var ageNodes: [AgeNode] = []
    }

    /// Discarded items need allocated blocks and deletion metadata, never file
    /// contents. Returning nil sends unusual/blocked trees to the secure walker.
    static func discardedInventory(_ path: String, control: CleanupScanControl,
                                   deadline: TimeInterval = .infinity,
                                   retainedPathLimit: Int = 100_000,
                                   inspect: (String, stat) -> Bool?) -> MetadataInventory? {
        let began = ProcessInfo.processInfo.systemUptime
        guard !control.shouldStop, let name = strdup(path) else { return nil }
        defer { free(name) }
        var paths: [UnsafeMutablePointer<CChar>?] = [name, nil]
        guard let tree = paths.withUnsafeMutableBufferPointer({
            fts_open($0.baseAddress!, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil)
        }) else { return nil }
        defer { fts_close(tree) }
        var inventory = MetadataInventory(measurement: Measurement(), paths: [], requiresAdministrator: false)
        var seen = Set<Identity>()
        var device: dev_t?
        while true {
            guard !control.shouldStop,
                  control.elapsed < deadline,
                  ProcessInfo.processInfo.systemUptime - began < control.directoryBudget else { return nil }
            errno = 0
            guard let entry = fts_read(tree) else { return errno == 0 ? inventory : nil }
            let info = Int32(entry.pointee.fts_info)
            if info == FTS_DP { continue }
            guard [FTS_F, FTS_D, FTS_SL, FTS_SLNONE].contains(info),
                  entry.pointee.fts_level < 128,
                  let metadata = entry.pointee.fts_statp?.pointee,
                  let rawPath = entry.pointee.fts_path else { return nil }
            if device == nil { device = metadata.st_dev }
            guard metadata.st_dev == device else { return nil }
            let current = String(cString: rawPath)
            guard let administrator = inspect(current, metadata) else { return nil }
            inventory.requiresAdministrator = inventory.requiresAdministrator || administrator
            if inventory.isCacheable {
                if inventory.paths.count < retainedPathLimit { inventory.paths.append(current) }
                else {
                    // Large trees still finish one metadata pass. They simply
                    // avoid retaining an oversized display snapshot.
                    inventory.paths.removeAll(keepingCapacity: false)
                    inventory.isCacheable = false
                }
            }
            if info == FTS_D { control.reportDirectory(current) }
            if info == FTS_F && metadata.st_nlink > 1,
               !seen.insert(Identity(device: metadata.st_dev, inode: metadata.st_ino)).inserted { continue }
            inventory.measurement.bytes &+= UInt64(max(0, metadata.st_blocks)) * 512
            if info != FTS_D { inventory.measurement.files += 1 }
            if info == FTS_F {
                let modified = Date(timeIntervalSince1970: TimeInterval(metadata.st_mtimespec.tv_sec))
                let accessed = Date(timeIntervalSince1970: TimeInterval(metadata.st_atimespec.tv_sec))
                inventory.measurement.newestModified = max(inventory.measurement.newestModified ?? .distantPast, modified)
                inventory.measurement.newestAccessed = max(inventory.measurement.newestAccessed ?? .distantPast, accessed)
            }
        }
    }

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
        var activityEvidenceIsComplete = true

        /// Combined activity evidence for the measured tree.
        var activityEvidence: Date? {
            guard activityEvidenceIsComplete else { return nil }
            return CleanupAgePolicy.activityEvidence(modified: newestModified,
                                              accessed: newestAccessed)
        }
    }

    static func measure(_ path: String, control: CleanupScanControl) -> Measurement {
        let measured = FileScanService.measure(path, policy: .cleanup,
            maximumSeconds: control.directoryBudget,
            shouldStop: { control.shouldStop }, onDirectory: control.reportDirectory)
        return Measurement(bytes: measured.bytes, files: measured.files, complete: measured.complete,
            newestModified: measured.newestModified, newestAccessed: measured.newestAccessed)
    }

    private struct Identity: Hashable {
        let device: dev_t
        let inode: ino_t
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
