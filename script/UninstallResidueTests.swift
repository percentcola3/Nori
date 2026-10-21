import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

private struct FixedApplicationSizer: ApplicationSizeMeasuring {
    func allocatedBytes(at root: URL) -> UInt64 { 4096 }
}

private struct GroupApplicationInventory: ApplicationInventoryReading {
    let base = NativeApplicationInventory()
    let groups: [String: Set<String>]
    func roots(home: URL) -> [(URL, String)] { base.roots(home: home) }
    func children(of directory: URL) -> [URL] { base.children(of: directory) }
    func metadata(at url: URL) -> ApplicationBundleMetadata? { base.metadata(at: url) }
    func directoryIdentity(_ url: URL) -> String? { base.directoryIdentity(url) }
    func installedApps(in roots: [(URL, String)]) -> [UninstallApp] { base.installedApps(in: roots) }
    func applicationGroups(at url: URL) -> Set<String> { groups[url.path] ?? [] }
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
        for data in ["Library/HTTPStorages/\(identifier).binarycookies",
                     "Library/Application Scripts/\(identifier)/script.scpt",
                     "Library/Group Containers/TEAM123456.\(identifier)/state",
                     "Library/Preferences/ByHost/\(identifier).12345678-1234-1234-1234-123456789ABC.plist"] {
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
        for relative in ["Library/HTTPStorages/\(identifier).binarycookies",
                         "Library/Application Scripts/\(identifier)",
                         "Library/Group Containers/TEAM123456.\(identifier)",
                         "Library/Preferences/ByHost/\(identifier).12345678-1234-1234-1234-123456789ABC.plist"] {
            expect(plan.dataPaths.contains(home.appendingPathComponent(relative).path),
                   "Standard app data was omitted from the uninstall plan: \(relative)")
        }
        let groupOwner = try makeApp("GroupPeer", name: "GroupPeer", bundleID: "com.example.group-peer")
        let declaredGroup = "TEAM123456.com.example.declared-storage"
        try write("Library/Group Containers/\(declaredGroup)/state")
        try write("Library/Application Scripts/\(declaredGroup)/script")
        try write("Library/Group Containers/TEAM123456.\(identifier).other/keep")
        let groupCore = NativeCore(applicationInventory: GroupApplicationInventory(groups: [
            app.path: [declaredGroup], groupOwner.path: [declaredGroup]
        ]))
        let sharedGroupPlan = await groupCore.uninstallPlan(for: app, homeDirectory: home.path)!
        for relative in ["Library/Group Containers/\(declaredGroup)", "Library/Application Scripts/\(declaredGroup)"] {
            let path = home.appendingPathComponent(relative).path
            expect(sharedGroupPlan.files.contains { $0.path == path && $0.isSharedData }
                   && !sharedGroupPlan.includingData([path]).dataPaths.contains(path),
                   "An entitlement-declared shared group must remain visible and protected")
        }
        expect(!sharedGroupPlan.files.contains {
            $0.path == home.appendingPathComponent("Library/Group Containers/TEAM123456.\(identifier).other").path
        }, "A similar vendor or Bundle ID prefix cannot prove data ownership")
        try fm.removeItem(atPath: groupOwner.path)
        let exclusiveGroupPlan = await groupCore.uninstallPlan(for: app, homeDirectory: home.path)!
        expect(exclusiveGroupPlan.dataPaths.contains(home.appendingPathComponent("Library/Group Containers/\(declaredGroup)").path),
               "An exclusive entitlement-declared group must be offered for optional uninstall")
        let opted = plan.includingData([preferences, storage, home.appendingPathComponent("Documents").path])
        expect(automatic(opted, "Library/Preferences/\(identifier).plist")
               && automatic(opted, "Library/HTTPStorages/\(identifier)"),
               "Chosen app data must be removed with the app")
        expect(!automatic(opted, "Library/Containers/\(identifier)") && !automatic(opted, "Documents"),
               "Unchosen data and paths outside the plan must stay retained")
        expect(opted.fileIdentities == plan.fileIdentities, "Choosing data must keep the reviewed identities")

        // Whole-app data is an explicit opt-in, separate from ordinary cleanup.
        let cursor = try makeApp("Cursor", name: "Cursor", bundleID: "com.todesktop.230313mzl4w4u92")
        try write("Library/Application Support/Cursor/snapshots/checkpoint", bytes: 8192)
        try write("Library/Application Support/Cursor/User/workspaceStorage/state")
        try write("Library/Application Support/Cursor/Cache/entry")
        let cursorPlan = await core.uninstallPlan(for: cursor, homeDirectory: home.path)!
        let cursorRoot = home.appendingPathComponent("Library/Application Support/Cursor").path
        let cursorData = cursorPlan.files.filter { $0.isAgentData && ($0.path == cursorRoot || $0.path.hasPrefix(cursorRoot + "/")) }
        for suffix in ["snapshots", "User/workspaceStorage"] {
            let needed = cursorRoot + "/" + suffix
            expect(cursorData.contains { $0.informational && (needed == $0.path || needed.hasPrefix($0.path + "/")) },
                   "Exclusive history must remain opt-in whether its parent is whole or split around protected data")
        }
        let optedCursor = cursorPlan.includingData(Set(cursorData.map(\.path)))
        expect(cursorData.allSatisfy { selected in optedCursor.files.contains { $0.path == selected.path && !$0.informational } },
               "Explicitly selected history parts must enter the uninstall request")
        expect(automatic(cursorPlan, "Library/Application Support/Cursor/Cache"),
               "History protection must not hide the Agent's regenerable cache leaves")
        try write("Library/Application Support/Cursor/User/real-project/.git/config")
        let renamedCursor = try makeApp("AnotherCursorCopy", name: "Cursor", bundleID: "com.example.other-cursor")
        let sharedCursor = await core.uninstallPlan(for: cursor, homeDirectory: home.path)!
        expect(!sharedCursor.dataPaths.contains { $0 == cursorRoot || $0.hasPrefix(cursorRoot + "/") },
               "A renamed installation sharing the support name must also protect partitioned history roots")
        try fm.removeItem(atPath: renamedCursor.path)
        try fm.removeItem(atPath: cursor.path)

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
        let standardPaths = Set(plan.dataPaths.filter {
            $0.contains("/Application Scripts/") || $0.contains("/ByHost/") || $0.hasSuffix(".binarycookies")
                || $0.contains("/Group Containers/TEAM123456.")
        })
        let standardItems = standardPaths.compactMap { path in
            plan.fileIdentities[path].map { DeletionPlan.Item(record: path, identity: $0) }
        }
        let fixtureTrash = fixture.appendingPathComponent("trash")
        try fm.createDirectory(at: fixtureTrash, withIntermediateDirectories: true)
        let standardResult = core.applyCleanup(items: standardItems, permanent: false,
            homeDirectory: home.path, verifiedTargets: standardPaths, trashHandler: { url in
                try fm.moveItem(at: url, to: fixtureTrash.appendingPathComponent(UUID().uuidString))
            })
        expect(standardResult.failed == 0 && standardResult.skipped == 0
               && standardResult.removedPaths == standardPaths
               && standardPaths.allSatisfy { !fm.fileExists(atPath: $0) },
               "Newly identified standard data must actually leave its original paths: \(standardResult.messages)")

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
        expect(siblingPlan.dataPaths.isEmpty,
               "Shared data must not be selectable while another installation still owns it")
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
        try testWholeAppDataConsent(fixture: fixture)
        try await testUninstalledDataScan(fixture: fixture)
        print("Uninstall residues: cache coverage, fresh scan, shared owners, symlinks and verified results passed")
    }

