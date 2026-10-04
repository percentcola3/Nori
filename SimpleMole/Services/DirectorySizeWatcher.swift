import Foundation
import CoreServices
import Darwin

/// Watches only directories already observed by the directory-size cache. FSEvents
/// supplies invalidation hints; callers reconcile the actual filesystem separately.
@MainActor
final class DirectorySizeWatcher {
    private var stream: FSEventStreamRef?
    private var mappings: [DirectorySizeWatchRoot] = []
    private var inputRootSignature: [String]?
    private var requiresRestart = false
    private var generation: UInt64 = 0
    private var eventCursor = FSEventsGetCurrentEventId()
    private let queue = DispatchQueue(label: "nori.directory-size-events", qos: .utility)
    private let onChange: @MainActor ([URL]) -> Void
    private let onRescan: @MainActor () -> Void

    init(onChange: @escaping @MainActor ([URL]) -> Void,
         onRescan: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        self.onRescan = onRescan
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    func watch(_ urls: [URL]) {
        let normalized = Set(urls.filter(\.isFileURL).map(\.standardizedFileURL)).sorted { $0.path < $1.path }
        let signature = normalized.map(\.path)
        // Per-size-request subscriptions usually contain precisely the same roots.
        // Avoid lstat/realpath on MainActor until their input topology changes.
        guard inputRootSignature != signature || requiresRestart else { return }
        let newMappings = DirectorySizeWatchRoot.make(normalized)
        inputRootSignature = signature
        guard requiresRestart || newMappings != mappings else { return }
        stop()
        inputRootSignature = signature
        mappings = newMappings
        guard !newMappings.isEmpty else { return }
        let currentGeneration = generation
        let owner = DirectorySizeEventContext(owner: self, generation: currentGeneration, roots: newMappings)
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(owner).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<DirectorySizeEventContext>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<DirectorySizeEventContext>.fromOpaque(info).release()
            }, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes)
        let paths = DirectorySizeWatchRoot.compactPhysicalPaths(newMappings) as CFArray
        guard let created = FSEventStreamCreate(kCFAllocatorDefault, { _, info, count, rawPaths, eventFlags, eventIDs in
            guard let info else { return }
            let context = Unmanaged<DirectorySizeEventContext>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(rawPaths).takeUnretainedValue() as! [String]
            context.receive(paths: paths, flags: eventFlags, eventIDs: eventIDs, count: count)
        }, &context, paths, eventCursor, 1.0, flags) else {
            requestRescan(generation: currentGeneration)
            return
        }
        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            stream = nil
            requestRescan(generation: currentGeneration)
            return
        }
    }

    func stop() {
        generation &+= 1
        mappings = []
        inputRootSignature = nil
        requiresRestart = false
        guard let existing = stream else { return }
        stream = nil
        FSEventStreamStop(existing)
        FSEventStreamInvalidate(existing)
        FSEventStreamRelease(existing)
    }

    fileprivate func deliver(paths: [URL], rescan: Bool, generation: UInt64,
                             eventID: FSEventStreamEventId, eventIDsWrapped: Bool,
                             reevaluateRoots: Bool = true) {
        guard self.generation == generation, !mappings.isEmpty else { return }
        if rescan {
            if reevaluateRoots {
                inputRootSignature = nil
                requiresRestart = true
            }
            onRescan()
        }
        else if !paths.isEmpty { onChange(paths) }
        // Cursor advancement follows delivery, so an invalidated generation's
        // queued callback is replayed by the replacement stream. HistoryDone
        // is intentionally handled without a filesystem invalidation callback.
        eventCursor = eventIDsWrapped ? eventID : max(eventCursor, eventID)
    }

    private func requestRescan(generation: UInt64) {
        // Preserve mappings after a failed start: repeatedly calling watch with the
        // same set must not create a rescan/retry loop. stop() permits an explicit retry.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.deliver(paths: [], rescan: true, generation: generation,
                         eventID: self.eventCursor, eventIDsWrapped: false,
                         reevaluateRoots: false)
        }
    }
}

