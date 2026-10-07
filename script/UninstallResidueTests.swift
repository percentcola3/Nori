import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

private struct FixedApplicationSizer: ApplicationSizeMeasuring {
    func allocatedBytes(at root: URL) -> UInt64 { 4096 }
}

@main
struct UninstallResidueTests {
    static func main() async throws {
        let fm = FileManager.default
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        let home = fixture.appendingPathComponent("home")
        let identifier = "com.example.nori-uninstall-fixture"
        let appName = "NoriUninstallFixture"
        func write(_ path: String, bytes: Int = 128) throws {
            let url = home.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 97, count: bytes).write(to: url)
        }
        func makeApp(_ filename: String, name: String, bundleID: String) throws -> UninstallApp {
            let url = home.appendingPathComponent("Applications/" + filename + ".app")
            try fm.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            let info = ["CFBundleIdentifier": bundleID, "CFBundleName": name,
                        "CFBundlePackageType": "APPL", "CFBundleExecutable": filename]
            let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try data.write(to: url.appendingPathComponent("Contents/Info.plist"))
            return UninstallApp(name: name, bundleID: bundleID, source: "Fixture", path: url.path, size: "1 KB")
        }
        func automatic(_ plan: UninstallPlan, _ relative: String) -> Bool {
            plan.files.contains { !$0.informational && $0.path == home.appendingPathComponent(relative).path }
        }
        let app = try makeApp(appName, name: appName, bundleID: identifier)
        let core = NativeCore.shared
        let applications = home.appendingPathComponent("Applications")
        var roots: [(URL, String)] = [(applications, "User Applications")]
        // Reproduce two mounted installers pointing back at the same Applications.
        for name in ["Nori", "Nori 1"] {
            let volume = fixture.appendingPathComponent("Volumes/" + name)
            try fm.createDirectory(at: volume, withIntermediateDirectories: true)
            let link = volume.appendingPathComponent("Applications")
            try fm.createSymbolicLink(at: link, withDestinationURL: applications)
            roots.append((link, "External Applications"))
        }
        let linkedHome = fixture.appendingPathComponent("LinkedHome")
        try fm.createSymbolicLink(at: linkedHome, withDestinationURL: home)
        roots.append((linkedHome.appendingPathComponent("Applications"), "Alias ancestor"))
        roots.append((fixture.appendingPathComponent("missing"), "Missing"))
        try fm.createSymbolicLink(at: applications.appendingPathComponent("Shortcut.app"),
                                 withDestinationURL: URL(fileURLWithPath: app.path))
        let deduplicated = core.installedApps(in: roots)
        expect(deduplicated.count == 1, "Installer aliases produced duplicate apps")
        expect(deduplicated.first?.path == app.path, "Inventory must use the real install path")
        expect(deduplicated.first?.source == "User Applications", "Alias replaced the original source")
        let sizingDependency = FixedApplicationSizer()
        let injectedInventory = NativeApplicationInventory(sizer: sizingDependency)
        let injectedCore = NativeCore(applicationInventory: injectedInventory, applicationSizer: sizingDependency)
        let injectedApps = injectedCore.installedApps(in: roots)
        expect(injectedApps.count == 1 && injectedApps[0].size == ByteFormat.format(4096),
               "Application discovery accepts a replacement size dependency without changing physical identity or source")
        let sizingRoot = fixture.appendingPathComponent("owned-sizing")
        try fm.createDirectory(at: sizingRoot, withIntermediateDirectories: true)
        let payload = sizingRoot.appendingPathComponent("payload")
        try Data(repeating: 97, count: 65_536).write(to: payload)
        let nativeSizer = BoundedApplicationSizeMeasurer()
        let singleBytes = nativeSizer.allocatedBytes(at: payload)
        try fm.linkItem(at: payload, to: sizingRoot.appendingPathComponent("hardlink"))
        try fm.createSymbolicLink(at: sizingRoot.appendingPathComponent("foreign-link"), withDestinationURL: home)
        expect(singleBytes > 0 && nativeSizer.allocatedBytes(at: sizingRoot) == singleBytes,
               "Size-only application measurement deduplicates hard links and never follows foreign symlinks")
        expect(nativeSizer.allocatedBytes(at: sizingRoot.appendingPathComponent("foreign-link")) == 0,
               "A symlink root cannot become an application size traversal")
        var expiredSizer = BoundedApplicationSizeMeasurer()
        expiredSizer.maximumEntries = 0
        expect(expiredSizer.allocatedBytes(at: sizingRoot) == 0, "The bounded application size dependency respects its traversal budget")
        let external = fixture.appendingPathComponent("External/Applications")
        try fm.createDirectory(at: external, withIntermediateDirectories: true)
        try fm.copyItem(at: URL(fileURLWithPath: app.path),
                        to: external.appendingPathComponent(appName + ".app"))
        roots.append((external, "External Applications"))
        expect(core.installedApps(in: roots).count == 2,
               "Distinct installs sharing a name and Bundle ID must remain visible")
        let caches = [
            "Library/Caches/\(identifier)",
            "Library/Caches/\(identifier).ShipIt",
            "Library/Caches/\(appName)",
            "Library/Logs/\(identifier)",
            "Library/Caches/com.apple.nsurlsessiond/Downloads/\(identifier)",
            "Library/Containers/\(identifier)/Data/Library/Caches",
            "Library/Containers/\(identifier)/Data/Library/Logs",
            "Library/Containers/\(identifier)/Data/tmp",
            "Library/WebKit/\(identifier)/WebsiteData/NetworkCache",
            "Library/Application Support/\(identifier)/Code Cache",
            "Library/Application Support/\(appName)/Cache",
            "Library/Application Support/\(appName)/Default/GPUCache",
            "Library/Application Support/\(appName)/Profile 2/Service Worker/CacheStorage"
        ]
        for cache in caches { try write(cache + "/entry") }
        for data in ["Library/Application Support/\(appName)/User/settings.json",
                     "Library/Application Support/\(appName)/Default/Cookies",
                     "Library/Containers/\(identifier)/Data/Documents/keep.txt",
                     "Library/HTTPStorages/\(identifier)/httpstorages.sqlite",
                     "Library/Group Containers/\(identifier)/Library/Caches/shared",
                     "Library/Preferences/\(identifier).plist"] {
            try write(data)
        }
        let emptyCache = "Library/Application Support/\(appName)/CachedData"
        try fm.createDirectory(at: home.appendingPathComponent(emptyCache), withIntermediateDirectories: true)
        guard let plan = await core.uninstallPlan(for: app, homeDirectory: home.path) else {
            preconditionFailure("Fixture uninstall plan missing")
        }
        for cache in caches { expect(automatic(plan, cache), "Missing cache: \(cache)") }
        let aliasApp = UninstallApp(name: appName, bundleID: identifier, source: "Alias",
                                    path: roots[1].0.appendingPathComponent(appName + ".app").path,
                                    size: app.size)
        let aliasPlan = await core.uninstallPlan(for: aliasApp, homeDirectory: home.path)!
        expect(automatic(aliasPlan, "Library/Caches/\(identifier)"),
               "An alias of the target must not be treated as a sibling sharing its cache")
        expect(automatic(plan, emptyCache), "Empty cache directories must not be omitted")
        for retained in ["Library/Application Support/\(appName)",
                         "Library/Containers/\(identifier)", "Library/HTTPStorages/\(identifier)",
                         "Library/Group Containers/\(identifier)", "Library/Preferences/\(identifier).plist"] {
            expect(!automatic(plan, retained), "User/shared data was scheduled for removal: \(retained)")
        }
        let preferences = home.appendingPathComponent("Library/Preferences/\(identifier).plist").path
        let storage = home.appendingPathComponent("Library/HTTPStorages/\(identifier)").path
        expect(plan.dataPaths.contains(preferences) && plan.dataPaths.contains(storage),
               "App data must be offered for optional removal")
        let opted = plan.includingData([preferences, storage, home.appendingPathComponent("Documents").path])
        expect(automatic(opted, "Library/Preferences/\(identifier).plist")
               && automatic(opted, "Library/HTTPStorages/\(identifier)"),
               "Chosen app data must be removed with the app")
        expect(!automatic(opted, "Library/Containers/\(identifier)") && !automatic(opted, "Documents"),
               "Unchosen data and paths outside the plan must stay retained")
        expect(opted.fileIdentities == plan.fileIdentities, "Choosing data must keep the reviewed identities")
        // Dot directories named after the app are offered as optional data and
        // counted in the footprint; generic or shared names are left alone.
        try write(".\(appName.lowercased())/binaries/runtime", bytes: 4096)
        try write(".config/\(appName.lowercased())/settings.json")
        try write(".cache/code/keep")
        let dotted = await core.uninstallPlan(for: app, homeDirectory: home.path)!
        let dotRoot = home.appendingPathComponent(".\(appName.lowercased())").path
        expect(dotted.dataPaths.contains(dotRoot)
               && dotted.dataPaths.contains(home.appendingPathComponent(".config/\(appName.lowercased())").path)
               && !dotted.files.contains { $0.path.hasSuffix("/.cache/code") },
               "app-named dot directories must be associated as optional data: \(dotted.dataPaths)")
        expect(dotted.space.optionalDataBytes >= 4096 && dotted.space.footprintBytes > dotted.space.totalBytes,
               "optional data must count toward the footprint but not the default total")
        let dataItems = opted.dataPaths.isEmpty ? [] : [preferences, storage].compactMap { path in
            opted.fileIdentities[path].map { DeletionPlan.Item(record: path, identity: $0) }
        }
        var trashed: [String] = []
        let dataResult = core.applyCleanup(items: dataItems, permanent: false, homeDirectory: home.path,
            allowedRoots: [app.path], allowApplicationBundle: true, verifiedTargets: [preferences, storage],
            trashHandler: { trashed.append($0.path) })
        expect(Set(trashed) == [preferences, storage] && dataResult.failed == 0,
               "Chosen app data must reach the Trash route: \(dataResult.messages)")