    static func testUninstalledDataScan(fixture: URL) async throws {
        let home = fixture.appendingPathComponent("uninstalled-scan")
        let fm = FileManager.default
        func write(_ relative: String) throws {
            let url = home.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 1, count: 8192).write(to: url)
        }
        let snapshots = home.appendingPathComponent("Library/Application Support/Cursor/snapshots")
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 8192).write(to: snapshots.appendingPathComponent("history"))
        let core = NativeCore(cleanupOpenFileProbe: { [] })
        let bin = home.appendingPathComponent("bin")
        let presence = AgentPresenceContext(applicationDirs: [home.appendingPathComponent("Applications").path], searchPath: [bin.path])
        try write(".config/fixture-cli/settings.json")
        try write(".local/share/fixture-cli/history")
        try write(".fixture-cli/real-project/.git/config")
        try write(".fixture-cli/real-project/code.swift")
        try write(".config/fixture-cli.toml")
        try write(".fixture-clirc")
        try write("Library/Caches/Homebrew/fixture-cli--1.2.3.arm64_sequoia.bottle.tar.gz")
        try write("Library/Caches/Homebrew/downloads/" + String(repeating: "a", count: 64) + "--fixture-cli--1.2.3.arm64_sequoia.bottle.tar.gz")
        try write("Library/Caches/Homebrew/fixture-cli-other--9.0.bottle.tar.gz")
        try write("Library/Logs/Homebrew/fixture-cli/post_install.log")
        try write(".config/fixture-cli-other.toml")
        try write(".unknown-tool/keep")
        try write("Library/WebKit/com.example.alreadydeleted/state")
        try write("Library/Preferences/com.example.alreadydeleted.plist")
        try write("Library/Group Containers/2BBY89MBSN.dev.warp/warp.sqlite")
        try write("Library/Application Support/com.example.onlyproject/Repo/.git/config")
        try write("Library/Application Support/com.example.onlyproject/Repo/code.swift")
        let cli = UninstallDataOwner(kind: .cli, name: "fixture-cli", installationPath: home.path + "/tools/fixture-cli",
                                     names: ["fixture-cli"], commands: ["fixture-cli"])
        core.rememberUninstallDataOwners([cli], homeDirectory: home.path)
        try write("Library/Application Support/Code/User/history")
        try write(".vscode/extensions/fixture/extension.json")
        let code = UninstallDataOwner(kind: .application, name: "Visual Studio Code", bundleID: "com.example.VSCode",
                                      names: ["Code", "Visual Studio Code"])
        let codePlan = core.uninstalledDataPlan(owner: code, homeDirectory: home.path, presence: presence)
        let codeData = codePlan.files.filter(\.isAgentData).map(\.path)
        expect(["Library/Application Support/Code/User/history", ".vscode/extensions/fixture/extension.json"].allSatisfy { relative in
            let needed = home.path + "/" + relative
            return codeData.contains { needed == $0 || needed.hasPrefix($0 + "/") }
        },
               "Standard app-support aliases and bundle-suffix extension directories must both support opt-in deep cleanup")
        // Capture bundle metadata while installed; the data name deliberately
        // differs from the .app filename and has no reverse-DNS spelling.
        let appURL = home.appendingPathComponent("Applications/FixtureDeep.app")
        try fm.createDirectory(at: appURL.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "com.example.fixturedeep", "CFBundleName": "FriendlySupport", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: appURL.appendingPathComponent("Contents/Info.plist"))
        try write("Library/Application Support/FriendlySupport/History/record")
        try write("Library/Application Support/FriendlySupport/RealProject/.git/config")
        try write("Library/Application Support/FriendlySupport/RealProject/code.swift")
        let app = UninstallApp(name: "FriendlySupport", bundleID: "com.example.fixturedeep", source: "Fixture", path: appURL.path, size: "0")
        guard let appPlan = await core.uninstallPlan(for: app, homeDirectory: home.path) else { preconditionFailure("Missing app preview") }
        let appHistory = home.path + "/Library/Application Support/FriendlySupport/History"
        expect(appPlan.files.contains { $0.path == appHistory && $0.isAgentData }, "Generic app history must be opt-in in the software uninstall preview")
        expect(!appPlan.dataPaths.contains { $0.contains("RealProject") }, "Generic software uninstall offered a real project for deletion")
        try fm.removeItem(at: appURL)
        let scan = await core.scanCleanup(homeDirectory: home.path, mode: .deep, agentPresence: presence)
        expect(scan.categories.contains { $0.source == .appLeftover && $0.paths.contains(home.appendingPathComponent("Library/Application Support/Cursor").path) },
               "Uninstalled Cursor history must appear in uninstall leftovers during cleanup scanning")
        let published = CleanupRiskPolicy.presentationCategories(scan.categories, running: .init(), homeDirectory: home.path)
        let residues = published.filter { $0.uninstallDataOwner != nil }
        expect(!residues.isEmpty && residues.allSatisfy { !$0.selected && !$0.quickCleanEligible },
               "Uninstall data must publish unselected and never enter automatic cleanup")
        let paths = residues.flatMap(\.paths)
        let warpDatabase = home.path + "/Library/Group Containers/2BBY89MBSN.dev.warp/warp.sqlite"
        expect(paths.contains { warpDatabase == $0 || warpDatabase.hasPrefix($0 + "/") },
               "A generic bundle-ID candidate must not hide the actual Agent owner's leftover data")
        expect(!published.flatMap(\.paths).contains { $0.contains("com.example.onlyproject") },
               "A protected project was re-admitted by the legacy app-data scan")
        expect(paths.contains(home.path + "/.config/fixture-cli") && paths.contains(home.path + "/.local/share/fixture-cli"),
               "Generic CLI configuration and history disappeared after uninstall")
        let brewDownload = home.path + "/Library/Caches/Homebrew/downloads/" + String(repeating: "a", count: 64)
            + "--fixture-cli--1.2.3.arm64_sequoia.bottle.tar.gz"
        expect([".config/fixture-cli.toml", ".fixture-clirc",
                "Library/Caches/Homebrew/fixture-cli--1.2.3.arm64_sequoia.bottle.tar.gz",
                "Library/Logs/Homebrew/fixture-cli"].allSatisfy { paths.contains(home.path + "/" + $0) }
               && paths.contains(brewDownload),
               "Single-file configs and Homebrew per-package caches/logs must be offered for a removed CLI")
        expect(!paths.contains { $0.contains("fixture-cli-other") },
               "A different package sharing the name prefix must never be offered")
        expect(paths.contains(appHistory), "Named app data was lost after the .app and its metadata were removed")
        expect(paths.contains(home.path + "/Library/WebKit/com.example.alreadydeleted")
               && paths.contains(home.path + "/Library/Preferences/com.example.alreadydeleted.plist"),
               "Old bundle-ID leftovers, including small preferences, must be detected without a saved inventory")
        expect(!paths.contains { $0.contains(".unknown-tool") || $0.contains("real-project") || $0 == home.path + "/.fixture-cli" },
               "Unknown directories and real project code must be retained")
        guard let cliCategory = residues.first(where: { $0.uninstallDataOwner?.id == cli.id }) else {
            preconditionFailure("Missing CLI residue category")
        }
        let selectedCLI = cliCategory.selectingPaths([home.path + "/.config/fixture-cli"])
        let none = core.applyUninstallResidues([cliCategory], homeDirectory: home.path, presence: presence,
            trashHandler: { _ in preconditionFailure("Unselected leftovers were removed") })
        expect(none.removed == 0, "Empty leftover selection must do nothing")
        try write("bin/fixture-cli")
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("fixture-cli").path)
        let installed = await core.scanCleanup(homeDirectory: home.path, mode: .deep, agentPresence: presence)
        expect(!installed.categories.contains { $0.uninstallDataOwner?.id == cli.id }, "Installed CLI was labeled as uninstall garbage")
        let reinstalled = core.applyUninstallResidues([selectedCLI], homeDirectory: home.path, presence: presence,
            trashHandler: { _ in preconditionFailure("CLI reinstalled after review was ignored") })
        expect(reinstalled.removed == 0 && reinstalled.skipped > 0, "Reinstallation must invalidate leftover consent")
        try fm.removeItem(at: bin.appendingPathComponent("fixture-cli"))
        let trash = fixture.appendingPathComponent("scan-trash")
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        var selected = residues.map { $0.selectingPaths($0.paths) }
        // Retain one CLI history path to verify partial selection remains exact.
        for index in selected.indices where selected[index].uninstallDataOwner?.id == cli.id {
            selected[index] = selected[index].selectingPaths([home.path + "/.config/fixture-cli"])
        }
        let applied = core.applyUninstallResidues(selected, homeDirectory: home.path, presence: presence) { url in
            try fm.moveItem(at: url, to: trash.appendingPathComponent(UUID().uuidString))
        }
        expect(applied.removed > 0 && applied.failed == 0 && !fm.fileExists(atPath: snapshots.path),
               "Scanned Agent history did not actually move to fixture Trash")
        expect(!fm.fileExists(atPath: home.path + "/.config/fixture-cli")
               && fm.fileExists(atPath: home.path + "/.local/share/fixture-cli/history")
               && fm.fileExists(atPath: home.path + "/.fixture-cli/real-project/code.swift"),
               "CLI deep cleanup did not respect exact consent and real project protection")
        expect(!fm.fileExists(atPath: appHistory)
               && fm.fileExists(atPath: home.path + "/Library/Application Support/FriendlySupport/RealProject/code.swift"),
               "Generic app deep cleanup must move history and retain real project code")
    }

    static func testWholeAppDataConsent(fixture: URL) throws {
        let fm = FileManager.default
        let home = fixture.appendingPathComponent("consent-home")
        func write(_ relative: String) throws {
            let url = home.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: url)
        }
        let support = "Library/Application Support/Cursor/"
        try write(support + "snapshots/checkpoint/.git/config")
        try write(support + "User/workspaceStorage/state")
        try write(support + "User/real-project/.git/config")
        try write(support + "User/real-project/main.swift")
        try write(".cursor/extensions/example/payload")
        try write(".cursor/embedded-cli/bin/cursor-agent")
        try write(".cursor/embedded-cli/lib/runtime")
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.appendingPathComponent(".cursor/embedded-cli/bin/cursor-agent").path)
        try write(".cursor/state.vscdb")
        try write(".cursor/state.vscdb-wal")
        try write(".cursor/worktrees/project/.git")
        try write(".cursor/skills/shared/SKILL.md")
        try write(".cursor/shared-mcp/worker")
        try write(".cursor/shared data/dataset")
        try write(".cursor/shared relative/dataset")
        try write("Applications/Codex.app/Contents/Info.plist")
        try fm.createDirectory(at: home.appendingPathComponent(".codex/skills"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: home.appendingPathComponent(".codex/skills/shared"),
            withDestinationURL: home.appendingPathComponent(".cursor/skills/shared"))
        let mcp = home.appendingPathComponent(".cursor/shared-mcp/worker").path
        let sharedData = home.appendingPathComponent(".cursor/shared data").path
        try Data(("[projects.\"" + home.path + "\"]\ntrust_level = 'trusted'\n"
                  + "[mcp_servers.shared]\ncommand = \"" + mcp + "\"\nargs = ['" + sharedData + "', '../.cursor/shared relative']\n").utf8)
            .write(to: home.appendingPathComponent(".cursor/shared-config.toml"))
        try write("Applications/Zed.app/Contents/Info.plist")
        try write(".cursor/shared-jsonc/worker")
        let zedSettings = home.appendingPathComponent(".config/zed/settings.json")
        try fm.createDirectory(at: zedSettings.deletingLastPathComponent(), withIntermediateDirectories: true)
        let jsonc = "{ // JSONC settings\n\"unrelatedProjectRoot\": \"" + home.path + "\",\n"
            + "\"context_servers\": {\"shared\": {\"command\": \"" + home.path + "/.cursor/shared-jsonc/worker\",},},}"
        try Data(jsonc.utf8).write(to: zedSettings)
        try fm.createSymbolicLink(at: home.appendingPathComponent(".codex/config.toml"),
            withDestinationURL: home.appendingPathComponent(".cursor/shared-config.toml"))
        let presence = AgentPresenceContext(applicationDirs: [home.appendingPathComponent("Applications").path],
            searchPath: [home.appendingPathComponent(".cursor/embedded-cli/bin").path])
        let core = NativeCore(cleanupOpenFileRecordsProbe: { [] })
        let plan = core.uninstalledAgentDataPlan(agentIDs: ["cursor"], homeDirectory: home.path, presence: presence)
        let snapshot = home.appendingPathComponent(support + "snapshots").path
        let state = home.appendingPathComponent(support + "User/workspaceStorage").path
        let extensions = home.appendingPathComponent(".cursor/extensions").path
        let selectable = Set(plan.files.filter(\.isAgentData).map(\.path))
        expect(selectable.isSuperset(of: [snapshot, state, extensions]),
               "Snapshots, state and extensions should be offered for whole-app-data consent: \(selectable)")
        for retained in [support + "User/real-project", ".cursor/worktrees", ".cursor/skills/shared", ".cursor/shared-mcp/worker", ".cursor/shared data", ".cursor/shared-config.toml", ".cursor/shared relative", ".cursor/embedded-cli"] {
            let path = home.appendingPathComponent(retained).path
            expect(!selectable.contains { path == $0 || path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/") },
                   "Real projects or shared resources entered the removal selection: \(retained)")
        }
        let unchecked = core.applyUninstalledAgentData(plan, selecting: [])
        expect(unchecked.removed == 0 && fm.fileExists(atPath: snapshot), "An empty selection removed app history")
        let database = home.appendingPathComponent(".cursor/state.vscdb").path
        let partialDatabase = core.applyUninstalledAgentData(plan, selecting: [database], trashHandler: { _ in
            preconditionFailure("A partial SQLite family was moved")
        })
        expect(partialDatabase.failed > 0 && partialDatabase.removed == 0,
               "A database must be selected together with its WAL/SHM/journal family")
        let unknown = NativeCore(cleanupOpenFileRecordsProbe: { nil }).applyUninstalledAgentData(plan, selecting: [snapshot],
            trashHandler: { _ in preconditionFailure("History was removed without a complete runtime probe") })
        expect(unknown.removed == 0 && unknown.skipped > 0, "Unknown open-file state must retain all app data")
        let identity = DeletionPlan.identity(at: snapshot)!
        let forged = core.applyCleanup(items: [.init(record: snapshot, identity: identity)], permanent: false,
            homeDirectory: home.path, verifiedTargets: [snapshot], trashHandler: { _ in preconditionFailure("Ordinary cleanup bypassed history protection") })
        expect(forged.removed == 0 && forged.skipped > 0, "The new opt-in weakened ordinary cleanup")
        let trash = fixture.appendingPathComponent("consent-trash")
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        let result = core.applyUninstalledAgentData(plan, selecting: [snapshot, state, database, database + "-wal"], trashHandler: { url in
            try fm.moveItem(at: url, to: trash.appendingPathComponent(UUID().uuidString))
        })
        expect(result.succeeded && result.removed == 4 && !fm.fileExists(atPath: snapshot) && !fm.fileExists(atPath: state)
               && !fm.fileExists(atPath: database) && !fm.fileExists(atPath: database + "-wal"),
               "Explicitly selected app history did not leave its original paths: \(result.messages)")
        expect(fm.fileExists(atPath: home.appendingPathComponent(support + "User/real-project/main.swift").path)
               && fm.fileExists(atPath: home.appendingPathComponent(".cursor/worktrees/project/.git").path)
               && fm.fileExists(atPath: home.appendingPathComponent(".cursor/skills/shared/SKILL.md").path)
               && fm.fileExists(atPath: mcp), "Whole-app data removal damaged a project or shared resource")
        try fm.removeItem(atPath: extensions)
        try write(".cursor/extensions/replacement/new-data")
        let changed = core.applyUninstalledAgentData(plan, selecting: [extensions], trashHandler: { _ in
            preconditionFailure("A replacement directory was deleted using old consent")
        })
        expect(changed.removed == 0 && changed.skipped > 0, "Old consent rebound to a replacement directory")
        let fresh = core.uninstalledAgentDataPlan(agentIDs: ["cursor"], homeDirectory: home.path, presence: presence)
        try write("Applications/Cursor.app/Contents/Info.plist")
        let reinstalled = core.applyUninstalledAgentData(fresh, selecting: [extensions], trashHandler: { _ in
            preconditionFailure("Data was removed after the owner reappeared")
        })
        expect(reinstalled.removed == 0 && reinstalled.skipped > 0, "An installation appearing after consent was ignored")
        try fm.removeItem(at: home.appendingPathComponent("Applications/Cursor.app"))
        try fm.createSymbolicLink(at: home.appendingPathComponent(".codex/skills/new-shared"),
            withDestinationURL: URL(fileURLWithPath: extensions))
        let newlyShared = core.applyUninstalledAgentData(fresh, selecting: [extensions], trashHandler: { _ in
            preconditionFailure("A newly shared resource was deleted")
        })
        expect(newlyShared.removed == 0 && newlyShared.skipped > 0, "Sharing changes after consent were ignored")
    }
}
