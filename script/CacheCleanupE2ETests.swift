import AppKit
import Darwin
import Foundation

/// Filesystem E2E: production discovery, immutable plan, deletion and rescan.
/// Process probes are injected only for deterministic matrix cases. The live
/// descriptor scenario below uses the production lsof probe with a real open fd.
@main struct CacheCleanupE2ETests {
    static let fm = FileManager.default
    static func write(_ url: URL, _ payload: Data = Data(repeating: 0x53, count: 8192)) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try payload.write(to: url)
    }
    static func ageTree(_ root: URL) throws {
        let paths = [root] + (fm.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
        let seconds = Int(Date().addingTimeInterval(-9 * 86400).timeIntervalSince1970)
        for path in paths.reversed() {
            var times = [timeval(tv_sec: seconds, tv_usec: 0), timeval(tv_sec: seconds, tv_usec: 0)]
            try cacheExpect(utimes(path.path, &times) == 0, "cannot age fixture " + path.path)
        }
    }
    static func covered(_ path: String, by root: String) -> Bool { path == root || path.hasPrefix(root + "/") }
    static func items(_ scan: NativeCore.CleanupScan, payload: String) -> [DeletionPlan.Item] {
        scan.categories.flatMap { category in
            category.paths.filter { covered(payload, by: $0) }.map {
                DeletionPlan.Item(record: $0, identity: category.pathIdentities[$0] ?? "")
            }
        }
    }
    static func scan(_ core: NativeCore, _ home: URL) async -> NativeCore.CleanupScan {
        await core.scanCleanup(homeDirectory: home.path, mode: .deep,
            agentPresence: AgentPresenceContext(applicationDirs: [], searchPath: []))
    }
    static func roundTrip(_ item: CacheFixtureCase, fixture: URL) async throws {
        let home = fixture.appendingPathComponent(item.name + "/home")
        let root = home.appendingPathComponent(item.root)
        let payload = root.appendingPathComponent("fixture.cache")
        try write(payload)
        var preserved = ["Documents/user.txt", ".codex/auth.json", ".codex/sessions/history.jsonl",
                         ".cache/huggingface/models/weights", ".npm/custom-data/keep"]
        if let profile = item.root.range(of: "/Default/") {
            let prefix = String(item.root[..<profile.lowerBound]) + "/Default/"
            preserved += [prefix + "Cookies", prefix + "Login Data", prefix + "IndexedDB/site.db"]
        }
        let sentinel = Data("keep this user data".utf8)
        for relative in preserved { try write(home.appendingPathComponent(relative), sentinel) }
        if item.aged { try ageTree(root) }
        let core = NativeCore(cleanupOpenFileProbe: { [] })
        if item.name == "gradle-build" {
            let defaults = await scan(core, home)
            try cacheExpect(defaults.succeeded && items(defaults, payload: payload.path).isEmpty
                && fm.fileExists(atPath: payload.path), "default whitelist failed to retain Gradle")
        }
        // An empty fixture whitelist opts out of convenience exclusions;
        // unconditional safety exclusions and production checks still apply.
        try write(home.appendingPathComponent(".config/mole/whitelist"), Data())
        let before = await scan(core, home)
        try cacheExpect(before.succeeded, "E2E \(item.name): scan incomplete")
        let plan = items(before, payload: payload.path)
        try cacheExpect(!plan.isEmpty && plan.allSatisfy { !$0.identity.isEmpty }, "E2E \(item.name): no identity-bound candidate")
        if item.aged {
            try cacheExpect(before.categories.allSatisfy { category in
                category.paths.filter { covered(payload.path, by: $0) }.allSatisfy { category.isPathSelected($0) }
            }, "E2E \(item.name): old regenerable cache not recommended")
        }
        let result = core.applyCleanup(items: plan, permanent: true, homeDirectory: home.path)
        try cacheExpect(result.failed == 0 && result.skipped == 0 && result.removed > 0
            && result.reclaimedBytes > 0 && !fm.fileExists(atPath: payload.path),
            "E2E \(item.name): removal failed: \(result.messages)")
        for relative in preserved {
            try cacheExpect(fm.contents(atPath: home.appendingPathComponent(relative).path) == sentinel,
                            "E2E \(item.name): changed sentinel \(relative)")
        }
        let after = await scan(core, home)
        try cacheExpect(after.succeeded && items(after, payload: payload.path).isEmpty,
                        "E2E \(item.name): removed payload offered on rescan")
        let replay = core.applyCleanup(items: plan, permanent: true, homeDirectory: home.path)
        try cacheExpect(replay.removed == 0 && replay.reclaimedBytes == 0, "E2E \(item.name): repeated plan double-counted")
        print("PASS E2E \(item.name): create → scan → identity-bound delete → preserve → rescan → replay")
    }
    static func guards(fixture: URL) async throws {
        let home = fixture.appendingPathComponent("guards/home")
        let root = home.appendingPathComponent("Library/Caches/com.example.guard")
        let payload = root.appendingPathComponent("fixture.cache")
        let core = NativeCore(cleanupOpenFileProbe: { [] })
        try write(payload)
        let initial = await scan(core, home)
        let plan = items(initial, payload: payload.path)
        try cacheExpect(!plan.isEmpty, "E2E guard fixture missing")
        let unavailable = NativeCore(cleanupOpenFileProbe: { nil }).applyCleanup(items: plan, permanent: true, homeDirectory: home.path)
        try cacheExpect(unavailable.removed == 0 && fm.fileExists(atPath: payload.path), "unknown occupancy deleted data")
        let busy = NativeCore(cleanupOpenFileProbe: { [payload.path] }).applyCleanup(items: plan, permanent: true, homeDirectory: home.path)
        try cacheExpect(busy.removed == 0 && fm.fileExists(atPath: payload.path), "busy payload deleted")
        let saved = root.deletingLastPathComponent().appendingPathComponent("saved-original")
        try fm.moveItem(at: root, to: saved); try write(payload, Data("replacement".utf8))
        let stale = core.applyCleanup(items: plan, permanent: true, homeDirectory: home.path)
        try cacheExpect(stale.removed == 0 && fm.contents(atPath: payload.path) == Data("replacement".utf8), "stale identity deleted replacement")
        let fresh = await scan(core, home)
        let freshPlan = items(fresh, payload: payload.path)
        try cacheExpect(!freshPlan.isEmpty && freshPlan.allSatisfy { !$0.identity.isEmpty }, "fresh guard plan missing")
        try write(home.appendingPathComponent(".config/mole/whitelist"), Data((root.path + "\n").utf8))
        let protected = core.applyCleanup(items: freshPlan, permanent: true, homeDirectory: home.path)
        try cacheExpect(protected.removed == 0 && fm.fileExists(atPath: payload.path), "apply ignored new whitelist")
        try fm.removeItem(at: home.appendingPathComponent(".config/mole/whitelist"))
        try fm.removeItem(at: root)
        try fm.createSymbolicLink(at: root, withDestinationURL: saved)
        let redirected = core.applyCleanup(items: freshPlan, permanent: true, homeDirectory: home.path)
        try cacheExpect(redirected.removed == 0 && fm.fileExists(atPath: saved.appendingPathComponent("fixture.cache").path), "symlink redirect deleted outside object")

        let liveHome = fixture.appendingPathComponent("live/home")
        let livePayload = liveHome.appendingPathComponent("Library/Caches/com.example.live/fixture.cache")
        let idlePayload = liveHome.appendingPathComponent("Library/Caches/com.example.idle/fixture.cache")
        try write(livePayload); try write(idlePayload)
        let liveBefore = await scan(NativeCore.shared, liveHome)
        let livePlan = items(liveBefore, payload: livePayload.path) + items(liveBefore, payload: idlePayload.path)
        try cacheExpect(livePlan.count == 2, "real process probe did not scan both fixtures")
        let fd = open(livePayload.path, O_RDONLY)
        try cacheExpect(fd >= 0, "cannot hold cache open"); defer { close(fd) }
        let partial = NativeCore.shared.applyCleanup(items: livePlan, permanent: true, homeDirectory: liveHome.path)
        try cacheExpect(partial.removed == 1 && partial.skipped == 1 && fm.fileExists(atPath: livePayload.path)
            && !fm.fileExists(atPath: idlePayload.path), "real open-file partial cleanup failed")
        print("PASS E2E guards: unknown occupancy, busy cache, replaced inode, new whitelist, symlink redirect, real fd partial success")

        let recentHome = fixture.appendingPathComponent("recent/home")
        let recentRoot = recentHome.appendingPathComponent(".npm/_cacache")
        let recentPayload = recentRoot.appendingPathComponent("fixture.cache")
        try write(recentPayload)
        let recentScan = await scan(core, recentHome)
        try cacheExpect(recentScan.categories.contains { c in
            c.paths.contains(recentRoot.path) && !c.isPathSelected(recentRoot.path)
        }, "recent developer cache was recommended")
        try cacheExpect(fm.fileExists(atPath: recentPayload.path), "scan mutated recent cache")
        print("PASS E2E recent cache: visible, unselected, retained")
    }
    static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data(("FAIL: " + error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
    static func run() async throws {
        guard CommandLine.arguments.count == 3 else { throw NSError(domain: "Arguments", code: 1) }
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        try cacheExpect(fixture.lastPathComponent.hasPrefix(".cache-e2e-fixture.") && !fixture.path.hasPrefix("/private/"), "unsafe fixture directory")
        let mode = CommandLine.arguments[2]
        DeveloperCacheLocations.override = .resolve(home: fixture.path, environment: [:], readText: { _ in nil })
        defer { DeveloperCacheLocations.override = nil }
        try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: fixture) }
        if mode != "--e2e" { try CacheCleanupUnitTests.run(home: fixture.appendingPathComponent("unit-home").path) }
        if mode != "--unit" {
            var failures: [String] = []
            let cases = CacheFixtureCase.all + [.init(name: "trash", root: ".Trash/FixtureTrash", aged: false)]
            for item in cases {
                do { try await roundTrip(item, fixture: fixture) }
                catch { failures.append(error.localizedDescription); print("FAIL " + error.localizedDescription) }
            }
            do { try await guards(fixture: fixture) }
            catch { failures.append(error.localizedDescription); print("FAIL " + error.localizedDescription) }
            try cacheExpect(failures.isEmpty, failures.joined(separator: "\n"))
        }
        print("PASS: cache cleanup " + mode)
    }
}