        // A fresh inventory must include a cache created after the displayed plan.
        let lateCache = "Library/Application Support/\(appName)/ShaderCache"
        try write(lateCache + "/new")
        let fresh = await core.uninstallPlan(for: app, homeDirectory: home.path)!
        expect(!automatic(plan, lateCache) && automatic(fresh, lateCache), "Fresh scan missed a late cache")

        // Another product using the same support name retains that shared cache.
        let collision = try makeApp("DifferentProduct", name: appName, bundleID: "com.example.other-product")
        let shared = await core.uninstallPlan(for: app, homeDirectory: home.path)!
        expect(!automatic(shared, "Library/Application Support/\(appName)/Cache"), "Shared support cache removed")
        expect(!automatic(shared, "Library/Caches/\(appName)"), "Shared named cache removed")
        expect(automatic(shared, "Library/Caches/\(identifier)"), "Unrelated shared name blocked exact bundle cache")
        try fm.removeItem(atPath: collision.path)

        let sibling = try makeApp("SiblingCopy", name: "SiblingCopy", bundleID: identifier)
        let siblingPlan = await core.uninstallPlan(for: app, homeDirectory: home.path)!
        expect(siblingPlan.files.filter { !$0.informational }.map(\.path) == [app.path],
               "Another install with the same bundle ID must retain all shared residues")
        try fm.removeItem(atPath: sibling.path)