private struct DirectorySizeWatchRoot: Equatable, Sendable {
    let lexicalPath: String
    let physicalPath: String

    static func make(_ urls: [URL]) -> [DirectorySizeWatchRoot] {
        var roots: [DirectorySizeWatchRoot] = []
        for url in Set(urls.filter(\.isFileURL).map(\.standardizedFileURL)).sorted(by: { $0.path < $1.path }) {
            var status = stat()
            let physicalPath = url.withUnsafeFileSystemRepresentation { path -> String? in
                guard let path, lstat(path, &status) == 0,
                      (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
                      let physical = realpath(path, nil) else { return nil }
                defer { free(physical) }
                return String(cString: physical)
            }
            guard let physicalPath else { continue }
            roots.append(DirectorySizeWatchRoot(lexicalPath: url.path, physicalPath: physicalPath))
        }
        return roots
    }

    static func compactPhysicalPaths(_ roots: [DirectorySizeWatchRoot]) -> [String] {
        var paths: [String] = []
        for path in Set(roots.map(\.physicalPath)).sorted(by: {
            $0.count == $1.count ? $0 < $1 : $0.count < $1.count
        }) {
            if !paths.contains(where: { contains(root: $0, path: path) }) { paths.append(path) }
        }
        return paths
    }

    func translate(_ path: String) -> URL? {
        guard Self.contains(root: physicalPath, path: path) else { return nil }
        let suffix = String(path.dropFirst(physicalPath == "/" ? 0 : physicalPath.count))
        let lexical = lexicalPath == "/" ? (suffix.isEmpty ? "/" : suffix) : lexicalPath + suffix
        return URL(fileURLWithPath: lexical).standardizedFileURL
    }

    private static func contains(root: String, path: String) -> Bool {
        path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }
}

/// The framework retains this context from stream creation through final stream
/// disposal. It holds only a weak owner, and transfers owned path values to MainActor.
private final class DirectorySizeEventContext: @unchecked Sendable {
    private weak var owner: DirectorySizeWatcher?
    private let generation: UInt64
    private let roots: [DirectorySizeWatchRoot]
    private static let rescanFlags = FSEventStreamEventFlags(
        kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
        | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped
        | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount)

    init(owner: DirectorySizeWatcher, generation: UInt64, roots: [DirectorySizeWatchRoot]) {
        self.owner = owner
        self.generation = generation
        self.roots = roots
    }

    func receive(paths: [String], flags: UnsafePointer<FSEventStreamEventFlags>,
                 eventIDs: UnsafePointer<FSEventStreamEventId>, count: Int) {
        var rescan = false
        var affected = Set<URL>()
        var maximumEventID: FSEventStreamEventId = 0
        var lastEventID: FSEventStreamEventId = 0
        var eventIDsWrapped = false
        for position in 0..<min(count, paths.count) {
            let flag = flags[position]
            maximumEventID = max(maximumEventID, eventIDs[position])
            if eventIDs[position] != 0 { lastEventID = eventIDs[position] }
            if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped) != 0 { eventIDsWrapped = true }
            if flag & Self.rescanFlags != 0 { rescan = true; continue }
            if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0 { continue }
            for root in roots {
                if let url = root.translate(paths[position]) { affected.insert(url) }
            }
        }
        let urls = affected.sorted { $0.path < $1.path }
        let generation = generation
        // A counter wrap invalidates numerical max ordering; the final nonzero
        // event ID is the correct new journal position after that calibration.
        let eventID = eventIDsWrapped ? lastEventID : maximumEventID
        Task { @MainActor [weak owner] in
            owner?.deliver(paths: urls, rescan: rescan, generation: generation,
                           eventID: eventID, eventIDsWrapped: eventIDsWrapped)
        }
    }
}
