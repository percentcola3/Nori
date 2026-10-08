import Darwin
import Foundation

private final class WorkerCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private(set) var peak = 0
    func validate(_ path: String) -> Bool {
        lock.lock(); active += 1; peak = max(peak, active); lock.unlock()
        usleep(2_000)
        lock.lock(); active -= 1; lock.unlock()
        return true
    }
}

@main
struct AdministratorCleanupPerformanceTests {
    @MainActor
    static func main() async throws {
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        let stage = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "optimized"
        let fm = FileManager.default
        let home = fixture.appendingPathComponent("home")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        func write(_ url: URL, bytes: Int = 4096) throws {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0x61, count: bytes).write(to: url)
        }
        func item(_ path: String) -> DeletionPlan.Item {
            .init(record: path, identity: DeletionPlan.identity(at: path) ?? "unavailable")
        }
        func apply(_ items: [DeletionPlan.Item], open: Set<String>? = [],
                   finalValidation: ((String) -> Bool)? = nil) -> NativeCore.ApplySummary {
            NativeCore(cleanupOpenFileProbe: { open }).applyCleanup(items: items, permanent: true,
                homeDirectory: home.path, verifiedTargets: Set(items.map(\.record)), finalValidation: finalValidation)
        }

        // Exact/raw aliases count once each; duplicate identical records do not.
        let tree = home.appendingPathComponent("Library/Caches/index-fixture")
        let leaf = tree.appendingPathComponent("payload.cache")
        try write(leaf)
        let aliases = [tree.path, tree.path + "/", tree.path.replacingOccurrences(of: "/Caches/", with: "/Caches//"), leaf.path]
        let nested = apply((aliases + [tree.path]).map(item))
        precondition(nested.removed == aliases.count && nested.failed == 0 && nested.skipped == 0)
        precondition(nested.removedPaths == Set(aliases) && nested.remainingPaths.isEmpty && !fm.fileExists(atPath: tree.path))
        let composedTree = home.appendingPathComponent("Library/Caches/composed-fixture")
        let composedLeaf = composedTree.appendingPathComponent("\u{0301}entry.cache")
        try write(composedLeaf)
        precondition(!composedLeaf.path.hasPrefix(composedTree.path + "/"),
                     "This fixture must exercise Swift's composed slash boundary")
        let composed = apply([item(composedTree.path), item(composedLeaf.path)])
        precondition(composed.removed == 1 && composed.removedPaths == [composedTree.path]
                     && composed.remainingPaths == [composedLeaf.path] && !fm.fileExists(atPath: composedTree.path),
                     "Indexed accounting must preserve the original String.hasPrefix coverage semantics")
        let retained = home.appendingPathComponent("Library/Caches/retained.cache")
        let neighbor = home.appendingPathComponent("Library/Caches/retained.cache-neighbor")
        try write(retained); try write(neighbor)
        let occupied = apply([item(retained.path), item(neighbor.path)], open: [retained.path + "/child"])
        precondition(occupied.removed == 1 && occupied.skipped == 1 && fm.fileExists(atPath: retained.path)
                     && !fm.fileExists(atPath: neighbor.path), "Open descendants must not block same-prefix neighbors")
        let unavailable = apply([item(retained.path)], open: nil)
        precondition(unavailable.removed == 0 && unavailable.skipped == 1 && fm.fileExists(atPath: retained.path))
        let unsafe = retained.path + "/../unreviewed.cache"
        let invalid = apply([item(unsafe), item(unsafe), .init(record: "/", identity: "invalid-root")])
        precondition(invalid.removed == 0 && invalid.skipped == 2 && invalid.remainingPaths.count == 3)
        let separate = home.appendingPathComponent("Library/Caches/separate.cache")
        try write(separate)
        let slashRoot = apply([.init(record: "/", identity: "invalid-root"), item(separate.path)])
        precondition(slashRoot.removed == 1 && slashRoot.skipped == 1 && !fm.fileExists(atPath: separate.path),
                     "The literal slash root cannot swallow separately reviewed safe records")
        let changed = apply([.init(record: retained.path, identity: "0:0:0")])
        precondition(changed.removed == 0 && changed.skipped == 1 && fm.fileExists(atPath: retained.path))