        // A symlinked ancestor must never contribute automatic cache paths.
        let linked = try makeApp("LinkedFixture", name: "LinkedFixture", bundleID: "com.example.linked-fixture")
        let outside = fixture.appendingPathComponent("outside")
        try fm.createDirectory(at: outside.appendingPathComponent("Cache"), withIntermediateDirectories: true)
        try Data([1]).write(to: outside.appendingPathComponent("Cache/keep"))
        try fm.createSymbolicLink(at: home.appendingPathComponent("Library/Application Support/LinkedFixture"),
                                 withDestinationURL: outside)
        let linkedPlan = await core.uninstallPlan(for: linked, homeDirectory: home.path)!
        expect(!automatic(linkedPlan, "Library/Application Support/LinkedFixture/Cache"), "Followed symlink ancestor")

        // Simulate the filesystem outcome, without using Trash or touching installed apps.
        let helper = app.path + "/Contents/Frameworks/crashpad"
        let blockedCore = NativeCore(cleanupOpenFileRecordsProbe: {
            [.init(pid: 12345, process: "chrome_crashpad_handler", descriptor: "txt", access: "r", path: helper)]
        })
        let selectedData: Set<String> = [preferences, storage]
        let blockedPlan = fresh.includingData(selectedData)
        let blocked = blockedCore.applyUninstall(app, plan: fresh, homeDirectory: home.path,
                                                includingData: selectedData)
        expect(blocked.removed == 0 && !blocked.succeeded
               && blockedPlan.files.filter { !$0.informational }.allSatisfy { fm.fileExists(atPath: $0.path) },
               "A blocked app bundle must retain every cache and selected data path")
        let unknownCore = NativeCore(cleanupOpenFileRecordsProbe: { nil })
        let unknown = unknownCore.applyUninstall(app, plan: fresh, homeDirectory: home.path)
        expect(unknown.removed == 0 && !unknown.succeeded,
               "Unknown occupancy must stop before any app data is moved")
        try fm.removeItem(atPath: app.path)
        let partial = core.verifyUninstallResult(.init(removed: 1, skipped: 1, failed: 0, messages: []),
                                                files: fresh.files)
        expect(!partial.succeeded && !partial.remainingPaths.isEmpty, "Skipped cache falsely reported success")
        expect(!partial.retainedPaths.isEmpty, "Intentionally retained data was not reported")
        for file in fresh.files where !file.informational && file.path != app.path {
            if fm.fileExists(atPath: file.path) { try fm.removeItem(atPath: file.path) }
        }
        let complete = core.verifyUninstallResult(.init(removed: 10, skipped: 0, failed: 0, messages: []),
                                                 files: fresh.files)
        expect(complete.succeeded && complete.remainingPaths.isEmpty && !complete.retainedPaths.isEmpty,
               "Retained user data must remain distinct from failed cache cleanup")
        expect(fm.fileExists(atPath: home.appendingPathComponent("Library/Application Support/\(appName)/User/settings.json").path),
               "User settings were removed")
        let link = home.appendingPathComponent("Library/Caches/dangling")
        try fm.createSymbolicLink(at: link, withDestinationURL: fixture.appendingPathComponent("missing"))
        let dangling = core.verifyUninstallResult(.init(removed: 0, skipped: 0, failed: 0, messages: []),
            files: [.init(bytes: 0, label: "related", path: link.path)])
        expect(!dangling.succeeded && dangling.remainingPaths == [link.path], "Dangling residue was ignored")
        print("Uninstall residues: cache coverage, fresh scan, shared owners, symlinks and verified results passed")
    }
}
