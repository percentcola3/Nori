import Darwin
import Foundation

@main
struct DirectorySizeCacheTests {
    private final class CancelBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<DirectorySizeRecord?, Never>?
        private var requested = false
        func install(_ task: Task<DirectorySizeRecord?, Never>) {
            lock.lock()
            self.task = task
            let requested = requested
            lock.unlock()
            if requested { task.cancel() }
        }
        func cancel() {
            lock.lock()
            requested = true
            let task = task
            lock.unlock()
            task?.cancel()
        }
    }

    private final class InFlightBox: @unchecked Sendable {
        private let lock = NSLock()
        private var cache: DirectorySizeCache?
        private var fired = false
        func install(_ cache: DirectorySizeCache) {
            lock.lock()
            self.cache = cache
            lock.unlock()
        }
        func takeOnce() -> DirectorySizeCache? {
            lock.lock()
            defer { lock.unlock() }
            guard !fired else { return nil }
            fired = true
            return cache
        }
    }

    static func expect(_ condition: Bool, _ message: String) {
        guard condition else {
            FileHandle.standardError.write(Data(("FAIL: \(message)\n").utf8))
            exit(1)
        }
    }

    static func write(_ url: URL, bytes: Int) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            expect(FileManager.default.createFile(atPath: url.path, contents: nil), "test file creates")
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(repeating: 9, count: bytes))
        try handle.close()
    }

    static func refresh(_ cache: DirectorySizeCache, _ url: URL,
                        mode: DirectorySizeRefreshMode = .incremental) async -> DirectorySizeRecord {
        guard let result = await cache.refresh(url, mode: mode) else {
            expect(false, "expected a size record for \(url.path)")
            fatalError()
        }
        return result
    }

    static func main() async throws {
        let manager = FileManager.default
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let measured = fixture.appendingPathComponent("measured", isDirectory: true)
        let cacheURL = fixture.appendingPathComponent("cache/state.json")
        let left = measured.appendingPathComponent("left", isDirectory: true)
        let right = measured.appendingPathComponent("right", isDirectory: true)
        try manager.createDirectory(at: left, withIntermediateDirectories: true)
        try manager.createDirectory(at: right, withIntermediateDirectories: true)
        let first = left.appendingPathComponent("first")
        let hidden = left.appendingPathComponent(".hidden")
        let second = right.appendingPathComponent("second")
        try write(first, bytes: 8192)
        try write(hidden, bytes: 16384)
        try write(second, bytes: 32768)
        let hardlink = right.appendingPathComponent("hardlink")
        try manager.linkItem(at: first, to: hardlink)
        let loop = measured.appendingPathComponent("loop")
        try manager.createSymbolicLink(atPath: loop.path, withDestinationPath: measured.path)
        let broken = measured.appendingPathComponent("broken")
        try manager.createSymbolicLink(atPath: broken.path, withDestinationPath: "missing")

        let cache = DirectorySizeCache(cacheURL: cacheURL)
        expect(await cache.records(for: [measured]).isEmpty, "unobserved roots have no fake zero record")
        let initial = await refresh(cache, measured)
        expect(initial.result == DirectoryFileService.allocatedSize(of: measured), "full snapshot matches physical blocks, hidden entries, hardlink dedup and symlink safety")
        expect(initial.result.isComplete && !initial.isStale, "successful initial measurement is fresh and complete")
        expect(manager.fileExists(atPath: cacheURL.path), "snapshot persists atomically to the configured storage")
        let persistedText = String(decoding: try Data(contentsOf: cacheURL), as: UTF8.self)
        expect(!persistedText.contains(first.path) && !persistedText.contains(second.path),
               "persistence stores per-root totals only, never per-file membership")
        let observed = await cache.observedDirectories().map(\.path)
        expect(observed == [measured.path], "observed roots are exposed for watcher setup: \(observed) versus \(measured.path)")
        let untouched = await refresh(cache, measured)
        let untouchedStats = await cache.diagnostics()
        expect(untouched == initial && untouchedStats.inspectedCount == 0, "unchanged incremental refresh performs no metadata reads")

        try write(first, bytes: 131072)
        await cache.invalidate(paths: [first])
        expect((await cache.records(for: [measured]))[measured.path]?.isStale == true, "invalidation immediately marks the visible cached record stale")
        let edited = await refresh(cache, measured)
        let editedStats = await cache.diagnostics()
        expect(edited.result == DirectoryFileService.allocatedSize(of: measured), "incremental hardlink edits update the shared inode's occupied blocks once")
        expect(!editedStats.inspectedPaths.contains(right.path) && !editedStats.inspectedPaths.contains(second.path)
            && !editedStats.inspectedPaths.contains(hardlink.path), "an unaffected subtree is reused without lstat")
        expect(!editedStats.inspectedPaths.contains(hidden.path), "unchanged siblings need no metadata reads when membership is enumerated")

        let added = left.appendingPathComponent("added")
        try write(added, bytes: 24576)
        await cache.invalidate(paths: [added])
        expect((await refresh(cache, measured)).result == DirectoryFileService.allocatedSize(of: measured), "added files enter cached membership")
        try manager.removeItem(at: hidden)
        await cache.invalidate(paths: [hidden])
        expect((await refresh(cache, measured)).result == DirectoryFileService.allocatedSize(of: measured), "deleted files leave cached membership")
        let renamed = right.appendingPathComponent("renamed")
        try manager.moveItem(at: added, to: renamed)
        await cache.invalidate(paths: [added, renamed])
        expect((await refresh(cache, measured)).result == DirectoryFileService.allocatedSize(of: measured), "cross-folder renames update old and new memberships")

        var before = stat()
        expect(lstat(second.path, &before) == 0, "in-place fixture captures exact metadata")
        try write(second, bytes: 196608)
        var times = [before.st_atimespec, before.st_mtimespec]
        expect(times.withUnsafeMutableBufferPointer { utimensat(AT_FDCWD, second.path, $0.baseAddress, 0) } == 0,
               "fixture restores the original mtime so ctime remains the change signal")
        let beforeCalibration = await refresh(cache, measured)
        expect(beforeCalibration.result != DirectoryFileService.allocatedSize(of: measured), "unannounced in-place writes wait for calibration")
        let calibrated = await refresh(cache, measured, mode: .calibration)
        let calibrationStats = await cache.diagnostics()
        expect(calibrated.result == DirectoryFileService.allocatedSize(of: measured), "calibration detects nested in-place writes even when mtime is restored")
        expect(calibrationStats.enumerationCount == 0 && calibrationStats.inspectedPaths.contains(second.path), "calibration reuses unchanged membership while checking nested fingerprints")

        let offline = right.appendingPathComponent(".offline-change")
        try write(offline, bytes: 65536)
        let restarted = DirectorySizeCache(cacheURL: cacheURL)
        let saved = await restarted.records(for: [measured])
        expect(saved[measured.path]?.result == calibrated.result && saved[measured.path]?.isStale == true,
               "restart returns persisted sizes immediately and marks them stale")
        expect((await restarted.diagnostics()).inspectedCount == 0, "loading a persisted record performs no lstat")
        expect(await restarted.dueDirectories().map(\.path).contains(measured.path), "persisted stale roots are due for calibration")
        let online = await refresh(restarted, measured)
        expect(online.result == DirectoryFileService.allocatedSize(of: measured) && !online.isStale,
               "the first incremental use after restart calibrates offline additions")
        expect((await restarted.diagnostics()).inspectedPaths.contains(first.path), "first restart refresh calibrates nested existing files too")
        expect(await restarted.dueDirectories(now: online.updatedAt.addingTimeInterval(3600)).isEmpty,
               "fresh roots are not periodically recalibrated too soon")
        expect(await restarted.dueDirectories(now: online.updatedAt.addingTimeInterval(7 * 3600)).map(\.path).contains(measured.path),
               "old roots become due for periodic calibration")
        await restarted.invalidate(paths: [cacheURL, cacheURL.deletingLastPathComponent()])
        expect((await restarted.records(for: [measured]))[measured.path]?.isStale == false, "owned cache writes cannot invalidate the cache itself")
        let selfObserved = fixture.appendingPathComponent("self-observed")
        try manager.createDirectory(at: selfObserved, withIntermediateDirectories: false)
        let selfState = selfObserved.appendingPathComponent("DirectorySizes/state.json")
        let selfCache = DirectorySizeCache(cacheURL: selfState)
        let selfRecord = await refresh(selfCache, selfObserved)
        await selfCache.invalidate(paths: [selfState, selfState.deletingLastPathComponent(),
            selfState.deletingLastPathComponent().appendingPathComponent("atomic-write-temp")])
        let afterSelfWrite = (await selfCache.records(for: [selfObserved]))[selfObserved.path]!
        expect(afterSelfWrite == selfRecord, "storage-subtree events are ignored even when its parent is an observed root")
        _ = await refresh(selfCache, selfObserved)
        expect((await selfCache.diagnostics()).inspectedCount == 0, "owned persistence events cannot trigger a perpetual refresh loop")

        // Replace an entire directory at the same path: old membership cannot
        // survive an inode replacement, even when descendant names match.
        let removedLeft = fixture.appendingPathComponent("removed-left")
        try manager.moveItem(at: left, to: removedLeft)
        try manager.createDirectory(at: left, withIntermediateDirectories: false)
        try write(left.appendingPathComponent("replacement"), bytes: 4096)
        await restarted.invalidate(paths: [left])
        expect((await refresh(restarted, measured)).result == DirectoryFileService.allocatedSize(of: measured), "identity replacement discards the old directory's children")

        let unreadable = measured.appendingPathComponent("unreadable")
        try manager.createDirectory(at: unreadable, withIntermediateDirectories: false)
        try write(unreadable.appendingPathComponent("secret"), bytes: 8192)
        try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        await restarted.invalidate(paths: [unreadable])
        let partial = await refresh(restarted, measured)
        if !manager.isReadableFile(atPath: unreadable.path) {
            expect(!partial.result.isComplete, "permission boundaries are stored as an incomplete lower bound")
        }
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: unreadable.path)
        expect((await refresh(restarted, measured, mode: .calibration)).result == DirectoryFileService.allocatedSize(of: measured), "calibration repairs a previously unreadable subtree")
        let beforeRootFailure = (await restarted.records(for: [measured]))[measured.path]!
        try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: measured.path)
        let rootIsUnreadable = !manager.isReadableFile(atPath: measured.path)
        let afterRootFailure = await restarted.refresh(measured, mode: .calibration)
        if rootIsUnreadable {
            expect(afterRootFailure?.result == beforeRootFailure.result && afterRootFailure?.updatedAt == beforeRootFailure.updatedAt
                && afterRootFailure?.isStale == true, "an unreadable root preserves its previous size and honest timestamp, marked stale")
        }
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: measured.path)
        _ = await refresh(restarted, measured, mode: .calibration)

        let cancelBox = CancelBox()
        let cancelCacheURL = fixture.appendingPathComponent("cancel-cache/state.json")
        let cancelCache = DirectorySizeCache(cacheURL: cancelCacheURL, inspectionObserver: { path in
            if path == second.path { cancelBox.cancel() }
        })
        // Seed from a separate cache so the observer only runs for cancellation.
        try manager.createDirectory(at: cancelCacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.copyItem(at: cacheURL, to: cancelCacheURL)
        let oldCancelRecord = (await cancelCache.records(for: [measured]))[measured.path]!
        let oldData = try Data(contentsOf: cancelCacheURL)
        let cancelledTask = Task { await cancelCache.refresh(measured, mode: .calibration) }
        cancelBox.install(cancelledTask)
        _ = await cancelledTask.value
        let keptRecord = (await cancelCache.records(for: [measured]))[measured.path]!
        let keptData = try Data(contentsOf: cancelCacheURL)
        expect(keptRecord == oldCancelRecord && keptData == oldData,
               "mid-refresh cancellation preserves the previous record and persisted snapshot")
        expect((await cancelCache.diagnostics()).inspectedPaths.contains(second.path), "cancellation is exercised after traversal starts")

        let inFlightBox = InFlightBox()
        let duringScan = left.appendingPathComponent("during-first-scan")
        let inFlightCache = DirectorySizeCache(cacheURL: fixture.appendingPathComponent("inflight-cache/state.json"),
            inspectionObserver: { path in
                if path == right.path, let cache = inFlightBox.takeOnce() {
                    try? write(duringScan, bytes: 45056)
                    await cache.invalidate(paths: [duringScan])
                }
            })
        inFlightBox.install(inFlightCache)
        expect(await inFlightCache.refresh(measured) == nil, "changes during a first in-flight scan invalidate its revision before any root is stored")
        expect(await inFlightCache.records(for: [measured]).isEmpty, "invalidated first scans cannot publish a falsely fresh snapshot")
        expect((await refresh(inFlightCache, measured)).result == DirectoryFileService.allocatedSize(of: measured), "the retried first scan includes changes to an already traversed branch")

        let deletedRoot = fixture.appendingPathComponent("deleted-root")
        try manager.createDirectory(at: deletedRoot, withIntermediateDirectories: false)
        _ = await refresh(restarted, deletedRoot)
        try manager.removeItem(at: deletedRoot)
        await restarted.invalidate(paths: [deletedRoot])
        expect(await restarted.refresh(deletedRoot) == nil, "deleted observed roots are removed when absence is confirmed")
        expect((await restarted.records(for: [deletedRoot])).isEmpty, "deleted roots leave no stale size row")

        let firstUnreadable = fixture.appendingPathComponent("first-unreadable")
        try manager.createDirectory(at: firstUnreadable, withIntermediateDirectories: false)
        try write(firstUnreadable.appendingPathComponent("restored-later"), bytes: 4096)
        try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: firstUnreadable.path)
        if !manager.isReadableFile(atPath: firstUnreadable.path) {
            expect(await restarted.refresh(firstUnreadable) == nil, "an unreadable first-use root presents no fake zero size")
            expect((await restarted.records(for: [firstUnreadable])).isEmpty, "unreadable placeholders are hidden from visible records")
            expect(await restarted.observedDirectories().map(\.path).contains(firstUnreadable.path), "an unreadable first-use root remains observed for watcher recovery")
            expect(await restarted.dueDirectories().map(\.path).contains(firstUnreadable.path), "unreadable placeholders remain due for capped periodic retries")
            let placeholderRestart = DirectorySizeCache(cacheURL: cacheURL)
            expect((await placeholderRestart.records(for: [firstUnreadable])).isEmpty,
                   "persisted unreadable placeholders remain invisible after restart")
            expect(await placeholderRestart.observedDirectories().map(\.path).contains(firstUnreadable.path),
                   "persisted unreadable placeholders retain watcher observation")
        }
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: firstUnreadable.path)
        expect((await refresh(restarted, firstUnreadable)).result == DirectoryFileService.allocatedSize(of: firstUnreadable),
               "an observed unreadable first-use root recovers once permissions are restored")

        let malformedURL = fixture.appendingPathComponent("malformed-cache/state.json")
        try manager.createDirectory(at: malformedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not valid json".utf8).write(to: malformedURL)
        expect(await DirectorySizeCache(cacheURL: malformedURL).observedDirectories().isEmpty, "malformed persistence is ignored")
        try Data("{\"version\":999,\"roots\":[]}".utf8).write(to: malformedURL)
        expect(await DirectorySizeCache(cacheURL: malformedURL).observedDirectories().isEmpty, "incompatible persistence versions are ignored")
        expect(!manager.fileExists(atPath: malformedURL.path), "incompatible persistence is removed rather than kept on disk")
        // 旧版逐文件快照：超过上限直接删除，不读入内存。
        manager.createFile(atPath: malformedURL.path, contents: nil)
        let legacy = try FileHandle(forWritingTo: malformedURL)
        try legacy.truncate(atOffset: 8 << 20)
        try legacy.close()
        expect(await DirectorySizeCache(cacheURL: malformedURL).observedDirectories().isEmpty
               && !manager.fileExists(atPath: malformedURL.path), "oversized legacy snapshots are discarded without decoding")

        let bounded = DirectorySizeCache(cacheURL: fixture.appendingPathComponent("bounded-cache/state.json"))
        for index in 0..<130 {
            let root = fixture.appendingPathComponent("bounded-\(index)")
            try manager.createDirectory(at: root, withIntermediateDirectories: false)
            _ = await bounded.refresh(root)
        }
        expect(await bounded.observedDirectories().count == 128, "observed roots have a bounded persistence footprint")

        // reset()：内存清单与持久化封套一起消失，之后的 persist 只能写出
        // 新观测到的根，旧根不会复活（清理管道删除自有缓存的前提）。
        let resetCacheURL = fixture.appendingPathComponent("reset-cache/state.json")
        let resetCache = DirectorySizeCache(cacheURL: resetCacheURL)
        _ = await refresh(resetCache, measured)
        _ = await refresh(resetCache, left)
        expect(manager.fileExists(atPath: resetCacheURL.path), "reset fixture cache persisted")
        await resetCache.reset()
        expect(!manager.fileExists(atPath: resetCacheURL.path), "reset removes the persisted envelope")
        expect(await resetCache.records(for: [measured, left]).isEmpty,
               "reset drops every in-memory record")
        expect(await resetCache.observedDirectories().isEmpty,
               "reset drops watcher observation of stale roots")
        _ = await refresh(resetCache, right)
        expect(manager.fileExists(atPath: resetCacheURL.path),
               "a later refresh persists again after reset")
        let resurrected = DirectorySizeCache(cacheURL: resetCacheURL)
        expect(await resurrected.records(for: [measured, left]).isEmpty,
               "persisting after reset resurrects deleted roots")
        expect(await resurrected.observedDirectories().map(\.path) == [right.path],
               "only the freshly observed root survives across a restart")
        print("Directory size cache tests passed")
    }
}
