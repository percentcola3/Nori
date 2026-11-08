import Darwin
import Foundation

@main
struct CleanupRemovalMemoryTests {
    enum Failure: Error { case assertion(String) }
    static let fm = FileManager.default
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure.assertion(message) }
    }
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info.phys_footprint : 0
    }
    final class LifetimeCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var live = 0, peak = 0, created = 0
        private var peakFootprint: UInt64 = 0
        func didCreate() {
            lock.lock()
            live += 1; created += 1; peak = max(peak, live)
            let sample = created % 128 == 0
            lock.unlock()
            if sample {
                let bytes = CleanupRemovalMemoryTests.footprint()
                lock.lock(); peakFootprint = max(peakFootprint, bytes); lock.unlock()
            }
        }
        func didDestroy() { lock.lock(); live -= 1; lock.unlock() }
        func snapshot() -> (live: Int, peak: Int, created: Int, footprint: UInt64) {
            lock.lock(); defer { lock.unlock() }
            return (live, peak, created, peakFootprint)
        }
    }
    final class AutoreleasedBuffer: NSObject {
        let bytes = Data(repeating: 0x53, count: 4096) as NSData
        let counter: LifetimeCounter
        init(_ counter: LifetimeCounter) { self.counter = counter; super.init(); counter.didCreate() }
        deinit {
            counter.didDestroy()
            // Pool draining can clobber errno. Production must preserve a failed
            // unlink/policy result rather than report this unrelated error.
            errno = E2BIG
        }
    }
    static func item(_ path: URL) -> DeletionPlan.Item {
        .init(record: path.path, identity: DeletionPlan.identity(at: path.path) ?? "",
              metadata: DeletionPlan.Metadata.read(path.path))
    }
    static func write(_ path: URL, data: Data = Data(repeating: 0x53, count: 256)) throws {
        try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: path)
    }
    static func remove(_ name: String, core: NativeCore, items: [DeletionPlan.Item], home: URL,
                       live: Set<String> = []) throws -> NativeCore.ApplySummary {
        let counter = LifetimeCounter()
        let before = footprint()
        let result = core.applyCleanup(items: items, permanent: true, homeDirectory: home.path,
            verifiedTargets: Set(items.map(\.record)), liveCleanupTargets: live,
            onCurrentFile: { _ in
                let object = AutoreleasedBuffer(counter)
                precondition(object.bytes.length == 4096 && object.bytes.bytes.load(as: UInt8.self) == 0x53)
                _ = Unmanaged.passRetained(object).autorelease()
            })
        let after = counter.snapshot()
        try expect(after.live == 0, "Removal returned with autoreleased objects still live: " + name)
        try expect(after.peak < 64, "Temporary object lifetime grew with entry count: " + name)
        print("Removal pools \(name): callbacks=\(after.created) peakLive=\(after.peak) beforeMiB=\(before / 1048576) peakSampleMiB=\(after.footprint / 1048576) afterMiB=\(footprint() / 1048576)")
        return result
    }
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw Failure.assertion("workspace fixture base required") }
        let base = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).resolvingSymlinksInPath()
        let fixture = base.appendingPathComponent(".cleanup-removal-memory-fixture." + UUID().uuidString)
        try expect(fixture.path.hasPrefix(base.path + "/.cleanup-removal-memory-fixture.") && mkdir(fixture.path, 0o700) == 0,
                   "Cannot create exclusive nonce fixture")
        var owned = stat()
        try expect(lstat(fixture.path, &owned) == 0, "Cannot bind owned nonce directory")
        defer {
            var current = stat()
            if lstat(fixture.path, &current) == 0, current.st_dev == owned.st_dev, current.st_ino == owned.st_ino,
               fixture.path.hasPrefix(base.path + "/.cleanup-removal-memory-fixture.") {
                try? fm.removeItem(at: fixture)
            }
        }
        let home = fixture.appendingPathComponent("home")
        let whole = home.appendingPathComponent(".Trash/whole")
        let outside = fixture.appendingPathComponent("outside/keep.cache")
        try autoreleasepool {
            try write(outside)
            for index in 0..<4096 {
                try write(whole.appendingPathComponent("branch-\(index % 8)/nested/item-\(index).cache"))
            }
            try fm.createSymbolicLink(at: whole.appendingPathComponent("outside-link"), withDestinationURL: outside)
        }
        let core = NativeCore(cleanupOpenFileProbe: { [] })
        let wholeResult = try remove("recursive-discarded", core: core, items: [item(whole)], home: home)
        try expect(wholeResult.failed == 0 && wholeResult.removed == 1 && !fm.fileExists(atPath: whole.path),
                   "Recursive secure removal changed behavior")
        try expect(fm.fileExists(atPath: outside.path), "Recursive removal followed an external link")

        let live = home.appendingPathComponent("Library/Caches/com.example.poolfixture")
        let whitelist = home.appendingPathComponent(".config/mole/whitelist")
        let keep = live.appendingPathComponent("keep.cache")
        let database = live.appendingPathComponent("database-payload.cache")
        try autoreleasepool {
            for index in 0..<4096 { try write(live.appendingPathComponent("branch-\(index % 8)/item-\(index).cache")) }
            try write(keep)
            var databaseBytes = Data(repeating: 0x53, count: 256)
            databaseBytes.replaceSubrange(0..<16, with: Data("SQLite format 3\0".utf8))
            try write(database, data: databaseBytes)
            try write(live.appendingPathComponent("SingletonLock"))
            try write(whitelist, data: Data((keep.path + "\n").utf8))
        }
        let liveResult = try remove("live-cache", core: core, items: [item(live)], home: home, live: [live.path])
        try expect(liveResult.failed == 0 && liveResult.removed >= 4096 && fm.fileExists(atPath: live.path),
                   "Live cache no longer retained its root or reclaimed its unused leaves")
        try expect(fm.fileExists(atPath: keep.path) && fm.fileExists(atPath: database.path)
            && fm.fileExists(atPath: live.appendingPathComponent("SingletonLock").path),
                   "Pooling weakened whitelist, SQLite or lock protection")

        let roots: [URL] = try autoreleasepool {
            try (0..<512).map { index in
                let path = home.appendingPathComponent(".Trash/root-\(index).cache")
                try write(path)
                return path
            }
        }
        let rootResult = try remove("many-roots", core: core, items: roots.map(item), home: home)
        try expect(rootResult.failed == 0 && rootResult.removed == roots.count, "Per-root pooling changed results")
        let blocked = home.appendingPathComponent(".Trash/blocked")
        try write(blocked.appendingPathComponent("SingletonLock"))
        let blockedResult = try remove("errno-failure", core: core, items: [item(blocked)], home: home)
        try expect(blockedResult.failed == 1 && fm.fileExists(atPath: blocked.appendingPathComponent("SingletonLock").path)
            && blockedResult.messages.contains { $0.contains(String(cString: strerror(EBUSY))) },
                   "Pool draining changed errno or removed protected lock content")
        let changed = home.appendingPathComponent(".Trash/changed.cache")
        try write(changed)
        let stale = item(changed)
        try Data(repeating: 0x54, count: 256).write(to: changed, options: .atomic)
        let staleResult = try remove("stale-identity", core: core, items: [stale], home: home)
        try expect(staleResult.removed == 0 && fm.fileExists(atPath: changed.path), "Pooling bypassed fresh identity validation")
        print("PASS removal memory: per-root/entry drainage, recursive accounting, link isolation, live guards, errno and changed identity")
    }
}
