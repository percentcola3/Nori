import AppKit
import Darwin
import Foundation

/// Payloads stay in a new .build fixture, except the identity-guarded current-user T nonce.
private struct AuditInventory: ApplicationInventoryReading {
    func roots(home: URL) -> [(URL, String)] { [(home.appendingPathComponent("Applications"), "Fixture")] }
    func children(of directory: URL) -> [URL] { [] }
    func metadata(at url: URL) -> ApplicationBundleMetadata? { nil }
    func directoryIdentity(_ url: URL) -> String? { nil }
    func installedApps(in roots: [(URL, String)]) -> [UninstallApp] { [] }
}

@main struct CleanupNativeAuditTests {
    static let fm = FileManager.default
    static var failures: [String] = []
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { failures.append(message); print("FAIL: " + message) }
    }
    static func write(_ url: URL, data: Data = Data(repeating: 0x41, count: 8192)) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
    static func age(_ url: URL) throws {
        let seconds = Int(Date().addingTimeInterval(-9 * 86400).timeIntervalSince1970)
        var times = [timeval(tv_sec: seconds, tv_usec: 0), timeval(tv_sec: seconds, tv_usec: 0)]
        guard utimes(url.path, &times) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
    static func core(open: Set<String> = []) -> NativeCore {
        NativeCore(cleanupOpenFileProbe: { open }, applicationInventory: AuditInventory())
    }
    static func locations(_ home: URL, environment: [String: String] = [:]) {
        DeveloperCacheLocations.override = .resolve(home: home.path, environment: environment, readText: { _ in nil })
    }
    static func scan(_ core: NativeCore, home: URL) async -> NativeCore.CleanupScan {
        await core.scanCleanup(homeDirectory: home.path, mode: .deep,
            agentPresence: .init(applicationDirs: [home.path + "/Applications"], searchPath: []))
    }
    static func covers(_ root: String, _ path: String) -> Bool { path == root || path.hasPrefix(root + "/") }
    static func category(_ paths: [String], retention: TimeInterval = 0) -> CleanupCategory {
        let sizes = Dictionary(uniqueKeysWithValues: paths.map { path -> (String, UInt64) in
            var metadata = stat()
            precondition(lstat(path, &metadata) == 0, "missing audit fixture: " + path)
            return (path, UInt64(max(0, metadata.st_blocks)) * 512)
        })
        return CleanupCategory(name: "Audit", paths: paths, bytes: sizes.values.reduce(0, &+),
            pathBytes: sizes, selected: true,
            source: .developerCache, risk: .safe, disposal: .permanentDelete,
            applyRoute: .developerCacheTrash, activityGuard: .openFile, retention: retention,
            reasonKey: "cleanup.risk.rebuildableDeveloperCache")
    }
    static func selection(_ fixture: URL) throws {
        let home = fixture.appendingPathComponent("selection/home")
        let old = home.appendingPathComponent(".npm/_cacache/old.cache")
        let fresh = home.appendingPathComponent(".cache/pip/fresh.cache")
        try write(old); try write(fresh); try age(old)
        locations(home)
        let selected = category([old.path, fresh.path], retention: CleanupAgePolicy.developerRetention).selectingPaths([old.path])
        let cache = fixture.appendingPathComponent("selection/snapshot.json")
        CleanupCache.save([selected], to: cache)
        let restored = CleanupCache.restore(from: cache)?.categories.first
        check(restored?.selectedPaths == [old.path], "cache restore changed per-path selection")
        check(restored?.retention == selected.retention, "cache restore lost retention")
        if let restored {
            let candidate = restored.safeCleanupCandidate
            check(candidate != nil, "presentation fixture lost measured paths")
            if let candidate { check(candidate.selectedPaths == [old.path], "presentation reselected active cache") }
        }
        let rechecked = core().preflightCleanupCategories([category([old.path, fresh.path], retention: selected.retention)], homeDirectory: home.path)
        check(rechecked.categories.flatMap(\.paths).contains(fresh.path), "preflight hid recent cache")
        check(rechecked.categories.allSatisfy { !$0.isPathSelected(fresh.path) && $0.isPathSelected(old.path) }, "preflight selected recent cache or cleared stale cache")
        let seconds = Int(Date().timeIntervalSince1970)
        var times = [timeval(tv_sec: seconds, tv_usec: 0), timeval(tv_sec: seconds, tv_usec: 0)]
        _ = utimes(old.path, &times)
        let changed = core().preflightCleanupCategories([selected], homeDirectory: home.path)
        check(changed.categories.allSatisfy { !$0.isPathSelected(old.path) }, "restore preflight ignored new file activity")
        print("Selection audit completed")
    }
    static func aliases(_ fixture: URL) async throws {
        let home = fixture.appendingPathComponent("aliases/home")
        let cache = home.appendingPathComponent("Library/Caches")
        let pairs = [(".gradle", "gradle-default"), (".cargo", "cargo-default"), ("gradle-custom", "gradle-custom"), ("cargo-custom", "cargo-custom")]
        for (alias, target) in pairs {
            let root = cache.appendingPathComponent(target)
            let leaves = alias.contains("gradle") ? ["caches/modules-2/dependency.jar", "caches/build-cache-1/output"] : ["registry/src/package/source.rs", "git/checkouts/package/source.rs", "registry/cache/package.crate"]
            for leaf in leaves { try write(root.appendingPathComponent(leaf)) }
            try fm.createSymbolicLink(at: home.appendingPathComponent(alias), withDestinationURL: root)
        }
        try write(home.appendingPathComponent(".config/mole/whitelist"), data: Data())
        locations(home, environment: ["GRADLE_USER_HOME": home.path + "/gradle-custom", "CARGO_HOME": home.path + "/cargo-custom"])
        var dependencyLeaves: [String] = []
        for (alias, target) in pairs {
            let base = cache.path + "/" + target
            if alias.contains("gradle") {
                dependencyLeaves.append(base + "/caches/modules-2/dependency.jar")
            } else {
                dependencyLeaves.append(base + "/registry/src/package/source.rs")
                dependencyLeaves.append(base + "/git/checkouts/package/source.rs")
            }
        }
        for leaf in dependencyLeaves { check(CleanupRiskPolicy.isProtectedCleanupPath(leaf, homeDirectory: home.path), "dependency alias unprotected: " + leaf) }
        let worker = core()
        let inventory = await scan(worker, home: home)
        let offered = inventory.categories.flatMap(\.paths)
        check(inventory.succeeded, "alias scan failed")
        for (_, target) in pairs {
            let relative = target.contains("gradle") ? "/caches/build-cache-1" : "/registry/cache"
            let safe = cache.path + "/" + target + relative
            check(inventory.categories.contains { $0.paths.contains(safe) && $0.retention == CleanupAgePolicy.developerRetention },
                  "physical rebuildable cache missing or bypassed retention: " + safe)
        }
        for leaf in dependencyLeaves { check(!offered.contains { covers($0, leaf) }, "dependency alias offered: " + leaf) }
        let broad = pairs.map { cache.path + "/" + $0.1 }
        let result = worker.applyCleanup(items: DeletionPlan(paths: broad).items, permanent: true, homeDirectory: home.path)
        for leaf in dependencyLeaves { check(fm.fileExists(atPath: leaf), "dependency alias deleted: " + leaf) }
        check(result.failed == 0, "alias cleanup unexpectedly failed")
        print("Alias audit: 4 tool homes, 6 dependency payloads, broad scan and deletion edges")
    }
    static func aliasRetarget(_ fixture: URL) async throws {
        let home = fixture.appendingPathComponent("retarget/home")
        let first = home.appendingPathComponent("Library/Caches/old-owner")
        let second = home.appendingPathComponent("Library/Caches/new-owner")
        let payload = second.appendingPathComponent("caches/modules-2/dependency.jar")
        try write(first.appendingPathComponent("caches/modules-2/dependency.jar"))
        try write(payload)
        try write(home.appendingPathComponent(".config/mole/whitelist"), data: Data())
        let link = home.appendingPathComponent(".gradle")
        try fm.createSymbolicLink(at: link, withDestinationURL: first)
        locations(home)
        let worker = core()
        let before = await scan(worker, home: home)
        check(before.categories.flatMap(\.paths).contains(second.path), "retarget precondition: unowned cache not offered")
        let plan = DeletionPlan(paths: [second.path])
        precondition(link.path == home.path + "/.gradle" && (try? fm.destinationOfSymbolicLink(atPath: link.path)) == first.path)
        try fm.removeItem(at: link)
        try fm.createSymbolicLink(at: link, withDestinationURL: second)
        locations(home)
        let restored = worker.preflightCleanupCategories(before.categories, homeDirectory: home.path, usingScanInventoryCache: true)
        check(!restored.categories.flatMap(\.paths).contains { covers($0, payload.path) }, "retarget reused obsolete safe-tree inventory")
        let removal = worker.applyCleanup(items: plan.items, permanent: true, homeDirectory: home.path)
        check(removal.removed == 0 && fm.fileExists(atPath: payload.path), "retargeted dependency deleted from old plan")
        print("Alias retarget audit: scan -> physical owner change -> restore -> old-plan deletion refusal")
    }
    static func mixedDepth(_ fixture: URL) async throws {
        let home = fixture.appendingPathComponent("mixed/home")
        locations(home)
        let root = home.appendingPathComponent("Library/Caches/com.example.mixed")
        let nested = root.appendingPathComponent((0..<24).map { "d\($0)" }.joined(separator: "/"))
        let ordinary = nested.appendingPathComponent("idle.cache")
        let protected = [nested.appendingPathComponent("state.sqlite"), nested.appendingPathComponent("credentials/secret"), nested.appendingPathComponent("opaque.cache"), nested.appendingPathComponent("busy.cache"), nested.appendingPathComponent("keep/whitelisted.cache")]
        try write(ordinary)
        for leaf in protected { try write(leaf, data: leaf.lastPathComponent == "opaque.cache" ? Data("SQLite format 3\0".utf8) : Data(repeating: 0x42, count: 8192)) }
        try write(home.appendingPathComponent(".config/mole/whitelist"), data: Data((protected.last!.deletingLastPathComponent().path + "\n").utf8))
        let worker = core(open: [protected[3].path])
        let before = await scan(worker, home: home)
        let paths = before.categories.filter { $0.risk == .safe }.flatMap(\.paths)
        check(paths.contains(ordinary.path), "24-level mixed cache lost idle payload")
        check(!paths.contains(root.path), "mixed root was offered whole")
        for leaf in protected { check(!paths.contains { covers($0, leaf.path) }, "mixed scan covered protected payload") }
        let removed = worker.applyCleanup(items: DeletionPlan(paths: [root.path]).items, permanent: true, homeDirectory: home.path)
        check(!fm.fileExists(atPath: ordinary.path) && removed.failed == 0, "mixed deletion failed idle descendant")
        for leaf in protected { check(fm.fileExists(atPath: leaf.path), "mixed deletion lost protected payload") }
        let deep = home.appendingPathComponent("Library/Caches/com.example.toodeep")
        let deepLeaf = deep.appendingPathComponent((0..<132).map { "d\($0)" }.joined(separator: "/") + "/entry")
        try write(deepLeaf)
        let after = await scan(worker, home: home)
        check(after.deferredPaths.contains(deep.path), "depth-limited tree reported complete")
        check(!after.completedRoots.contains(deep.path), "depth-limited tree certified for continuation")
        let deepRemoval = worker.applyCleanup(items: DeletionPlan(paths: [deep.path]).items, permanent: true, homeDirectory: home.path)
        check(deepRemoval.removed == 0 && fm.fileExists(atPath: deepLeaf.path), "depth limit failed closed at deletion")
        print("Mixed-depth audit: 24 levels/5 protected siblings; 132-level limit")
    }
    static func matrix(_ fixture: URL) async throws {
        let started = Date()
        var count = 0
        for item in CacheFixtureCase.all {
            let home = fixture.appendingPathComponent("matrix/" + item.name + "/home")
            let payload = home.appendingPathComponent(item.root + "/fixture.cache")
            try write(payload)
            try write(home.appendingPathComponent(".config/mole/whitelist"), data: Data())
            for app in ["Codex", "Cursor", "Zed"] { try fm.createDirectory(at: home.appendingPathComponent("Applications/" + app + ".app"), withIntermediateDirectories: true) }
            if item.aged { try age(payload) }
            locations(home)
            let worker = core()
            let before = await scan(worker, home: home)
            let offered = before.categories.filter { $0.risk == .safe }.flatMap(\.paths).filter { covers($0, payload.path) }
            check(before.succeeded && before.deferredPaths.isEmpty && !offered.isEmpty, "matrix discovery: " + item.name)
            let result = worker.applyCleanup(items: DeletionPlan(paths: offered).items, permanent: true, homeDirectory: home.path)
            check(result.failed == 0 && result.removed > 0 && result.reclaimedBytes > 0 && !fm.fileExists(atPath: payload.path), "matrix deletion: " + item.name)
            let replay = worker.applyCleanup(items: DeletionPlan(paths: offered).items, permanent: true, homeDirectory: home.path)
            check(replay.removed == 0 && replay.reclaimedBytes == 0, "matrix replay: " + item.name)
            count += 1
        }
        print(String(format: "Matrix: %d cache classes, scan/delete/replay in %.3fs", count, Date().timeIntervalSince(started)))
    }
    static func npmDepth(_ fixture: URL) async throws {
        let began = Date()
        let home = fixture.appendingPathComponent("npm-depth/home")
        let npm = home.appendingPathComponent(".npm/_cacache")
        let content = npm.appendingPathComponent("content-v2/sha512")
        let old = [content.appendingPathComponent("aa/00/old.cache"), content.appendingPathComponent("bb/00/old.cache")]
        let fresh = content.appendingPathComponent("bb/00/fresh.cache")
        let busy = content.appendingPathComponent("cc/00/busy.cache")
        let durable = content.appendingPathComponent("dd/00/state.sqlite")
        let unknown = content.appendingPathComponent("ee/00/unknown.cache")
        let future = content.appendingPathComponent("ff/00/future.cache")
        let index = npm.appendingPathComponent("index-v5/record")
        for leaf in old + [fresh, busy, durable, unknown, future, index] { try write(leaf) }
        for leaf in old + [busy, durable] { try age(leaf) }
        var zero = [timeval(tv_sec: 0, tv_usec: 0), timeval(tv_sec: 0, tv_usec: 0)]
        _ = utimes(unknown.path, &zero)
        let futureTime = Int(Date().timeIntervalSince1970) + 86400
        var futureTimes = [timeval(tv_sec: futureTime, tv_usec: 0), timeval(tv_sec: futureTime, tv_usec: 0)]
        _ = utimes(future.path, &futureTimes)
        locations(home)
        let worker = core(open: [busy.path])
        let measured = await scan(worker, home: home)
        let selected = measured.categories.flatMap { category in category.paths.filter(category.isPathSelected) }
        for leaf in old { check(selected.contains { covers($0, leaf.path) }, "npm old independent unit was not recommended") }
        for leaf in [fresh, busy, durable, unknown, future, index] {
            check(!selected.contains { covers($0, leaf.path) }, "npm default included retained or recent content: " + leaf.lastPathComponent)
        }
        check(!selected.contains(npm.path), "mixed npm root was selected wholesale")
        let selectedBytes = measured.categories.reduce(UInt64(0)) { result, category in
            result + category.paths.filter(category.isPathSelected).reduce(0) { $0 + (category.pathBytes[$1] ?? 0) }
        }
        check(selectedBytes == 16_384, "npm default increment must be exactly two allocated old blobs")
        check(DeletionPlan.nonOverlappingPaths(selected).count == selected.count, "npm frontier contains overlapping units")
        let applied = worker.applyCleanup(items: DeletionPlan(paths: selected).items, permanent: true, homeDirectory: home.path)
        check(applied.failed == 0 && old.allSatisfy { !fm.fileExists(atPath: $0.path) }, "npm default old content deletion failed")
        for leaf in [fresh, busy, durable, unknown, future, index] {
            check(fm.fileExists(atPath: leaf.path), "npm default deletion lost retained content")
        }

        let cacheHome = fixture.appendingPathComponent("npm-depth-cache/home")
        let cacheRoot = cacheHome.appendingPathComponent(".npm/_cacache")
        let cachedOld = cacheRoot.appendingPathComponent("content-v2/sha512/aa/00/blob")
        try write(cachedOld); try age(cachedOld)
        try write(cacheRoot.appendingPathComponent("index-v5/record"))
        locations(cacheHome)
        let cachedWorker = core()
        let first = await scan(cachedWorker, home: cacheHome)
        check(first.categories.contains { $0.paths.contains(cacheRoot.path + "/content-v2") && $0.selected }, "npm clean mixed root did not coalesce old content subtree")
        let control = CleanupScanControl(mode: .deep)
        let second = await cachedWorker.scanCleanup(homeDirectory: cacheHome.path, mode: .deep, control: control,
            agentPresence: .init(applicationDirs: [cacheHome.path + "/Applications"], searchPath: []))
        check(control.rulePreviewCounts.cached > 0, "npm mixed cache did not reuse the validated flat inventory")
        check(second.categories.contains { $0.paths.contains(cacheRoot.path + "/content-v2") && $0.selected }, "npm cache hit lost the stale frontier")
        let oldPlan = DeletionPlan(paths: [cacheRoot.path + "/content-v2"])
        let recent = Int(Date().timeIntervalSince1970)
        let oldTime = recent - 9 * 86400
        var accessed = [timeval(tv_sec: recent, tv_usec: 0), timeval(tv_sec: oldTime, tv_usec: 0)]
        _ = utimes(cachedOld.path, &accessed)
        let changed = cachedWorker.preflightCleanupCategories(first.categories, homeDirectory: cacheHome.path, usingScanInventoryCache: true)
        check(changed.categories.allSatisfy { $0.selectedPaths.isEmpty }, "npm newly accessed content remained default selected")
        let refused = cachedWorker.applyCleanup(items: oldPlan.items, permanent: true, homeDirectory: cacheHome.path,
            finalValidation: { path in
                let current = CleanupScanWorker.measure(path, control: CleanupScanControl(mode: .deep))
                return current.complete && CleanupAgePolicy.isStale(current.activityEvidence, retention: CleanupAgePolicy.developerRetention)
            })
        check(refused.removed == 0 && fm.fileExists(atPath: cachedOld.path), "npm scan-to-apply activity change was not refused")
        let partial = cachedWorker.preflightCleanupCategories(first.categories, homeDirectory: cacheHome.path,
            control: CleanupScanControl(mode: .deep, totalBudget: 0))
        check(!partial.deferredPaths.isEmpty && partial.categories.allSatisfy { $0.selectedPaths.isEmpty }, "npm partial traversal recommended unverified content")
        try age(cachedOld)
        try age(cacheRoot.appendingPathComponent("index-v5/record"))
        let whole = await scan(cachedWorker, home: cacheHome)
        check(whole.categories.contains { $0.paths.contains(cacheRoot.path) && $0.selected }, "entire stale npm tree stopped coalescing")
        print(String(format: "Npm depth: +%llu default bytes, old/fresh/busy/protected/unknown/future, cache-hit and changed activity in %.3fs", selectedBytes, Date().timeIntervalSince(began)))
    }

    static func systemTemporaryScope(_ fixture: URL) throws {
        guard geteuid() != 0, let physical = realpath(NSTemporaryDirectory(), nil) else {
            print("SKIP system-temp scope: requires a non-root current-user physical T directory")
            return
        }
        let temp = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
        free(physical)
        let prefix = "/private/var/folders/"
        let parts = temp.path.dropFirst(prefix.count).split(separator: "/")
        guard temp.path.hasPrefix(prefix), parts.count == 3, parts[0].count == 2, parts[2] == "T" else {
            print("SKIP system-temp scope: NSTemporaryDirectory is not a physical user T root")
            return
        }
        let home = fixture.appendingPathComponent("system-temp/home")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        locations(home)
        var account = stat(), scratch = stat()
        guard lstat(home.path, &account) == 0, lstat(temp.path, &scratch) == 0,
              scratch.st_mode & S_IFMT == S_IFDIR, scratch.st_uid == account.st_uid,
              account.st_uid == geteuid(), access(temp.path, W_OK | X_OK) == 0 else {
            print("SKIP system-temp scope: current-user T ownership or access unavailable")
            return
        }
        let name = ".com.openai.codex.nori-audit-" + UUID().uuidString
        let nonce = temp.appendingPathComponent(name, isDirectory: true)
        guard nonce.deletingLastPathComponent().path == temp.path,
              nonce.path == temp.path + "/" + name,
              CleanupRiskPolicy.systemCleanupAccountScopeEligible(path: nonce.path, homeDirectory: home.path) else {
            print("SKIP system-temp scope: account container is not owned by fixture UID")
            return
        }
        guard mkdir(nonce.path, 0o700) == 0 else {
            print("SKIP system-temp scope: cannot create fresh nonce, errno=\(errno)")
            return
        }
        var created = stat()
        guard lstat(nonce.path, &created) == 0, created.st_mode & S_IFMT == S_IFDIR,
              created.st_uid == account.st_uid else {
            check(false, "could not verify created system-temp nonce; retained: " + nonce.path)
            return
        }
        let proof = DeletionPlan.Metadata(created)
        func isPhysicalPath(_ url: URL) -> Bool {
            guard let resolved = realpath(url.path, nil) else { return false }
            defer { free(resolved) }
            return String(cString: resolved) == url.path
        }
        func ownsNonce() -> Bool {
            var current = stat()
            return CleanupRiskPolicy.normalizedPathLiteral(nonce.path) == temp.path + "/" + name
                && isPhysicalPath(nonce)
                && lstat(nonce.path, &current) == 0
                && proof.matches(current, allowingDirectoryContentChanges: true)
        }
        defer {
            if ownsNonce() {
                do {
                    try fm.removeItem(at: nonce)
                    check(!fm.fileExists(atPath: nonce.path), "system-temp nonce cleanup left fixture")
                } catch { check(false, "system-temp nonce cleanup failed: \(error)") }
            } else { check(false, "refused cleanup of replaced system-temp nonce: " + nonce.path) }
        }
        func temporaryCategory(_ root: URL) -> CleanupCategory {
            CleanupCategory(name: "System Temporary Files", paths: [root.path], bytes: 1,
                source: .core, risk: .safe, disposal: .permanentDelete, applyRoute: .genericTrash,
                activityGuard: .openFile, retention: 86400)
        }
        let mixed = nonce.appendingPathComponent("mixed")
        let old = (0..<50).map { mixed.appendingPathComponent("old-\($0).cache") }
        let fresh = mixed.appendingPathComponent("fresh.cache")
        let busy = mixed.appendingPathComponent("busy.cache")
        let database = mixed.appendingPathComponent("opaque.cache")
        let keep = mixed.appendingPathComponent("keep.cache")
        let model = mixed.appendingPathComponent("weights.safetensors")
        let link = mixed.appendingPathComponent("linked.cache")
        for leaf in old + [fresh, busy, keep, model] { try write(leaf) }
        try write(database, data: Data("SQLite format 3\0fixture".utf8))
        for leaf in old + [busy, database, keep, model] { try age(leaf) }
        try fm.createSymbolicLink(at: link, withDestinationURL: old[0])
        try write(home.appendingPathComponent(".config/mole/whitelist"), data: Data((keep.path + "\n").utf8))
        try age(mixed)
        let worker = core(open: [busy.path])
        let source = temporaryCategory(mixed)
        let reference = worker.preflightCleanupCategories([source], homeDirectory: home.path,
            includingAdministratorRequired: true, usingScanInventoryCache: false)
        let preview = worker.preflightCleanupCategories([source], homeDirectory: home.path,
            includingAdministratorRequired: true, usingScanInventoryCache: true)
        let paths = Set(preview.categories.flatMap(\.paths))
        let selected = Set(preview.categories.flatMap(\.selectedPaths))
        let expected = Set(old.map(\.path))
        check(preview.succeeded && preview.deferredPaths.isEmpty, "system-temp scope preflight was incomplete")
        check(paths == expected && selected == expected, "system-temp scope lost old files or offered retained content")
        check(Set(reference.categories.flatMap(\.paths)) == paths
            && reference.categories.reduce(UInt64(0), { $0 + $1.bytes }) == preview.categories.reduce(UInt64(0), { $0 + $1.bytes }),
            "system-temp context changed reference paths or allocation")
        for leaf in [fresh, busy, database, keep, model, link] {
            check(!paths.contains { covers($0, leaf.path) }, "system-temp scope covered protected item: " + leaf.lastPathComponent)
        }
        let control = CleanupScanControl(mode: .deep)
        var visits = 0
        let cancelled = worker.preflightCleanupCategories([source], homeDirectory: home.path, control: control,
            includingAdministratorRequired: true, usingScanInventoryCache: true, onVisit: { _ in
                visits += 1
                if visits == 8 { control.cancel() }
            })
        check(control.isCancelled && !cancelled.succeeded && cancelled.deferredPaths.contains(mixed.path),
            "system-temp scope did not observe cancellation")
        check(cancelled.categories.allSatisfy { $0.selectedPaths.isEmpty }, "cancelled system-temp scope offered incomplete data")
        let stale = worker.applyCleanup(items: [.init(record: old[0].path, identity: "0:0:0")], permanent: true, homeDirectory: home.path)
        check(stale.removed == 0 && fm.fileExists(atPath: old[0].path), "system-temp execution accepted stale identity")

        let swap = nonce.appendingPathComponent("swap")
        let saved = nonce.appendingPathComponent("swap-original")
        let swapLeaf = swap.appendingPathComponent("old.cache")
        try write(swapLeaf); try age(swapLeaf); try age(swap)
        let swapProof = DeletionPlan.Metadata.read(swap.path)!
        var replaced = false
        var swapError: Error?
        let changed = worker.preflightCleanupCategories([temporaryCategory(swap)], homeDirectory: home.path,
            includingAdministratorRequired: true, usingScanInventoryCache: true, onVisit: { path in
                if path == swap.path && !replaced && swapError == nil {
                    var current = stat()
                    guard ownsNonce(), isPhysicalPath(swap),
                          saved.path == nonce.path + "/swap-original",
                          !fm.fileExists(atPath: saved.path), lstat(swap.path, &current) == 0,
                          swapProof.matches(current, allowingDirectoryContentChanges: true) else {
                        swapError = CocoaError(.fileWriteUnknown); return
                    }
                    do {
                        try fm.moveItem(at: swap, to: saved)
                        try fm.createDirectory(at: swap, withIntermediateDirectories: false)
                        replaced = true
                    } catch { swapError = error }
                }
            })
        check(replaced && swapError == nil, "system-temp root replacement fixture failed")
        check(changed.categories.isEmpty && changed.deferredPaths.contains(swap.path), "system-temp scope accepted replaced root")
        check(fm.fileExists(atPath: saved.appendingPathComponent("old.cache").path), "system-temp replacement lost original fixture")

        // A cached one-day system rule must not shorten a custom npm cache's seven-day policy.
        let npmContent = nonce.appendingPathComponent("_cacache/content-v2/sha512")
        let twoDays = npmContent.appendingPathComponent("aa/00/two-day.cache")
        let nineDays = npmContent.appendingPathComponent("bb/00/nine-day.cache")
        let index = nonce.appendingPathComponent("_cacache/index-v5/recent")
        for leaf in [twoDays, nineDays, index] { try write(leaf) }
        let twoDayTime = Int(Date().addingTimeInterval(-2 * 86400).timeIntervalSince1970)
        var twoDayTimes = [timeval(tv_sec: twoDayTime, tv_usec: 0), timeval(tv_sec: twoDayTime, tv_usec: 0)]
        check(utimes(twoDays.path, &twoDayTimes) == 0, "could not age custom npm two-day fixture")
        try age(nineDays)
        locations(home, environment: ["NPM_CONFIG_CACHE": nonce.path])
        let npm = core().preflightCleanupCategories([temporaryCategory(nonce)], homeDirectory: home.path,
            includingAdministratorRequired: true, usingScanInventoryCache: true)
        let npmSelected = npm.categories.flatMap(\.selectedPaths)
        check(npm.succeeded && npm.deferredPaths.isEmpty, "custom npm/T restore was incomplete")
        check(!npmSelected.contains { covers($0, twoDays.path) }, "custom npm/T one-day rule selected two-day content")
        check(npmSelected.contains { covers($0, nineDays.path) }, "custom npm/T restore lost nine-day content")
        check(!npmSelected.contains { covers($0, index.path) }, "custom npm/T selected recent index")
        check(npm.categories.filter { $0.paths.contains { covers($0, nineDays.path) } }
            .allSatisfy { $0.retention >= CleanupAgePolicy.developerRetention }, "custom npm/T restore did not normalize retention")
        locations(home)

        let dependencyRoot = nonce.appendingPathComponent("unlabelled-data")
        let dependencyLeaf = dependencyRoot.appendingPathComponent("ordinary.cache")
        try write(dependencyLeaf); try age(dependencyLeaf); try age(dependencyRoot)
        let registry = home.appendingPathComponent(".cargo/registry")
        try fm.createDirectory(at: registry, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: registry.appendingPathComponent("src"), withDestinationURL: dependencyRoot)
        locations(home)
        let dependencyLocations = DeveloperCacheLocations.current(home: home.path)
        check(dependencyLocations.dependencyPhysicalRoots.contains(dependencyRoot.path),
            "Cargo-to-T physical snapshot lost /private spelling")
        check(DeveloperCleanupCatalog.isDependencyStoreContent(dependencyLeaf.path, home: home.path),
            "Cargo-to-T physical dependency ownership was lost")
        check(CleanupRiskPolicy.isProtectedCleanupPath(dependencyLeaf.path, homeDirectory: home.path,
            rebuildableRoot: dependencyRoot.path, rootIsVerifiedRebuildable: true),
            "Cargo-to-T dependency bypassed native content boundary")
        let dependencyWorker = core()
        let dependencyPreview = dependencyWorker.preflightCleanupCategories([temporaryCategory(dependencyRoot)],
            homeDirectory: home.path, includingAdministratorRequired: true, usingScanInventoryCache: true)
        check(dependencyPreview.succeeded && dependencyPreview.deferredPaths.isEmpty && dependencyPreview.categories.isEmpty,
            "temporary rule offered Cargo-to-T dependency content")
        let dependencyPlan = DeletionPlan(paths: [dependencyRoot.path])
        check(dependencyPlan.items.count == 1 && !dependencyPlan.items[0].identity.isEmpty,
            "Cargo-to-T execution fixture has no valid reviewed identity")
        let dependencyRemoval = dependencyWorker.applyCleanup(items: dependencyPlan.items,
            permanent: true, homeDirectory: home.path)
        check(dependencyRemoval.removed == 0 && dependencyRemoval.failed == 0 && dependencyRemoval.skipped > 0
            && fm.fileExists(atPath: dependencyLeaf.path), "native execution deleted Cargo-to-T dependency fixture")

        let aclRoot = nonce.appendingPathComponent("acl")
        let aclLeaf = aclRoot.appendingPathComponent("payload.cache")
        try write(aclLeaf); try age(aclLeaf); try age(aclRoot)
        let aclIdentity = DeletionPlan.identity(at: aclLeaf.path)!
        func aclCommand(_ arguments: [String]) throws -> Int32 {
            let command = Process()
            command.executableURL = URL(fileURLWithPath: "/bin/chmod")
            command.arguments = arguments
            try command.run(); command.waitUntilExit()
            return command.terminationStatus
        }
        let aclInstalled = try aclCommand(["+a", "\(NSUserName()) deny delete", aclLeaf.path]) == 0
        defer {
            if aclInstalled {
                if ownsNonce(), DeletionPlan.identity(at: aclLeaf.path) == aclIdentity {
                    do {
                        let status = try aclCommand(["-N", aclLeaf.path])
                        check(status == 0, "system-temp ACL fixture could not be released")
                    } catch { check(false, "system-temp ACL release failed: \(error)") }
                } else { check(false, "refused ACL release on changed system-temp fixture") }
            }
        }
        check(aclInstalled, "could not install system-temp deny-delete ACL fixture")
        if aclInstalled {
            let aclWorker = core()
            let user = aclWorker.preflightCleanupCategories([temporaryCategory(aclRoot)], homeDirectory: home.path,
                includingAdministratorRequired: false, usingScanInventoryCache: true)
            let administrator = aclWorker.preflightCleanupCategories([temporaryCategory(aclRoot)], homeDirectory: home.path,
                includingAdministratorRequired: true, usingScanInventoryCache: true)
            check(user.categories.isEmpty, "system-temp scope bypassed ACL user restriction")
            check(administrator.categories.flatMap(\.paths).contains(aclRoot.path)
                && administrator.administratorRequiredPaths.contains(aclRoot.path), "system-temp scope lost ACL administrator route")
        }
        print("System-temp scope: 50 old files, six protections, ACL, cancel, replaced root, stale execution, custom npm/T retention and Cargo/T dependency guard")
    }

    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { fatalError("missing fixture") }
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        guard fixture.path.contains("/.build/"), !fm.fileExists(atPath: fixture.path) else { fatalError("requires new .build fixture") }
        try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { DeveloperCacheLocations.override = nil }
        try selection(fixture)
        try await aliases(fixture)
        try await aliasRetarget(fixture)
        try await mixedDepth(fixture)
        try await npmDepth(fixture)
        try systemTemporaryScope(fixture)
        try await matrix(fixture)
        print("Native cleanup audit: \(checks) checks, \(failures.count) failures")
        if !failures.isEmpty { exit(1) }
    }
}