        // Bundle metadata observers are excluded only for reversible app moves.
        let app = home.appendingPathComponent("Applications/IndexObserverFixture.app")
        let info = app.appendingPathComponent("Contents/Info.plist")
        let icon = app.appendingPathComponent("Contents/Resources/fixture.icns")
        try write(info); try write(icon)
        func record(_ path: String, process: String = "index-fixture", descriptor: String = "5",
                    access: String = "r", pid: Int32 = 10) -> NativeCore.OpenFileRecord {
            .init(pid: pid, process: process, descriptor: descriptor, access: access, path: path)
        }
        let observers = [record(info.path), record(icon.path), record(app.path, process: "UserEventAgent")]
        let bundleItem = item(app.path)
        let blocked = NativeCore(cleanupOpenFileRecordsProbe: { observers }).applyCleanup(items: [bundleItem],
            permanent: true, homeDirectory: home.path, allowApplicationBundle: true, verifiedTargets: [app.path])
        precondition(blocked.removed == 0 && blocked.skipped == 1 && fm.fileExists(atPath: app.path))
        let blockers = observers + [record(app.path + "/z-first", process: "firstSource", access: "w", pid: 21),
                                   record(app.path + "/a-second", process: "secondSource", access: "w", pid: 22)]
        let denied = NativeCore(cleanupOpenFileRecordsProbe: { blockers }).applyCleanup(items: [bundleItem],
            permanent: false, homeDirectory: home.path, allowApplicationBundle: true, verifiedTargets: [app.path])
        precondition(denied.skipped == 1 && denied.messages.contains("Open by firstSource (PID 21): " + app.path + "/z-first"),
                     "Blocker diagnostics preserve source order after observer exclusions")
        for observer in [record(info.path, access: ""), record(app.path, process: "UserEventAgent", descriptor: "cwd")] {
            let stopped = NativeCore(cleanupOpenFileRecordsProbe: { [observer] }).applyCleanup(items: [bundleItem],
                permanent: false, homeDirectory: home.path, allowApplicationBundle: true, verifiedTargets: [app.path])
            precondition(stopped.removed == 0 && stopped.skipped == 1)
        }
        let moved = fixture.appendingPathComponent("owned-trash/IndexObserverFixture.app")
        try fm.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        let observed = NativeCore(cleanupOpenFileRecordsProbe: { observers }).applyCleanup(items: [bundleItem],
            permanent: false, homeDirectory: home.path, allowApplicationBundle: true, verifiedTargets: [app.path],
            trashHandler: { try fm.moveItem(at: $0, to: moved) })
        precondition(observed.removed == 1 && !fm.fileExists(atPath: app.path) && fm.fileExists(atPath: moved.path))

        if stage != "baseline" {
            var validationItems: [DeletionPlan.Item] = []
            for index in 0..<24 {
                let file = home.appendingPathComponent("Library/Caches/workers/\(index).cache")
                try write(file); validationItems.append(item(file.path))
            }
            let counter = WorkerCounter()
            let workerCore = NativeCore(cleanupOpenFileProbe: { [] })
            let workerTargets = Set(validationItems.map(\.record))
            let workers = await Task.detached(priority: .utility) {
                workerCore.applyCleanup(items: validationItems, permanent: true, homeDirectory: home.path,
                    verifiedTargets: workerTargets, finalValidation: counter.validate)
            }.value
            precondition(workers.removed == validationItems.count && counter.peak <= 4,
                         "Root work must retain a bounded concurrency budget")
        }

        // Every timed fixture has identical roots, records and occupancy. Its
        // creation, allocation measurement and identity capture are untimed.
        for kind in ["records", "paths"] {
            let rootCount = 600
            var benchmarkItems: [DeletionPlan.Item] = []
            var expectedBytes: UInt64 = 0
            var roots: [String] = []
            for index in 0..<rootCount {
                let root = home.appendingPathComponent("Library/Caches/benchmark-\(kind)/root-\(index)")
                let file = root.appendingPathComponent("payload.cache")
                try write(file)
                var metadata = stat()
                precondition(lstat(file.path, &metadata) == 0)
                expectedBytes &+= UInt64(metadata.st_blocks) * 512
                roots.append(root.path)
                benchmarkItems += [item(root.path), item(file.path), item(root.path + "/"),
                    item(root.path.replacingOccurrences(of: "/Caches/", with: "/Caches//")), item(root.path)]
            }
            let openPaths = (0..<3600).map { home.path + "/Library/Caches/other-\($0)/busy.cache" }
            let records = openPaths.enumerated().map { record($0.element, pid: Int32($0.offset + 50)) }
            let core = kind == "records" ? NativeCore(cleanupOpenFileRecordsProbe: { records })
                : NativeCore(cleanupOpenFileProbe: { Set(openPaths) })
            var greatestHeartbeatDelay: Double = 0
            var pulses = 0
            let heartbeat = Task { @MainActor in
                var previous = DispatchTime.now().uptimeNanoseconds
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 5_000_000) } catch { break }
                    let now = DispatchTime.now().uptimeNanoseconds
                    greatestHeartbeatDelay = max(greatestHeartbeatDelay, Double(now - previous) / 1_000_000 - 5)
                    pulses += 1
                    previous = now
                }
            }
            try await Task.sleep(nanoseconds: 10_000_000)
            let started = DispatchTime.now().uptimeNanoseconds
            let summary = await Task.detached(priority: .utility) {
                core.applyCleanup(items: benchmarkItems, permanent: true, homeDirectory: home.path,
                                  verifiedTargets: Set(roots))
            }.value
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            heartbeat.cancel(); await heartbeat.value
            precondition(summary.removed == rootCount * 4 && summary.failed == 0 && summary.skipped == 0,
                         "Coverage accounting must retain raw aliases and descendants")
            precondition(summary.reclaimedBytes == expectedBytes && summary.remainingPaths.isEmpty)
            precondition(roots.allSatisfy { !fm.fileExists(atPath: $0) } && pulses > 0)
            print(String(format: "%@ %@ roots=%d records=%d open=%d elapsed_ms=%.2f heartbeat_max_delay_ms=%.2f bytes=%llu",
                stage, kind, rootCount, benchmarkItems.count, openPaths.count, elapsed, greatestHeartbeatDelay, expectedBytes))
        }
        print("Administrator cleanup performance and safety fixtures passed")
    }
}
