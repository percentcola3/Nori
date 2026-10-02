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

    static func main() async throws {
        let manager = FileManager.default
        let home = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
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
        let firstPass = AdministratorCleanupPlan.execute([retryRecord], homeDirectory: home.path,
            core: transitioningCore, onProgress: { _, _, path in observedPaths.append(path) })
        try expect(observedPaths.contains(firstLeaf.path), "Nested administrator files were hidden behind their root")
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
