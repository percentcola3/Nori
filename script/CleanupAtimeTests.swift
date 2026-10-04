import AppKit
import Darwin
import Foundation

/// Uses real pread/readdir and the production lsof probe. Every mutable path
/// lives in the exclusively created /private/tmp fixture supplied by the script.
@main struct CleanupAtimeTests {
    static let fm = FileManager.default
    enum Failure: Error { case assertion(String) }
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure.assertion(message) }
    }
    static func write(_ url: URL, database: Bool = false) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data(repeating: 0x53, count: 8192)
        if database { data.replaceSubrange(0..<16, with: Data("SQLite format 3\0".utf8)) }
        try data.write(to: url)
    }
    static func metadata(_ url: URL) throws -> stat {
        var value = stat()
        try expect(lstat(url.path, &value) == 0, "missing fixture: " + url.path)
        return value
    }
    static func age(_ root: URL) throws {
        let paths = [root] + (fm.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
        // macOS coalesces accesses when atime >= mtime. Older atime ensures
        // this fixture exercises an actual kernel timestamp update on read.
        let now = Int(Date().timeIntervalSince1970)
        for path in paths.reversed() {
            var times = [timeval(tv_sec: now - 10 * 86400, tv_usec: 0),
                         timeval(tv_sec: now - 9 * 86400, tv_usec: 0)]
            try expect(utimes(path.path, &times) == 0, "cannot age exclusively created fixture")
        }
    }
    static func category(_ path: String) -> CleanupCategory {
        CleanupCategory(name: "Atime fixture", paths: [path], bytes: 1,
            selected: true, source: .core, risk: .safe, disposal: .permanentDelete,
            applyRoute: .genericTrash, activityGuard: .openFile,
            reasonKey: "cleanup.risk.rebuildableCache")
    }
    static func item(_ path: String) -> DeletionPlan.Item {
        .init(record: path, identity: DeletionPlan.identity(at: path) ?? "",
              metadata: DeletionPlan.Metadata.read(path))
    }
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw Failure.assertion("fixture required") }
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        try expect(fixture.path.hasPrefix("/private/tmp/nori-cleanup-atime-fixture."), "unexpected fixture root")
        let home = fixture.appendingPathComponent("home")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)

        let root = fixture.appendingPathComponent("own-cache")
        let nested = root.appendingPathComponent("nested")
        let payload = nested.appendingPathComponent("payload.cache")
        try write(payload); try age(root)
        let beforeFile = try metadata(payload)
        let beforeDirectory = try metadata(nested)
        let core = NativeCore()
        let first = core.preflightCleanupCategories([category(root.path)], homeDirectory: home.path)
        let afterFile = try metadata(payload)
        let afterDirectory = try metadata(nested)
        try expect(first.succeeded && first.categories.flatMap(\.paths).contains(root.path),
                   "own scan did not offer the old cache")
        try expect(afterFile.st_atimespec.tv_sec > beforeFile.st_atimespec.tv_sec
            && afterFile.st_mtimespec.tv_sec == beforeFile.st_mtimespec.tv_sec
            && afterFile.st_ctimespec.tv_sec == beforeFile.st_ctimespec.tv_sec,
                   "real header probe failed to exercise atime-only mutation")
        try expect(afterDirectory.st_atimespec.tv_sec > beforeDirectory.st_atimespec.tv_sec,
                   "real readdir failed to exercise directory atime mutation")
        let repeated = core.preflightCleanupCategories([category(root.path)], homeDirectory: home.path)
        try expect(repeated.categories.flatMap(\.paths).contains(root.path),
                   "same-instance rescan discarded its original age evidence")
        let removed = core.applyCleanup(items: [item(root.path)], permanent: true, homeDirectory: home.path)
        try expect(removed.failed == 0 && !fm.fileExists(atPath: payload.path)
            && !fm.fileExists(atPath: nested.path) && fm.fileExists(atPath: root.path),
                   "own scan/header/readdir prevented safe cleanup: " + removed.messages.joined(separator: "; "))
        print("PASS atime: real scan → rescan → cleanup, header read and directory enumeration")

        let scalar = fixture.appendingPathComponent("own-scalar.cache")
        try write(scalar); try age(scalar)
        let scalarRemoved = core.applyCleanup(items: [item(scalar.path)], permanent: true, homeDirectory: home.path)
        try expect(scalarRemoved.removed == 1 && !fm.fileExists(atPath: scalar.path),
                   "scalar preflight/header probe blocked its secure deletion edge")

        let isolated = fixture.appendingPathComponent("separate-worker.cache")
        try write(isolated); try age(isolated)
        let scanned = core.preflightCleanupCategories([category(isolated.path)], homeDirectory: home.path)
        try expect(!scanned.categories.isEmpty, "separate-worker setup scan failed")
        let other = NativeCore().applyCleanup(items: [item(isolated.path)], permanent: true, homeDirectory: home.path)
        try expect(other.removed == 0 && fm.fileExists(atPath: isolated.path),
                   "a new worker accepted another instance's age proof")
        let otherAdmin = AdministratorCleanupPlan.execute([
            .init(path: isolated.path, identity: DeletionPlan.identity(at: isolated.path)!,
                  metadata: DeletionPlan.Metadata.read(isolated.path))
        ], homeDirectory: home.path, core: NativeCore())
        try expect(otherAdmin.removed == 0 && fm.fileExists(atPath: isolated.path),
                   "administrator request imported another instance's age proof")
        print("PASS atime: cross-instance and administrator request remain fail-closed")

        let external = fixture.appendingPathComponent("external-access.cache")
        try write(external); try age(external)
        _ = core.preflightCleanupCategories([category(external.path)], homeDirectory: home.path)
        let observed = try metadata(external)
        var accessed = timeval(); gettimeofday(&accessed, nil)
        var times = [accessed, timeval(tv_sec: observed.st_mtimespec.tv_sec,
                                      tv_usec: Int32(observed.st_mtimespec.tv_nsec / 1000))]
        try expect(utimes(external.path, &times) == 0, "cannot mark fixture's subsequent external access")
        let externallyAccessed = core.applyCleanup(items: [item(external.path)], permanent: true,
                                                   homeDirectory: home.path)
        try expect(externallyAccessed.removed == 0 && fm.fileExists(atPath: external.path),
                   "a later external access timestamp reused an old inspection")

        let changed = fixture.appendingPathComponent("externally-written.cache")
        try write(changed); try age(changed)
        _ = core.preflightCleanupCategories([category(changed.path)], homeDirectory: home.path)
        let reviewedChanged = try metadata(changed)
        try Data(repeating: 0x54, count: 8192).write(to: changed)
        var restored = [timeval(tv_sec: reviewedChanged.st_atimespec.tv_sec,
                                tv_usec: Int32(reviewedChanged.st_atimespec.tv_nsec / 1000)),
                        timeval(tv_sec: reviewedChanged.st_mtimespec.tv_sec,
                                tv_usec: Int32(reviewedChanged.st_mtimespec.tv_nsec / 1000))]
        try expect(utimes(changed.path, &restored) == 0, "cannot restore fixture modification time")
        let written = core.applyCleanup(items: [item(changed.path)], permanent: true, homeDirectory: home.path)
        try expect(written.removed == 0 && fm.fileExists(atPath: changed.path),
                   "same-size write/restore-mtime reused inspection evidence")

        let directoryRoot = fixture.appendingPathComponent("externally-changed-directory")
        let changedDirectory = directoryRoot.appendingPathComponent("empty-mtime")
        let changedPermissions = directoryRoot.appendingPathComponent("empty-ctime")
        let sibling = directoryRoot.appendingPathComponent("payload.cache")
        try write(sibling)
        try fm.createDirectory(at: changedDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: changedPermissions, withIntermediateDirectories: true)
        try age(directoryRoot)
        _ = core.preflightCleanupCategories([category(directoryRoot.path)], homeDirectory: home.path)
        let permissionSnapshot = try metadata(changedPermissions)
        let directoryResult = core.applyCleanup(items: [item(directoryRoot.path)], permanent: true,
            homeDirectory: home.path, onCurrentFile: { path in
                if path == changedDirectory.path {
                    try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: path)
                } else if path == changedPermissions.path {
                    _ = chmod(path, permissionSnapshot.st_mode ^ 0o100)
                    _ = chmod(path, permissionSnapshot.st_mode)
                }
            })
        try expect(!fm.fileExists(atPath: sibling.path)
            && fm.fileExists(atPath: changedDirectory.path)
            && fm.fileExists(atPath: changedPermissions.path)
            && directoryResult.skipped >= 2,
                   "directory proof fallback ignored external mtime/ctime changes")

        let busy = fixture.appendingPathComponent("busy.cache")
        try write(busy); try age(busy)
        _ = core.preflightCleanupCategories([category(busy.path)], homeDirectory: home.path)
        let fd = open(busy.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        try expect(fd >= 0, "cannot open real busy fixture")
        defer { close(fd) }
        var header = [UInt8](repeating: 0, count: 16)
        try expect(pread(fd, &header, 16, 0) == 16, "cannot perform real external header read")
        let occupied = core.applyCleanup(items: [item(busy.path)], permanent: true, homeDirectory: home.path)
        try expect(occupied.removed == 0 && fm.fileExists(atPath: busy.path),
                   "inspection evidence bypassed production lsof")

        let database = fixture.appendingPathComponent("unknown-database.cache")
        try write(database, database: true); try age(database)
        let dbScan = core.preflightCleanupCategories([category(database.path)], homeDirectory: home.path)
        let dbCleanup = core.applyCleanup(items: [item(database.path)], permanent: true, homeDirectory: home.path)
        try expect(dbScan.categories.isEmpty && dbCleanup.removed == 0 && fm.fileExists(atPath: database.path),
                   "inspection evidence bypassed real SQLite magic protection")
        print("PASS atime: subsequent timestamp/write, empty-directory mtime/ctime, actual open fd, SQLite protection")

        let worker = fixture.appendingPathComponent("worker-cache")
        let workerPayload = worker.appendingPathComponent("nested/payload.cache")
        try write(workerPayload); try age(worker)
        let workerBefore = try metadata(workerPayload)
        var observedOwnRead = false
        let workerResult = AdministratorCleanupPlan.execute([
            .init(path: worker.path, identity: DeletionPlan.identity(at: worker.path)!,
                  metadata: DeletionPlan.Metadata.read(worker.path))
        ], homeDirectory: home.path, core: NativeCore(), onProgress: { _, _, path in
            if path == workerPayload.path, let value = try? metadata(workerPayload) {
                observedOwnRead = value.st_atimespec.tv_sec > workerBefore.st_atimespec.tv_sec
            }
        })
        try expect(observedOwnRead && workerResult.failed == 0 && workerResult.removed > 0
            && !fm.fileExists(atPath: workerPayload.path),
                   "worker's own scan/header proof failed: " + workerResult.messages.joined(separator: "; "))
        print("PASS atime: administrator worker uses only its own real I/O evidence")
    }
}
