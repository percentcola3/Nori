import Darwin
import Foundation

/// Portable synthetic atime-only pairs bound to real, exclusively owned nonce
/// objects. Production never sets atime; the test factory is not in app builds.
enum CleanupInspectionTransferTests {
    enum Failure: Error { case assertion(String) }
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure.assertion(message) }
    }
    static func metadata(_ path: URL) throws -> stat {
        var value = stat()
        try expect(lstat(path.path, &value) == 0, "Missing owned nonce object")
        return value
    }
    static func category(_ root: URL) -> CleanupCategory {
        CleanupCategory(name: "Transfer fixture", paths: [root.path], bytes: 8192, selected: true,
            source: .core, risk: .safe, disposal: .permanentDelete, applyRoute: .genericTrash,
            activityGuard: .openFile, retention: 7 * 86400, reasonKey: "cleanup.risk.rebuildableCache")
    }
    static func run() throws {
        let fm = FileManager.default
        let fixtureBase = CommandLine.arguments.dropFirst().first ?? fm.currentDirectoryPath
        let base = URL(fileURLWithPath: fixtureBase, isDirectory: true).resolvingSymlinksInPath()
        let fixture = base.appendingPathComponent(".cleanup-inspection-transfer-fixture." + UUID().uuidString)
        try expect(fixture.path.hasPrefix(base.path + "/.cleanup-inspection-transfer-fixture.")
            && mkdir(fixture.path, 0o700) == 0, "Cannot create exclusive nonce fixture")
        let ownedIdentity = try metadata(fixture)
        defer {
            if let current = try? metadata(fixture), current.st_dev == ownedIdentity.st_dev,
               current.st_ino == ownedIdentity.st_ino,
               fixture.path.hasPrefix(base.path + "/.cleanup-inspection-transfer-fixture.") {
                try? fm.removeItem(at: fixture)
            }
        }
        let home = fixture.appendingPathComponent("home")
        let cache = home.appendingPathComponent(".npm/_cacache")
        let payload = cache.appendingPathComponent("payload.cache")
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data(repeating: 0x53, count: 8192).write(to: payload)
        let old = Int(Date().timeIntervalSince1970)
        // Keep actual atime recent; synthesize only the read's old atime. This
        // exercises the handoff on every filesystem, including coalescing ones.
        for path in [payload, cache] {
            var times = [timeval(tv_sec: old, tv_usec: 0),
                         timeval(tv_sec: old - 9 * 86400, tv_usec: 0)]
            try expect(utimes(path.path, &times) == 0, "Cannot set exclusively owned fixture timestamps")
            let actual = try metadata(path)
            try expect(actual.st_atimespec.tv_sec == old && actual.st_mtimespec.tv_sec == old - 9 * 86400,
                       "Synthetic fixture must have recent atime and old mtime")
        }
        let source = category(cache)
        let unseeded = NativeCore(cleanupOpenFileProbe: { [] })
        let recent = unseeded.preflightCleanupCategories([source], homeDirectory: home.path)
        try expect(!recent.categories.contains(where: \.selected), "Recent real atime unexpectedly passed age gate")
        func observation(_ path: URL, first: UInt64? = nil, expires: UInt64? = nil,
                         originalMutation: (inout stat) -> Void = { _ in },
                         observedMutation: (inout stat) -> Void = { _ in }) throws -> NativeCore.CleanupInspectionObservation {
            var observed = try metadata(path)
            var original = observed
            original.st_atimespec = timespec(tv_sec: old - 10 * 86400, tv_nsec: 0)
            originalMutation(&original); observedMutation(&observed)
            return NativeCore.cleanupInspectionObservationForTesting(path: path.path, original: original, observed: observed,
                firstObservedContinuousTicks: first, expiresAtContinuousTicks: expires)
        }
        let pair = try [observation(cache), observation(payload)]
        let encoded = try JSONEncoder().encode(pair)
        let decoded = try JSONDecoder().decode([NativeCore.CleanupInspectionObservation].self, from: encoded)
        try expect(pair == decoded, "Typed metadata roundtrip lost fields")
        let seeded = NativeCore(cleanupOpenFileProbe: { [] })
        try expect(seeded.importTrustedCleanupInspectionObservations(decoded, homeDirectory: home.path) == 2,
                   "Valid temporary observations rejected")
        let reviewed = seeded.preflightCleanupCategories([source], homeDirectory: home.path)
        try expect(reviewed.categories.contains(where: \.selected), "Original old age was lost after trusted import")
        let transferred = seeded.exportCleanupInspectionObservations(homeDirectory: home.path)
        try expect(transferred.count == 2, "Read-only observations did not export")
        let next = NativeCore(cleanupOpenFileProbe: { [] })
        try expect(next.importTrustedCleanupInspectionObservations(transferred, homeDirectory: home.path) == 2,
                   "Second process handoff rejected unchanged observations")
        for carried in next.exportCleanupInspectionObservations(homeDirectory: home.path) {
            let initial = pair.first { $0.path == carried.path }!
            try expect(initial.firstObservedContinuousTicks == carried.firstObservedContinuousTicks
                && initial.expiresAtContinuousTicks == carried.expiresAtContinuousTicks,
                "Forwarding renewed the original deadline")
        }
        let unrelated = NativeCore(cleanupOpenFileProbe: { [] })
        try expect(unrelated.exportCleanupInspectionObservations(homeDirectory: home.path).isEmpty,
                   "Unrelated instance implicitly trusted another instance's observation")

        func rejected(_ values: [NativeCore.CleanupInspectionObservation], _ reason: String) throws {
            let core = NativeCore(cleanupOpenFileProbe: { [] })
            try expect(core.importTrustedCleanupInspectionObservations(values, homeDirectory: home.path) == 0, reason)
        }
        let stableChanges: [(inout stat) -> Void] = [
            { $0.st_dev += 1 }, { $0.st_ino += 1 }, { $0.st_mode ^= 1 },
            { $0.st_uid ^= 1 }, { $0.st_gid ^= 1 }, { $0.st_flags ^= 1 },
            { $0.st_nlink += 1 }, { $0.st_size += 1 },
            { $0.st_mtimespec.tv_nsec = ($0.st_mtimespec.tv_nsec + 1) % 1_000_000_000 },
            { $0.st_ctimespec.tv_nsec = ($0.st_ctimespec.tv_nsec + 1) % 1_000_000_000 },
            { $0.st_birthtimespec.tv_nsec = ($0.st_birthtimespec.tv_nsec + 1) % 1_000_000_000 }
        ]
        for (index, mutate) in stableChanges.enumerated() {
            try rejected([observation(payload, originalMutation: mutate)], "Accepted non-atime original change \(index)")
            try rejected([observation(payload, originalMutation: mutate, observedMutation: mutate)],
                         "Accepted mismatched current object field \(index)")
        }
        try rejected([observation(payload, observedMutation: { $0.st_atimespec.tv_nsec = ($0.st_atimespec.tv_nsec + 1) % 1_000_000_000 })],
                     "Accepted changed observed atime")
        try rejected([observation(payload, originalMutation: { $0.st_atimespec.tv_nsec = 1_000_000_000 })], "Accepted invalid original nanoseconds")
        try rejected([observation(payload, observedMutation: { $0.st_mtimespec.tv_nsec = -1 })], "Accepted invalid observed nanoseconds")
        let valid = try observation(payload)
        let lifetime = valid.expiresAtContinuousTicks - valid.firstObservedContinuousTicks
        try rejected([observation(payload, first: valid.expiresAtContinuousTicks)], "Accepted future observation")
        let expiredFirst = valid.firstObservedContinuousTicks > lifetime ? valid.firstObservedContinuousTicks - lifetime - 1 : 0
        try rejected([observation(payload, first: expiredFirst, expires: 0)], "Accepted expired observation")
        if valid.firstObservedContinuousTicks > lifetime {
            try rejected([observation(payload, first: expiredFirst)], "Accepted original deadline beyond 300 seconds")
        }
        try rejected([observation(payload, expires: valid.expiresAtContinuousTicks + lifetime)], "Accepted extended deadline")
        try rejected([observation(payload, first: UInt64.max)], "Accepted overflowed clock")
        let conflict = try observation(payload, originalMutation: { $0.st_atimespec.tv_sec -= 1 })
        try rejected([valid, conflict], "Conflicting duplicate imported one arbitrary record")
        try rejected(Array(repeating: valid, count: 100_001), "Accepted oversized observation batch")
        let remembered = NativeCore(cleanupOpenFileProbe: { [] })
        try expect(remembered.importTrustedCleanupInspectionObservations([valid], homeDirectory: home.path) == 1,
                   "Failed valid baseline before conflict test")
        try expect(remembered.importTrustedCleanupInspectionObservations([conflict], homeDirectory: home.path) == 0,
                   "Conflicting import replaced a live original")
        let later = try observation(payload)
        try expect(remembered.importTrustedCleanupInspectionObservations([later], homeDirectory: home.path) == 1,
                   "Identical fresh observation should retain the earlier deadline")
        try expect(remembered.exportCleanupInspectionObservations(homeDirectory: home.path).first?.expiresAtContinuousTicks
            == valid.expiresAtContinuousTicks, "Repeated import extended a remembered deadline")

        for unsafe in ["relative", home.path + "/../outside", home.path + "//unsafe", home.path + "/nul\0name"] {
            let current = try metadata(payload)
            var original = current; original.st_atimespec.tv_sec = old - 10 * 86400
            let value = NativeCore.cleanupInspectionObservationForTesting(path: unsafe, original: original, observed: current)
            try rejected([value], "Accepted unsafe observation path")
        }
        let alias = home.appendingPathComponent("alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: cache)
        let current = try metadata(payload)
        var original = current; original.st_atimespec.tv_sec = old - 10 * 86400
        let aliased = NativeCore.cleanupInspectionObservationForTesting(path: alias.appendingPathComponent("payload.cache").path,
            original: original, observed: current)
        try rejected([aliased], "Accepted symlink ancestor despite identical final stat")
        let outside = fixture.appendingPathComponent("outside.cache")
        try Data(repeating: 0x53, count: 8192).write(to: outside)
        try rejected([observation(outside)], "Accepted path outside scan home")

        let beforeReplacement = try observation(payload)
        let moved = cache.appendingPathComponent("old-payload.cache")
        try expect(payload.path.hasPrefix(fixture.path + "/") && moved.path.hasPrefix(fixture.path + "/")
            && !fm.fileExists(atPath: moved.path), "Unexpected nonce replacement targets")
        try fm.moveItem(at: payload, to: moved)
        try Data(repeating: 0x53, count: 8192).write(to: payload)
        try rejected([beforeReplacement], "Replacement inode inherited old read evidence")
        try expect(remembered.exportCleanupInspectionObservations(homeDirectory: home.path).isEmpty,
                   "Evidence survived current object replacement")
        print("Inspection handoff: portable age preservation, Codable/hops, stable stat+atime/namespace/current/replacement, expiry/future/conflict/cap passed")
    }
}
