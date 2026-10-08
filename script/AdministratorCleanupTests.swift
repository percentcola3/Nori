import Darwin
import Foundation

// Administrator UI is replaced in fixtures; these tests never elevate.
final class MoleEngine {
    static let shared = MoleEngine()
    var response = RunResult(output: "", exitCode: 1, timedOut: false)
    var inspectRequest: ((String, [String]) throws -> Void)?
    var manifestPath: String?
    var invocationCount = 0
    var responseDelay: UInt64 = 0

    func runPrivilegedBridge(_ path: String, arguments: [String],
                             timeout: TimeInterval) async -> RunResult {
        invocationCount += 1
        manifestPath = arguments.last
        do { try inspectRequest?(path, arguments) }
        catch { fatalError("Invalid administrator request: \(error)") }
        if responseDelay > 0 { try? await Task.sleep(nanoseconds: responseDelay) }
        return response
    }
}

@main
struct AdministratorCleanupTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: message, code: 1) }
    }

    static func testLiteralPathCoverage() throws {
        let literals = ["", "/", "/cache", "/cache/", "/cache//", "/cache-other", "relative", "relative/",
                        "/缓存", "/café", "/cafe\u{301}", "/cache/\u{301}"]
        let paths = ["", "/", "//", "/cache", "/cache/", "/cache//", "/cache///leaf", "/cache/leaf",
                     "/cache-other", "/cache-other/leaf", "/cache/../leaf", "/cache/./leaf", "relative", "relative/leaf",
                     "relative//leaf", "/缓存/文件", "/café/leaf", "/cafe\u{301}/leaf", "/cache/\u{301}entry", "/cache//\u{301}entry"]
        let rootSets: [Set<String>] = literals.map { Set([$0]) } + [Set(literals), []]
        for roots in rootSets {
            for path in paths {
                let original = roots.contains { path == $0 || path.hasPrefix($0 + "/") }
                try expect(DeletionPlan.isPathCovered(path, by: roots) == original,
                           "Literal path index broadened authorization for \(path)")
            }
        }
        try expect(!DeletionPlan.isPathCovered("/cache/\u{301}entry", by: ["/cache"]),
                   "A combining mark on the separator widened String.hasPrefix coverage")
    }

    static func testProgress(at file: URL) throws {
        let descriptor = open(file.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o600)
        try expect(descriptor >= 0, "Cannot create owned progress fixture")
        defer { close(descriptor) }
        var writes: [AdministratorCleanupPlan.Progress] = []
        var tick: TimeInterval = 0
        var activeWriters = 0
        var invalidWrite = false
        var concurrentWrite = false
        let sink = AdministratorCleanupPlan.ProgressSink(clock: {
            tick += 0.121
            return tick
        }, write: { data in
            activeWriters += 1
            concurrentWrite = concurrentWrite || activeWriters != 1
            defer { activeWriters -= 1 }
            guard AdministratorCleanupPlan.writeProgress(data, to: descriptor),
                  let persisted = try? Data(contentsOf: file),
                  let progress = try? JSONDecoder().decode(AdministratorCleanupPlan.Progress.self, from: persisted) else {
                invalidWrite = true
                return false
            }
            writes.append(progress)
            return true
        })
        var callbacks = 0
        let relay = AdministratorCleanupPlan.ProgressRelay { completed, total, path in
            callbacks += 1
            sink.submit(.init(completed: completed, total: total, path: path))
        }
        let roots = 256
        relay.report(completed: 0, total: roots, path: "")
        DispatchQueue.concurrentPerform(iterations: roots) { index in
            relay.report(completed: index + 1, total: roots, path: "root-\(index)")
            relay.currentFile("root-\(index)/child.cache")
        }
        relay.finish()
        sink.finish()
        try expect(!concurrentWrite && !invalidWrite && callbacks == roots * 2 + 2
                   && writes.count == callbacks + 1,
                   "Concurrent progress callbacks overlapped or corrupted the shared JSON descriptor")
        try expect(zip(writes, writes.dropFirst()).allSatisfy { $0.completed <= $1.completed }
                   && writes.allSatisfy { $0.total == roots }
                   && writes.last?.completed == roots,
                   "Concurrent cleanup progress moved backwards or lost its final completion")

        var now: TimeInterval = 0
        var throttled: [AdministratorCleanupPlan.Progress] = []
        let timed = AdministratorCleanupPlan.ProgressSink(clock: { now }, write: { data in
            guard let progress = try? JSONDecoder().decode(AdministratorCleanupPlan.Progress.self, from: data) else { return false }
            throttled.append(progress)
            return true
        })
        timed.submit(.init(completed: 0, total: 100, path: "first"))
        now = 0.119
        timed.submit(.init(completed: 1, total: 100, path: "withheld"))
        try expect(throttled.count == 1, "Progress writes exceeded the 120ms limit")
        now = 0.120
        timed.submit(.init(completed: 2, total: 100, path: "second"))
        try expect(throttled.count == 2, "Progress was not emitted at the 120ms boundary")
        now = 0.121
        for index in 0..<100 {
            timed.submit(.init(completed: 100, total: 100, path: "final-child-\(index)"))
        }
        try expect(throttled.count == 2, "Current-file notifications bypassed throttling at 100 percent")
        timed.finish()
        try expect(throttled.count == 3 && throttled.last?.completed == 100
                   && throttled.last?.path == "final-child-99",
                   "A final completion was lost inside the throttle window")
        timed.finish()
        timed.submit(.init(completed: 1, total: 100, path: "stale"))
        try expect(throttled.count == 3, "Late callbacks replaced completed progress")
    }

    static func testConfirmationPlanning(in home: URL) throws {
        let manager = FileManager.default
        let directory = home.appendingPathComponent("Library/Caches/confirmation", isDirectory: true)
        let leaf = directory.appendingPathComponent("payload.cache")
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("permission preview".utf8).write(to: leaf)
        func category(_ url: URL) -> CleanupCategory {
            CleanupCategory(name: "Preview", paths: [url.path], bytes: 4096,
                selected: true, source: .core, risk: .safe,
                disposal: .permanentDelete, applyRoute: .genericTrash)
        }
        let root = category(directory)
        let ordinary = AdministratorCleanupPlan.confirmationItems([root],
            administratorRequiredPaths: [], homeDirectory: home.path)
        try expect(ordinary.isEmpty, "Writable ordinary cleanup unexpectedly requested elevation")
        let preview = AdministratorCleanupPlan.confirmationItems([root, root],
            administratorRequiredPaths: [directory.path], homeDirectory: home.path)
        try expect(preview.count == 1 && preview[0].identity == root.pathIdentities[directory.path]
                   && preview[0].metadata == DeletionPlan.Metadata.read(directory.path),
                   "Scanner permission evidence was lost, duplicated, or detached from live metadata")
        var unselected = root
        unselected.selected = false
        var protected = root
        protected.risk = .protected
        var command = root
        command.applyRoute = .toolCommand
        var changed = root
        changed.pathIdentities[directory.path] = "0:0:0"
        try expect(AdministratorCleanupPlan.confirmationItems([unselected, protected, command, changed],
            administratorRequiredPaths: [directory.path], homeDirectory: home.path).isEmpty,
            "Unselected, protected, tool-command or changed paths entered administrator consent")

        // A permission change on a selected root is noticed without walking
        // its tree. Scanner hints remain responsible for descendant ACLs.
        let selectedLeaf = category(leaf)
        try expect(chmod(directory.path, 0o555) == 0, "Cannot prepare changed permission fixture")
        defer { _ = chmod(directory.path, 0o755) }
        let permissionChange = AdministratorCleanupPlan.confirmationItems([selectedLeaf],
            administratorRequiredPaths: [], homeDirectory: home.path)
        try expect(permissionChange.map(\.record) == [leaf.path]
                   && manager.fileExists(atPath: leaf.path),
                   "New root deletion permissions were missed or the preview deleted content")
    }

    static func main() async throws {
        let manager = FileManager.default
        let home = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        try testLiteralPathCoverage()
        try testProgress(at: home.appendingPathComponent("worker-progress-fixture.json"))
        try testConfirmationPlanning(in: home)
        let caches = home.appendingPathComponent("Library/Caches/test-admin", isDirectory: true)
        try manager.createDirectory(at: caches, withIntermediateDirectories: true)
        let file = caches.appendingPathComponent("generated.cache")
        func write(_ url: URL) throws {
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0x61, count: 4096).write(to: url)
        }
        func record(_ url: URL) -> AdministratorCleanupPlan.Record {
            .init(path: url.path, identity: DeletionPlan.identity(at: url.path) ?? "")
        }
        func allocatedBytes(_ url: URL) -> UInt64 {
            var metadata = stat()
            precondition(lstat(url.path, &metadata) == 0)
            return UInt64(metadata.st_blocks) * 512
        }
        let core = NativeCore(cleanupOpenFileProbe: { [] })

        try write(file)
        let expectedBytes = allocatedBytes(file)
        let garbageRecord = record(file)
        var observedPaths: [String] = []
        let cleaned = AdministratorCleanupPlan.execute([garbageRecord], homeDirectory: home.path, core: core,
            onProgress: { _, _, path in if !path.isEmpty { observedPaths.append(path) } })
        try expect(observedPaths.contains(file.path), "Administrator cleanup did not report its actual file")
        try expect(cleaned.removed == 1 && cleaned.skipped == 0 && cleaned.failed == 0,
                   "Administrator worker did not clean confirmed garbage")
        try expect(!manager.fileExists(atPath: file.path), "Confirmed garbage remains")
        try expect(cleaned.reclaimedBytes == expectedBytes,
                   "Administrator worker lost confirmed reclaimed bytes")

        let document = home.appendingPathComponent("Documents/keep.txt")
        let model = caches.appendingPathComponent("models/weights.gguf")
        try write(document)
        try write(model)
        let refused = AdministratorCleanupPlan.execute([record(document), record(model)],
                                                       homeDirectory: home.path, core: core)
        try expect(refused.skipped == 2 && refused.removed == 0,
                   "Elevation allowed non-garbage or protected model data")
        try expect(manager.fileExists(atPath: document.path) && manager.fileExists(atPath: model.path),
                   "Protected content changed")
        var emptyProbeCount = 0
        let noCandidatesCore = NativeCore(cleanupOpenFileProbe: { emptyProbeCount += 1; return [] })
        var emptyProgress: [AdministratorCleanupPlan.Progress] = []
        let staleModel = AdministratorCleanupPlan.Record(path: model.path, identity: "0:0:0")
        let noCandidates = AdministratorCleanupPlan.execute([record(document), staleModel],
            homeDirectory: home.path, core: noCandidatesCore,
            onProgress: { emptyProgress.append(.init(completed: $0, total: $1, path: $2)) })
        try expect(emptyProbeCount == 0 && noCandidates.skipped == 2 && noCandidates.removed == 0
                   && Set(noCandidates.remainingPaths) == [document.path, model.path]
                   && emptyProgress.last?.completed == 0 && emptyProgress.last?.total == 0,
                   "An empty administrator plan made an unnecessary occupancy probe or lost refusals")

        let occupied = caches.appendingPathComponent("open.cache")
        try write(occupied)
        let busyCore = NativeCore(cleanupOpenFileProbe: { [occupied.path] })
        let busy = AdministratorCleanupPlan.execute([record(occupied)], homeDirectory: home.path, core: busyCore)
        try expect(busy.removed == 0 && busy.skipped == 1 && manager.fileExists(atPath: occupied.path),
                   "Elevation bypassed open-file protection")
        let unknown = AdministratorCleanupPlan.execute([record(occupied)], homeDirectory: home.path,
                                                       core: NativeCore(cleanupOpenFileProbe: { nil }))
        try expect(unknown.removed == 0 && unknown.skipped == 1, "Unknown occupancy did not fail closed")

        try write(file)
        let stale = AdministratorCleanupPlan.Record(path: file.path, identity: "0:0:0")
        let changed = AdministratorCleanupPlan.execute([stale], homeDirectory: home.path, core: core)
        try expect(changed.removed == 0 && changed.skipped == 1 && manager.fileExists(atPath: file.path),
                   "Elevation bypassed planned identity")

        // Administrator authentication must retain the complete reviewed
        // metadata, including changes that keep the coarse mtime second.
        let metadataBound = caches.appendingPathComponent("metadata-bound.cache")
        try write(metadataBound)
        let fullRecord = AdministratorCleanupPlan.Record(path: metadataBound.path,
            identity: DeletionPlan.identity(at: metadataBound.path)!, metadata: DeletionPlan.Metadata.read(metadataBound.path))
        let modified = fullRecord.metadata!.modifiedSeconds
        try Data(repeating: 0x62, count: 8192).write(to: metadataBound)
        var preservedSecond = [timeval(tv_sec: Int(modified), tv_usec: 0), timeval(tv_sec: Int(modified), tv_usec: 0)]
        try expect(utimes(metadataBound.path, &preservedSecond) == 0, "cannot restore coarse timestamp")
        let metadataChanged = AdministratorCleanupPlan.execute([fullRecord], homeDirectory: home.path, core: core)
        try expect(metadataChanged.removed == 0 && metadataChanged.skipped == 1
            && manager.fileExists(atPath: metadataBound.path), "administrator lost full metadata across authentication")

        // A protected child appearing after preview changes the plan. Refuse
        // the original directory rather than silently broadening root deletion.
        let rootRecord = record(caches)
        let mixed = AdministratorCleanupPlan.execute([rootRecord], homeDirectory: home.path, core: core)
        try expect(mixed.removed == 0 && mixed.skipped == 1 && manager.fileExists(atPath: file.path),
                   "Administrator worker replaced the reviewed plan with a partial plan")

        let retryCache = home.appendingPathComponent("Library/Caches/admin-retry", isDirectory: true)
        let firstLeaf = retryCache.appendingPathComponent("first.cache")
        let busyLeaf = retryCache.appendingPathComponent("busy.cache")
        try write(firstLeaf)
        try write(busyLeaf)
        let retryRecord = record(retryCache)
        let firstBytes = allocatedBytes(firstLeaf)
        let busyBytes = allocatedBytes(busyLeaf)
        // The file becomes occupied between fresh preflight and deletion.
        var probeCount = 0
        let transitioningCore = NativeCore(cleanupOpenFileProbe: {
            probeCount += 1
            return probeCount == 1 ? [] : [busyLeaf.path]
        })
        observedPaths = []
        var preflightProgress: [AdministratorCleanupPlan.Progress] = []
        let firstPass = AdministratorCleanupPlan.execute([retryRecord], homeDirectory: home.path,
            core: transitioningCore, onProgress: { completed, total, path in
                observedPaths.append(path)
                if probeCount == 1 { preflightProgress.append(.init(completed: completed, total: total, path: path)) }
            })
        try expect(observedPaths.contains(firstLeaf.path), "Nested administrator files were hidden behind their root")
        try expect(preflightProgress.contains { $0.path == firstLeaf.path && $0.completed == 0 && $0.total == 1 },
                   "Administrator preflight did not report its actual nested file before deletion")
        try expect(firstPass.removed == 1 && firstPass.skipped > 0
                   && !manager.fileExists(atPath: firstLeaf.path)
                   && manager.fileExists(atPath: busyLeaf.path)
                   && firstPass.reclaimedBytes == firstBytes,
                   "Partial administrator cleanup lost deleted leaves or space")
        // Force a distinct mtime without waiting for a one-second stat tick.
        try manager.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 10)],
                                  ofItemAtPath: retryCache.path)
        let retry = AdministratorCleanupPlan.execute([retryRecord], homeDirectory: home.path, core: core)
        try expect(retry.removed > 0 && retry.skipped == 0 && retry.failed == 0
                   && !manager.fileExists(atPath: busyLeaf.path) && retry.reclaimedBytes == busyBytes,
                   "Partial administrator retry refused the same cache object after its content changed")

        try write(firstLeaf)
        let replacementRecord = record(retryCache)
        let renamedCache = retryCache.appendingPathExtension("original")
        try manager.moveItem(at: retryCache, to: renamedCache)
        try write(busyLeaf)
        let replaced = AdministratorCleanupPlan.execute([replacementRecord], homeDirectory: home.path,
                                                        core: core)
        try expect(replaced.removed == 0 && replaced.skipped == 1
                   && manager.fileExists(atPath: busyLeaf.path),
                   "Relaxed cache mtime checks accepted a replaced directory")

        let engine = MoleEngine.shared
        engine.inspectRequest = { path, arguments in
            try expect(path == "bin/app_cleanup_admin.sh" && arguments.count == 2,
                       "Unexpected administrator bridge")
            try expect(arguments[0] == String(getuid()), "Wrong target account")
            let manifest = arguments[1]
            let attributes = try manager.attributesOfItem(atPath: manifest)
            try expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
                       "Administrator manifest is not private")
            let request = try JSONDecoder().decode(AdministratorCleanupPlan.Request.self,
                                                   from: Data(contentsOf: URL(fileURLWithPath: manifest)))
            try expect(request.records.count == 1 && request.records[0].path == file.path,
                       "Administrator request changed selected files")
        }
        engine.response = RunResult(output: "User canceled authorization.", exitCode: 1, timedOut: false)
        let beforeCancellation = engine.invocationCount
        let cancelled = await AdministratorCleanupService.apply(items: [.init(record: file.path,
                                                                              identity: record(file).identity)])
        try expect(engine.invocationCount == beforeCancellation + 1, "Canceled elevation retried automatically")
        try expect(cancelled.failed == 1 && cancelled.executionFailed && cancelled.removed == 0,
                   "Cancelled authorization was reported successful")
        try expect(engine.manifestPath.map { !manager.fileExists(atPath: $0) } == true,
                   "Administrator manifest was retained")
        let summary = NativeCore.ApplySummary(removed: 1, skipped: 0, failed: 0,
                                             messages: [], removedPaths: [file.path], reclaimedBytes: 8192)
        let report = try JSONEncoder().encode(AdministratorCleanupPlan.Report(summary))
        engine.response = RunResult(output: AdministratorCleanupPlan.reportPrefix
                                    + String(decoding: report, as: UTF8.self), exitCode: 0, timedOut: false)
        let success = await AdministratorCleanupService.apply(items: [.init(record: file.path,
                                                                            identity: record(file).identity)])
        try expect(success.completedSuccessfully && success.removedPaths == [file.path]
                   && success.reclaimedBytes == 8192,
                   "Administrator result lost confirmed deletions")
        let partial = NativeCore.ApplySummary(removed: 1, skipped: 1, failed: 0,
                                             messages: ["Occupied cache retained."], removedPaths: [file.path],
                                             reclaimedBytes: 4096)
        let partialReport = try JSONEncoder().encode(AdministratorCleanupPlan.Report(partial))
        engine.response = RunResult(output: AdministratorCleanupPlan.reportPrefix
                                    + String(decoding: partialReport, as: UTF8.self), exitCode: 0, timedOut: false)
        let partialResult = await AdministratorCleanupService.apply(items: [
            .init(record: file.path, identity: record(file).identity)])
        try expect(partialResult.removed == 1 && partialResult.skipped == 1 && partialResult.failed == 0
                   && partialResult.removedPaths == [file.path] && partialResult.reclaimedBytes == 4096
                   && !partialResult.completedSuccessfully,
                   "Partial administrator cleanup lost confirmed deletions")
        for malformed in [
            NativeCore.ApplySummary(removed: 0, skipped: 0, failed: 0, messages: []),
            NativeCore.ApplySummary(removed: 1, skipped: 0, failed: 0,
                                    messages: [], removedPaths: [document.path])
        ] {
            let invalidReport = try JSONEncoder().encode(AdministratorCleanupPlan.Report(malformed))
            engine.response = RunResult(output: AdministratorCleanupPlan.reportPrefix
                                        + String(decoding: invalidReport, as: UTF8.self), exitCode: 0, timedOut: false)
            let invalid = await AdministratorCleanupService.apply(items: [
                .init(record: file.path, identity: record(file).identity)])
            try expect(invalid.failed == 1 && invalid.executionFailed && invalid.removed == 0,
                       "Malformed administrator report was accepted")
        }
        engine.inspectRequest = { _, arguments in
            let request = try JSONDecoder().decode(AdministratorCleanupPlan.Request.self,
                from: Data(contentsOf: URL(fileURLWithPath: arguments[1])))
            try expect(request.records.map(\.path) == [file.path, firstLeaf.path],
                       "Combined administrator request lost selected paths")
            let progressURL = URL(fileURLWithPath: arguments[1] + ".progress")
            try JSONEncoder().encode(AdministratorCleanupPlan.Progress(
                completed: 0, total: 2, path: firstLeaf.path)).write(to: progressURL)
            let progressAttributes = try manager.attributesOfItem(atPath: progressURL.path)
            try expect((progressAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
                       "Administrator progress file is not private")
        }
        engine.response = RunResult(output: "User canceled authorization.", exitCode: 1, timedOut: false)
        engine.responseDelay = 250_000_000
        var publishedPath = ""
        let beforeBatch = engine.invocationCount
        let batch = await AdministratorCleanupService.apply(items: [
            .init(record: file.path, identity: "fixture"), .init(record: firstLeaf.path, identity: "fixture")],
            onProgress: { _, _, path in publishedPath = path })
        try expect(publishedPath == firstLeaf.path, "Privileged progress did not reach its caller")
        try expect(engine.invocationCount == beforeBatch + 1 && batch.failed == 2,
                   "Combined administrator cleanup made repeated elevation requests")
        if getuid() != 0 {
            try expect(AdministratorCleanupPlan.runWorker(arguments: [String(getuid()), "/tmp/unused"]) == 64,
                       "Headless worker accepted an unprivileged process")
        }
        print("Administrator cleanup tests passed")
    }
}
