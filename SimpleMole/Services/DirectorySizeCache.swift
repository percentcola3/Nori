import Darwin
import Foundation

struct DirectorySizeRecord: Equatable, Sendable {
    let result: DirectorySizeResult
    let updatedAt: Date
    let isStale: Bool
}

enum DirectorySizeRefreshMode: Equatable, Sendable {
    case incremental, calibration
}

struct DirectorySizeCacheDiagnostics: Sendable {
    let inspectedCount: Int
    let enumerationCount: Int
    let inspectedPaths: [String]
    let enumeratedDirectories: [String]
}

/// Persists physical directory membership and metadata, rather than just a
/// previous total. Invalidation updates only affected branches; calibration
/// checks nested mtime/ctime fingerprints without re-enumerating unchanged
/// directory membership. Stored records are immediately available after a
/// restart, but their first refresh always calibrates offline changes.
actor DirectorySizeCache {
    private struct Fingerprint: Codable, Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
        let mode: UInt16
        let linkCount: UInt64
        let bytes: Int64
        let logicalBytes: Int64
        let flags: UInt32
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64

        init(_ info: stat) {
            device = UInt64(bitPattern: Int64(info.st_dev))
            inode = UInt64(info.st_ino)
            mode = UInt16(info.st_mode & S_IFMT)
            linkCount = UInt64(info.st_nlink)
            let blocks = max(0, Int64(info.st_blocks))
            bytes = blocks > Int64.max / 512 ? Int64.max : blocks * 512
            logicalBytes = max(0, Int64(info.st_size))
            flags = info.st_flags
            modifiedSeconds = Int64(info.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
            changedSeconds = Int64(info.st_ctimespec.tv_sec)
            changedNanoseconds = Int64(info.st_ctimespec.tv_nsec)
        }

        var isDirectory: Bool { mode == UInt16(S_IFDIR) }
        var identity: String { "\(device):\(inode)" }
        func hasSameIdentity(as other: Fingerprint) -> Bool {
            device == other.device && inode == other.inode && mode == other.mode
        }
        func hasSameMembership(as other: Fingerprint) -> Bool {
            hasSameIdentity(as: other) && modifiedSeconds == other.modifiedSeconds
                && modifiedNanoseconds == other.modifiedNanoseconds
                && changedSeconds == other.changedSeconds && changedNanoseconds == other.changedNanoseconds
        }
    }

    private struct LinkedBytes: Codable, Equatable, Sendable {
        let bytes: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64

        func isNewer(than other: LinkedBytes) -> Bool {
            changedSeconds != other.changedSeconds ? changedSeconds > other.changedSeconds
                : changedNanoseconds > other.changedNanoseconds
        }
    }

    private struct Node: Codable, Sendable {
        let path: String
        let fingerprint: Fingerprint
        let children: [Node]
        let membershipComplete: Bool
        let normalBytes: Int64
        let hardlinks: [String: LinkedBytes]
        let isComplete: Bool

        init(path: String, fingerprint: Fingerprint, children: [Node],
             membershipComplete: Bool, ownBytes: Int64, complete: Bool) {
            self.path = path
            self.fingerprint = fingerprint
            self.children = children
            self.membershipComplete = membershipComplete
            var normal = ownBytes
            var links: [String: LinkedBytes] = [:]
            var complete = complete
            if !fingerprint.isDirectory && fingerprint.linkCount > 1 {
                normal = 0
                links[fingerprint.identity] = LinkedBytes(bytes: ownBytes,
                    changedSeconds: fingerprint.changedSeconds,
                    changedNanoseconds: fingerprint.changedNanoseconds)
            }
            for child in children {
                let addition = normal.addingReportingOverflow(child.normalBytes)
                normal = addition.overflow ? Int64.max : addition.partialValue
                complete = complete && child.isComplete && !addition.overflow
                for (identity, candidate) in child.hardlinks {
                    if let current = links[identity], !candidate.isNewer(than: current) { continue }
                    links[identity] = candidate
                }
            }
            self.normalBytes = normal
            self.hardlinks = links
            self.isComplete = complete
        }

        var result: DirectorySizeResult {
            var bytes = normalBytes
            var complete = isComplete
            for link in hardlinks.values {
                let addition = bytes.addingReportingOverflow(link.bytes)
                bytes = addition.overflow ? Int64.max : addition.partialValue
                complete = complete && !addition.overflow
            }
            return DirectorySizeResult(bytes: bytes, isComplete: complete)
        }
    }

    private struct StoredRoot: Codable, Sendable {
        let path: String
        let node: Node?
        let bytes: Int64
        let isComplete: Bool
        let updatedAt: Date
    }

    private struct Envelope: Codable {
        let version: Int
        let roots: [StoredRoot]
    }

    private enum ScanCancelled: Error { case cancelled }

    private final class Scanner {
        let rootPath: String
        let mode: DirectorySizeRefreshMode
        let dirty: Set<String>
        let observer: (@Sendable (String) async -> Void)?
        var rootDevice: UInt64?
        var rootMissing = false
        var rootUnreadable = false
        var inspectedCount = 0
        var enumerationCount = 0
        var inspectedPaths: [String] = []
        var enumeratedDirectories: [String] = []

        init(rootPath: String, mode: DirectorySizeRefreshMode, dirty: Set<String>,
             observer: (@Sendable (String) async -> Void)?) {
            self.rootPath = rootPath
            self.mode = mode
            self.dirty = dirty
            self.observer = observer
        }

        func scan(_ path: String, previous: Node?, force: Bool = false, depth: Int = 0) async throws -> Node? {
            try checkCancellation()
            if let previous, !force, mode == .incremental,
               !dirty.contains(where: { DirectorySizeCache.contains(path, $0) }) {
                return previous
            }
            inspectedCount += 1
            if inspectedPaths.count < 2048 { inspectedPaths.append(path) }
            await observer?(path)
            try checkCancellation()
            if inspectedCount % 64 == 0 { await Task.yield(); try checkCancellation() }
            var info = stat()
            guard lstat(path, &info) == 0 else {
                if path == rootPath && (errno == ENOENT || errno == ENOTDIR) { rootMissing = true }
                else if path == rootPath { rootUnreadable = true }
                return nil
            }
            let fingerprint = Fingerprint(info)
            if path == rootPath { rootDevice = fingerprint.device }
            guard fingerprint.isDirectory else {
                return Node(path: path, fingerprint: fingerprint, children: [], membershipComplete: true,
                            ownBytes: fingerprint.bytes, complete: true)
            }
            if fingerprint.device != rootDevice {
                // Match the physical walker: mounted children are excluded.
                return Node(path: path, fingerprint: fingerprint, children: [], membershipComplete: false,
                            ownBytes: 0, complete: false)
            }
            if (fingerprint.flags & 0x40000000) != 0 || depth >= 512 {
                return Node(path: path, fingerprint: fingerprint, children: [], membershipComplete: false,
                            ownBytes: fingerprint.bytes, complete: false)
            }
            let sameIdentity = previous.map { fingerprint.hasSameIdentity(as: $0.fingerprint) } ?? false
            let reuseMembership = sameIdentity && previous?.membershipComplete == true
                && previous.map { fingerprint.hasSameMembership(as: $0.fingerprint) } == true
                && !dirty.contains(path)
            let paths: [String]
            if reuseMembership, let previous {
                paths = previous.children.map(\.path)
            } else {
                enumerationCount += 1
                if enumeratedDirectories.count < 2048 { enumeratedDirectories.append(path) }
                do {
                    paths = try FileManager.default.contentsOfDirectory(atPath: path).sorted()
                        .map { path == "/" ? "/" + $0 : path + "/" + $0 }
                } catch {
                    if path == rootPath { rootUnreadable = true }
                    return Node(path: path, fingerprint: fingerprint, children: [], membershipComplete: false,
                                ownBytes: fingerprint.bytes, complete: false)
                }
            }
            let oldChildren = Dictionary(uniqueKeysWithValues: (previous?.children ?? []).map { ($0.path, $0) })
            var children: [Node] = []
            var complete = true
            for childPath in paths {
                if let child = try await scan(childPath, previous: oldChildren[childPath],
                                              force: force || !sameIdentity, depth: depth + 1) {
                    children.append(child)
                } else { complete = false }
            }
            return Node(path: path, fingerprint: fingerprint, children: children,
                        membershipComplete: complete, ownBytes: fingerprint.bytes, complete: complete)
        }

        private func checkCancellation() throws {
            if Task.isCancelled { throw ScanCancelled.cancelled }
        }
    }

    private static let version = 1
    private static let maximumRoots = 128
    private let cacheURL: URL
    private let inspectionObserver: (@Sendable (String) async -> Void)?
    private var loaded = false
    private var roots: [String: StoredRoot] = [:]
    private var stale = Set<String>()
    private var needsCalibration = Set<String>()
    private var dirtyPaths: [String: Set<String>] = [:]
    private var revisions: [String: UInt64] = [:]
    private var inFlight: [String: Int] = [:]
    private var accessedAt: [String: Date] = [:]
    private var lastDiagnostics = DirectorySizeCacheDiagnostics(inspectedCount: 0, enumerationCount: 0,
                                                                inspectedPaths: [], enumeratedDirectories: [])

    init(cacheURL: URL? = nil, inspectionObserver: (@Sendable (String) async -> Void)? = nil) {
        self.cacheURL = Self.storageURL(cacheURL: cacheURL)
        self.inspectionObserver = inspectionObserver
    }

    /// Keep the state file in its own directory. Watchers can ignore this
    /// directory, including atomic-write temporary files and folder events.
    nonisolated static func storageURL(cacheURL: URL? = nil) -> URL {
        cacheURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nori/DirectorySizes/state.json")
    }

    func records(for urls: [URL]) -> [String: DirectorySizeRecord] {
        loadIfNeeded()
        var records: [String: DirectorySizeRecord] = [:]
        for url in urls where url.isFileURL {
            let path = Self.normalizedPath(url)
            if let stored = roots[path], let visible = visibleRecord(stored) {
                records[path] = visible
                accessedAt[path] = Date()
            }
        }
        return records
    }

    func observedDirectories() -> [URL] {
        loadIfNeeded()
        return roots.keys.sorted().map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    func diagnostics() -> DirectorySizeCacheDiagnostics { lastDiagnostics }

    func refresh(_ url: URL, mode: DirectorySizeRefreshMode = .incremental) async -> DirectorySizeRecord? {
        loadIfNeeded()
        guard url.isFileURL else { return nil }
        let path = Self.normalizedPath(url)
        let previous = roots[path]
        guard !Task.isCancelled else { return previous.flatMap(visibleRecord) }
        accessedAt[path] = Date()
        let actualMode: DirectorySizeRefreshMode = needsCalibration.contains(path) ? .calibration : mode
        if actualMode == .incremental, let previous, previous.node != nil, dirtyPaths[path]?.isEmpty != false {
            lastDiagnostics = DirectorySizeCacheDiagnostics(inspectedCount: 0, enumerationCount: 0,
                                                            inspectedPaths: [], enumeratedDirectories: [])
            return record(previous)
        }
        let ticket = (revisions[path] ?? 0) &+ 1
        revisions[path] = ticket
        inFlight[path, default: 0] += 1
        defer {
            let remaining = (inFlight[path] ?? 1) - 1
            if remaining == 0 { inFlight.removeValue(forKey: path) }
            else { inFlight[path] = remaining }
        }
        let scanner = Scanner(rootPath: path, mode: actualMode, dirty: dirtyPaths[path] ?? [], observer: inspectionObserver)
        do {
            let node = try await scanner.scan(path, previous: previous?.node, force: previous?.node == nil)
            lastDiagnostics = DirectorySizeCacheDiagnostics(inspectedCount: scanner.inspectedCount,
                                                            enumerationCount: scanner.enumerationCount,
                                                            inspectedPaths: scanner.inspectedPaths,
                                                            enumeratedDirectories: scanner.enumeratedDirectories)
            guard !Task.isCancelled, revisions[path] == ticket else { return roots[path].flatMap(visibleRecord) }
            if scanner.rootUnreadable {
                stale.insert(path)
                needsCalibration.insert(path)
                if previous?.node == nil {
                    // Observe unreadable first-use roots so watcher/timer
                    // retries can recover later, without presenting zero as
                    // a measured size. The placeholder is never visible.
                    roots[path] = StoredRoot(path: path, node: nil, bytes: 0,
                                            isComplete: false, updatedAt: Date())
                    evictIfNeeded()
                    persist()
                }
                return roots[path].flatMap(visibleRecord)
            }
            if scanner.rootMissing {
                roots.removeValue(forKey: path)
                stale.remove(path)
                needsCalibration.remove(path)
                dirtyPaths.removeValue(forKey: path)
                accessedAt.removeValue(forKey: path)
                persist()
                return nil
            }
            let result = node?.result ?? DirectorySizeResult(bytes: 0, isComplete: false)
            let stored = StoredRoot(path: path, node: node, bytes: result.bytes,
                                    isComplete: result.isComplete, updatedAt: Date())
            roots[path] = stored
            stale.remove(path)
            needsCalibration.remove(path)
            dirtyPaths.removeValue(forKey: path)
            evictIfNeeded()
            persist()
            return record(stored)
        } catch {
            lastDiagnostics = DirectorySizeCacheDiagnostics(inspectedCount: scanner.inspectedCount,
                                                            enumerationCount: scanner.enumerationCount,
                                                            inspectedPaths: scanner.inspectedPaths,
                                                            enumeratedDirectories: scanner.enumeratedDirectories)
            // Cancelled work never changes the last successful snapshot.
            return roots[path].flatMap(visibleRecord)
        }
    }

    func invalidate(paths: [URL]) {
        loadIfNeeded()
        let storage = (Self.normalizedPath(cacheURL) as NSString).deletingLastPathComponent
        let changes = paths.filter(\.isFileURL).map { Self.normalizedPath($0) }
            .filter { !Self.contains(storage, $0) }
        for root in Set(roots.keys).union(inFlight.keys) {
            for changed in changes {
                if Self.contains(root, changed) {
                    dirtyPaths[root, default: []].insert(changed)
                    let parent = (changed as NSString).deletingLastPathComponent
                    if Self.contains(root, parent) { dirtyPaths[root, default: []].insert(parent) }
                } else if Self.contains(changed, root) {
                    dirtyPaths[root, default: []].insert(root)
                } else { continue }
                stale.insert(root)
                revisions[root] = (revisions[root] ?? 0) &+ 1
            }
        }
    }

    func dueDirectories(now: Date = Date(), interval: TimeInterval = 6 * 3600) -> [URL] {
        loadIfNeeded()
        return roots.values.filter { stale.contains($0.path) || now.timeIntervalSince($0.updatedAt) >= max(0, interval) }
            .sorted { $0.updatedAt == $1.updatedAt ? $0.path < $1.path : $0.updatedAt < $1.updatedAt }
            .map { URL(fileURLWithPath: $0.path, isDirectory: true) }
    }

    private func record(_ stored: StoredRoot) -> DirectorySizeRecord {
        DirectorySizeRecord(result: DirectorySizeResult(bytes: stored.bytes, isComplete: stored.isComplete),
                            updatedAt: stored.updatedAt, isStale: stale.contains(stored.path))
    }

    private func visibleRecord(_ stored: StoredRoot) -> DirectorySizeRecord? {
        guard stored.node != nil else { return nil }
        return record(stored)
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: cacheURL),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.version == Self.version, envelope.roots.count <= Self.maximumRoots,
              Set(envelope.roots.map(\.path)).count == envelope.roots.count,
              envelope.roots.allSatisfy({ Self.valid($0) }) else { return }
        roots = Dictionary(uniqueKeysWithValues: envelope.roots.map { ($0.path, $0) })
        stale = Set(roots.keys)
        needsCalibration = stale
    }

    private static func valid(_ root: StoredRoot) -> Bool {
        guard root.path.hasPrefix("/"), normalizedPath(URL(fileURLWithPath: root.path, isDirectory: false)) == root.path,
              root.bytes >= 0 else { return false }
        func validNode(_ node: Node, expectedPath: String, depth: Int) -> Bool {
            guard depth <= 512, node.path == expectedPath, node.fingerprint.bytes >= 0,
                  node.normalBytes >= 0, node.hardlinks.values.allSatisfy({ $0.bytes >= 0 }),
                  Set(node.children.map(\.path)).count == node.children.count else { return false }
            return node.children.allSatisfy { child in
                (child.path as NSString).deletingLastPathComponent == node.path
                    && validNode(child, expectedPath: child.path, depth: depth + 1)
            }
        }
        return root.node.map { validNode($0, expectedPath: root.path, depth: 0) } ?? !root.isComplete
    }

    private func evictIfNeeded() {
        while roots.count > Self.maximumRoots {
            guard let oldest = roots.keys.min(by: { (accessedAt[$0] ?? roots[$0]!.updatedAt)
                < (accessedAt[$1] ?? roots[$1]!.updatedAt) }) else { break }
            roots.removeValue(forKey: oldest)
            stale.remove(oldest)
            needsCalibration.remove(oldest)
            dirtyPaths.removeValue(forKey: oldest)
            accessedAt.removeValue(forKey: oldest)
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(Envelope(version: Self.version,
            roots: roots.values.sorted { $0.path < $1.path })) else { return }
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: cacheURL, options: .atomic)
        } catch { /* Cache I/O must not interrupt file browsing. */ }
    }

    private static func contains(_ root: String, _ path: String) -> Bool {
        path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }

    /// Foundation standardization may rewrite /private paths differently when
    /// an item disappears. Lexical normalization keeps observed/cache IDs
    /// stable and performs no filesystem metadata reads.
    private static func normalizedPath(_ url: URL) -> String {
        var components: [Substring] = []
        for component in url.path.split(separator: "/") {
            if component == "." { continue }
            if component == ".." { if !components.isEmpty { components.removeLast() } }
            else { components.append(component) }
        }
        return "/" + components.joined(separator: "/")
    }
}
