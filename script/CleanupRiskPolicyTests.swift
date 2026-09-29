import Foundation

private struct RiskTestFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct CleanupRiskPolicyTests {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw RiskTestFailure(description: "missing fixture root")
        }
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        let policyHome = "/Users/simplemole-risk-test"
        try testDefaults()
        try testCoreClassification(home: policyHome)
        try testSourceMappings(home: policyHome)
        try testRuntimeReassessment(home: policyHome)
        try testPathSelection()
        try testLongTailMerging(home: policyHome)
        try testAgePolicyBoundaries()
        try testDisposalDecoding()
        try testMessengerOwnerScoping(home: policyHome)
        try testAnalyzeEntrySafety()
        try testDevEnvRelatedPackages()
        try testAutomationProtection(home: policyHome)
        try testCacheRoundTrip(fixture: fixture)
        try testNetmonParsing()
        try testCacheMapPolicy(home: policyHome)
        try testMoleParity(home: policyHome)
    }

    /// Cleanup-policy parity with Mole's clean/dev catalog: dependency stores
    /// are review-only, Gradle admits only build-cache-*, firmware and
    /// Messages caches are rebuildable, sandboxed tmp children are admitted per
    /// owner, and Xcode offers XCTestDevices plus superseded DeviceSupport.
    private static func testMoleParity(home: String) throws {
        for store in [home + "/.m2/repository", home + "/.m2/repository/org/example",
                      home + "/.gradle/caches", home + "/.gradle/caches/modules-2",
                      home + "/.nuget/packages", home + "/.pub-cache",
                      home + "/.cargo/git", home + "/.cargo/git/db",
                      home + "/.ivy2/cache", home + "/.sbt/boot"] {
            let descriptor = CleanupRiskPolicy.developerCache(path: store, homeDirectory: home)
            try expect(descriptor.risk == .warning && descriptor.disposal == .permanentDelete &&
                       descriptor.applyRoute == .developerCacheTrash &&
                       descriptor.reasonKey == "cleanup.risk.dependencyStore",
                       "dependency store was not review-only Warning: \(store)")
            try expect(CleanupRiskPolicy.core(section: "Developer", path: store,
                                              homeDirectory: home).risk != .safe,
                       "core route admitted a dependency store: \(store)")
        }
        for rebuildable in [home + "/.gradle/caches/build-cache-1",
                            home + "/.gradle/caches/build-cache-1/0123abcd",
                            home + "/.gradle/daemon", home + "/.gradle/workers",
                            home + "/.gradle/notifications",
                            home + "/go/pkg/mod/cache", home + "/go/pkg/mod/cache/download",
                            home + "/.cargo/registry/cache", home + "/Library/Caches/NuGet"] {
            let descriptor = CleanupRiskPolicy.developerCache(path: rebuildable, homeDirectory: home)
            try expect(descriptor.risk == .safe && descriptor.applyRoute == .developerCacheTrash &&
                       descriptor.activityGuard == .openFile,
                       "rebuildable developer cache was not Safe: \(rebuildable)")
            try expect(CleanupRiskPolicy.core(section: "Developer", path: rebuildable,
                                              homeDirectory: home).risk == .safe,
                       "core route did not dispatch a developer cache: \(rebuildable)")
        }
        try expect(CleanupRiskPolicy.developerCache(path: home + "/go/pkg/mod",
                                                    homeDirectory: home).risk == .warning,
                   "extracted Go module tree was blanket-cleanable")
        try expect(CleanupRiskPolicy.developerCache(path: home + "/.gradle/caches/build-cache",
                                                    homeDirectory: home).risk == .warning,
                   "Gradle build-cache lookalike without a suffix was admitted")

        for (path, reason) in [
            (home + "/Library/iTunes/iPhone Software Updates", "cleanup.risk.firmwareCache"),
            (home + "/Library/iTunes/iPhone Software Updates/iPhone16,1_18.0_Restore.ipsw",
             "cleanup.risk.firmwareCache"),
            (home + "/Library/Messages/StickerCache", "cleanup.risk.rebuildableCache"),
            (home + "/Library/Messages/Caches/Previews/Attachments", "cleanup.risk.rebuildableCache")
        ] {
            let descriptor = CleanupRiskPolicy.core(section: "Device Firmware", path: path,
                                                    homeDirectory: home)
            try expect(descriptor.risk == .safe && descriptor.applyRoute == .genericTrash &&
                       descriptor.reasonKey == reason,
                       "user rebuildable root was not Safe: \(path)")
        }
        for durable in [home + "/Library/Messages", home + "/Library/Messages/chat.db",
                        home + "/Library/Messages/Attachments/ab", home + "/Library/iTunes"] {
            try expect(CleanupRiskPolicy.core(section: "Messages", path: durable,
                                              homeDirectory: home).risk != .safe,
                       "Messages/iTunes user data was admitted: \(durable)")
        }

        let containerTemp = home + "/Library/Containers/com.apple.mediaanalysisd/Data/tmp"
        let tempChild = CleanupRiskPolicy.core(section: "com.apple.mediaanalysisd tmp",
                                               path: containerTemp + "/scratch.bin", homeDirectory: home)
        try expect(tempChild.risk == .safe && tempChild.activityGuard == .reverseDNSCache,
                   "sandboxed tmp child was not Safe with an owner guard")
        try expect(CleanupRiskPolicy.core(section: "tmp", path: containerTemp,
                                          homeDirectory: home).risk != .safe,
                   "sandboxed tmp root was blanket-cleanable")
        try expect(CleanupRiskPolicy.core(section: "tmp",
                                          path: home + "/Library/Containers/com.apple.mediaanalysisd/Data/Documents/x",
                                          homeDirectory: home).risk != .safe,
                   "container Documents was admitted through the tmp rule")

        let appSupport = home + "/Library/Application Support"
        for leaf in [appSupport + "/Google/Chrome/component_crx_cache",
                     appSupport + "/Google/Chrome/extensions_crx_cache",
                     appSupport + "/Google/Chrome/Crashpad/completed",
                     appSupport + "/Google/Chrome/Default/Service Worker/ScriptCache",
                     appSupport + "/Google/Chrome/Default/DawnGraphiteCache",
                     appSupport + "/Vivaldi/Default/Cache",
                     appSupport + "/Dia/User Data/Default/Code Cache"] {
            let descriptor = CleanupRiskPolicy.core(section: "Browser", path: leaf, homeDirectory: home)
            try expect(descriptor.risk == .safe && descriptor.activityGuard == .browser,
                       "browser cache leaf was not Safe with a browser guard: \(leaf)")
        }
        for durable in [appSupport + "/Google/Chrome/Default/Login Data",
                        appSupport + "/Google/Chrome/Crashpad/pending",
                        appSupport + "/Vivaldi/Default/Cookies"] {
            try expect(CleanupRiskPolicy.core(section: "Browser", path: durable,
                                              homeDirectory: home).risk != .safe,
                       "durable browser profile data was admitted: \(durable)")
        }

        let xctest = home + "/Library/Developer/XCTestDevices"
        for path in [xctest, xctest + "/0A1B2C3D-0000-4000-8000-000000000000"] {
            let descriptor = CleanupRiskPolicy.xcode(kind: "clean", path: path, homeDirectory: home)
            try expect(descriptor.risk == .safe && descriptor.activityGuard == .xcode &&
                       descriptor.applyRoute == .xcodeTrash,
                       "XCTestDevices was not guarded Safe: \(path)")
            try expect(CleanupRiskPolicy.core(section: "Xcode Test Devices", path: path,
                                              homeDirectory: home).risk == .safe,
                       "core route did not dispatch XCTestDevices: \(path)")
        }
        let deviceSupport = home + "/Library/Developer/Xcode/iOS DeviceSupport"
        let staleVersion = CleanupRiskPolicy.xcode(kind: "clean",
                                                   path: deviceSupport + "/16.0 (20A362) arm64e",
                                                   homeDirectory: home)
        try expect(staleVersion.risk == .safe && staleVersion.activityGuard == .xcode &&
                   staleVersion.reasonKey == "cleanup.risk.staleDeviceSupport",
                   "superseded DeviceSupport version offered as clean was not Safe")
        try expect(CleanupRiskPolicy.xcode(kind: "clean", path: deviceSupport,
                                           homeDirectory: home).risk == .warning,
                   "DeviceSupport root was blanket-cleanable")
        try expect(CleanupRiskPolicy.xcode(kind: "clean",
                                           path: deviceSupport + "/16.0 (20A362) arm64e/Symbols",
                                           homeDirectory: home).risk == .warning,
                   "DeviceSupport symbol subtree was admitted")
        try expect(CleanupRiskPolicy.xcode(kind: "keep", path: deviceSupport + "/16.0 (20A362) arm64e",
                                           homeDirectory: home).risk == .protected,
                   "keep-kind DeviceSupport row was not protected")
        try expect(CleanupRiskPolicy.core(section: "iOS DeviceSupport",
                                          path: deviceSupport + "/16.0 (20A362) arm64e",
                                          homeDirectory: home).risk != .safe,
                   "native core route admitted DeviceSupport without the bridge's keep-newest rule")
    }

    private static func expect(_ condition: @autoclosure () -> Bool,
                               _ message: String) throws {
        guard condition() else { throw RiskTestFailure(description: message) }
    }

    private static func testDefaults() throws {
        let unknown = CleanupCategory(name: "Unknown", paths: ["/tmp/item"], bytes: 1)
        try expect(unknown.risk == .warning, "unknown category was not Warning")
        try expect(!unknown.selected, "unknown category was selected by default")

        let protected = CleanupCategory(name: "Protected", paths: ["/tmp/item"], bytes: 1,
                                        selected: true, risk: .protected)
        try expect(!protected.selected && !protected.canSelect,
                   "Protected category accepted its requested default selection")
    }

    private static func testCoreClassification(home: String) throws {
        let safePath = home + "/Library/Caches/com.example.tool/cache.db"
        let warningPath = home + "/Library/Preferences/com.example.tool.plist"
        let diagnosticPath = home + "/Library/DiagnosticReports/Tool.crash"
        let sessionPath = home + "/.codex/sessions/2026/session.jsonl"
        let safe = CleanupRiskPolicy.core(section: "User essentials", path: safePath,
                                          homeDirectory: home)
        let warning = CleanupRiskPolicy.core(section: "User essentials", path: warningPath,
                                             homeDirectory: home)
        let diagnostic = CleanupRiskPolicy.core(section: "Diagnostic reports", path: diagnosticPath,
                                                homeDirectory: home)
        let protected = CleanupRiskPolicy.core(section: "Developer tools", path: sessionPath,
                                               homeDirectory: home)
        try expect(safe.risk == .safe && safe.activityGuard == .reverseDNSCache,
                   "explicit reverse-DNS cache was not Safe")
        try expect(warning.risk == .warning, "unknown preference was not Warning")
        try expect(diagnostic.risk == .safe && diagnostic.activityGuard == .openFile,
                   "diagnostic report was not admitted through the open-file guard")
        try expect(protected.risk == .protected, "Codex session was not Protected")

        let genericCache = CleanupRiskPolicy.core(
            section: "User essentials", path: home + "/Library/Caches/Yarn/archive",
            homeDirectory: home)
        let containerCache = CleanupRiskPolicy.core(
            section: "App caches",
            path: home + "/Library/Containers/com.example.tool/Data/Library/Caches/cache.db",
            homeDirectory: home)
        let supportCache = CleanupRiskPolicy.core(
            section: "Application Support",
            path: home + "/Library/Application Support/Example/Code Cache/js/index",
            homeDirectory: home)
        let loginData = CleanupRiskPolicy.core(
            section: "Browsers",
            path: home + "/Library/Application Support/Google/Chrome/Default/Login Data",
            homeDirectory: home)
        try expect(genericCache.risk == .safe,
                   "macOS cache root was not admitted as rebuildable")
        try expect(containerCache.risk == .safe &&
                   containerCache.activityGuard == .reverseDNSCache,
                   "container-owned cache did not retain its Bundle guard")
        try expect(supportCache.risk == .safe && supportCache.activityGuard == .openFile,
                   "explicit Application Support cache subtree was not Safe")
        // 缓存地图：登录数据库属于持久用户数据，保护级别高于旧的 Warning。
        try expect(loginData.risk == .protected,
                   "browser login database was not Protected")

    }

    private static func testSourceMappings(home: String) throws {
        let installerPath = home + "/Downloads/Tool.dmg"
        let rawInstaller = "12\tInstaller\t\(installerPath)"
        let installer = try unwrap(Parsers.installerCategory(rawInstaller), "installer category")
        try expect(installer.source == .installer && installer.risk == .warning &&
                   installer.disposal == .permanentDelete && installer.applyRoute == .installerTrash,
                   "installer mapping is not Warning/Trash/installer route")

        let leftoverPath = home + "/Library/Application Support/GhostApp"
        let leftover = CleanupRiskPolicy.appLeftover(
            path: leftoverPath, bundleIdentifier: "com.example.ghost", homeDirectory: home)
        try expect(leftover.source == .appLeftover && leftover.risk == .warning &&
                   leftover.disposal == .permanentDelete && leftover.applyRoute == .genericTrash,
                   "app leftovers were not manual-only Warning/Trash")
        let leftoverCache = CleanupRiskPolicy.appLeftover(
            path: home + "/Library/Caches/com.example.ghost",
            bundleIdentifier: "com.example.ghost", homeDirectory: home)
        try expect(leftoverCache.risk == .safe && leftoverCache.source == .appLeftover &&
                   leftoverCache.applyRoute == .genericTrash,
                   "exact bundle-owned orphan cache was not Safe")
        let leftoverSupportCache = CleanupRiskPolicy.appLeftover(
            path: home + "/Library/Application Support/GhostApp/Code Cache",
            bundleIdentifier: "com.example.ghost", homeDirectory: home)
        try expect(leftoverSupportCache.risk == .safe &&
                   leftoverSupportCache.activityGuard == .openFile,
                   "rebuildable Application Support cache was not Safe")
        for userStatePath in [
            home + "/Library/HTTPStorages/com.example.ghost.binarycookies",
            home + "/Library/Saved Application State/com.example.ghost.savedState"
        ] {
            try expect(CleanupRiskPolicy.appLeftover(
                path: userStatePath, bundleIdentifier: "com.example.ghost",
                homeDirectory: home).risk == .warning,
                "orphan login/session state was incorrectly marked Safe")
        }

        let npmPath = NSHomeDirectory() + "/.npm/_cacache"
        let developer = CleanupRiskPolicy.developerCache(path: npmPath)
        try expect(developer.source == .developerCache && developer.risk == .safe &&
                   developer.activityGuard == .openFile &&
                   developer.applyRoute == .developerCacheTrash,
                   "explicit developer cache did not receive its guarded Safe route")

        let session = CleanupRiskPolicy.ai(
            kind: "session", path: home + "/.local/share/agent/sessions", homeDirectory: home)
        let codexSessions = CleanupRiskPolicy.ai(
            kind: "session", path: home + "/.codex/sessions", homeDirectory: home)
        let model = CleanupRiskPolicy.ai(
            kind: "model", path: home + "/.ollama/models", homeDirectory: home)
        let geminiTemp = CleanupRiskPolicy.ai(
            kind: "cache", path: home + "/.gemini/tmp", homeDirectory: home)
        let codexCache = CleanupRiskPolicy.ai(
            kind: "cache", path: home + "/Library/Caches/Codex/Default/Cache",
            homeDirectory: home)
        let codexProfile = CleanupRiskPolicy.ai(
            kind: "cache", path: home + "/Library/Caches/Codex", homeDirectory: home)
        try expect(session.source == .aiSession && session.risk == .warning,
                   "AI session was not manual-only Warning")
        try expect(codexSessions.risk == .protected && codexSessions.disposal == .none,
                   "Codex sessions escaped the protected-content boundary")
        try expect(model.source == .aiModel && model.risk == .protected &&
                   model.disposal == .none,
                   "AI model was not Protected")
        try expect(geminiTemp.risk == .protected && geminiTemp.disposal == .none,
                   "Gemini temporary state disagrees with the protected-content boundary")
        try expect(codexCache.source == .aiCache && codexCache.risk == .safe &&
                   codexCache.applyRoute == .aiTrash,
                   "Codex desktop cache did not receive the guarded Safe route")
        try expect(codexProfile.risk == .warning && codexProfile.disposal == .permanentDelete,
                   "Codex profile parent was incorrectly made blanket-cleanable")

        // Electron AI clients expose only their rebuildable Chromium leaves to
        // the automatic route.  Keep each app-support parent review-only so a
        // catalog typo cannot turn settings or credentials into a delete.
        let aiCacheLeaves = [
            home + "/Library/Application Support/Antigravity/Cache",
            home + "/Library/Application Support/Antigravity/Code Cache",
            home + "/Library/Application Support/Antigravity/GPUCache",
            home + "/Library/Application Support/Antigravity/DawnGraphiteCache",
            home + "/Library/Application Support/Antigravity/DawnWebGPUCache",
            home + "/Library/Application Support/Filo/production/Cache",
            home + "/Library/Application Support/Filo/production/Code Cache",
            home + "/Library/Application Support/Filo/production/GPUCache",
            home + "/Library/Application Support/Filo/production/DawnGraphiteCache",
            home + "/Library/Application Support/Filo/production/DawnWebGPUCache",
            home + "/Library/Application Support/Claude/Cache",
            home + "/Library/Application Support/Claude/Code Cache",
            home + "/Library/Application Support/Claude/GPUCache",
            home + "/Library/Application Support/Claude/DawnGraphiteCache",
            home + "/Library/Application Support/Claude/DawnWebGPUCache",
            home + "/Library/Application Support/Claude/sentry",
            home + "/Library/Application Support/Qoder/Cache",
            home + "/Library/Application Support/Qoder/CachedData",
            home + "/Library/Application Support/Qoder/CachedExtensionVSIXs",
            home + "/Library/Application Support/Qoder/Code Cache",
            home + "/Library/Application Support/Qoder/GPUCache",
            home + "/Library/Application Support/Qoder/DawnGraphiteCache",
            home + "/Library/Application Support/Qoder/DawnWebGPUCache",
            home + "/Library/Application Support/Qoder/logs",
            home + "/.cache/prisma",
            home + "/.cache/opencode"
        ]
        for path in aiCacheLeaves {
            let descriptor = CleanupRiskPolicy.ai(kind: "cache", path: path,
                                                  homeDirectory: home)
            try expect(descriptor.source == .aiCache && descriptor.risk == .safe &&
                       descriptor.applyRoute == .aiTrash,
                       "AI cache leaf was not admitted through the guarded Safe route: \(path)")
        }
        for parent in [
            home + "/Library/Application Support/Antigravity",
            home + "/Library/Application Support/Filo",
            home + "/Library/Application Support/Claude",
            home + "/Library/Application Support/Qoder"
        ] {
            try expect(CleanupRiskPolicy.ai(kind: "cache", path: parent,
                                            homeDirectory: home).risk == .warning,
                       "AI app-support parent was incorrectly made blanket-cleanable: \(parent)")
        }

        let xcodeHome = NSHomeDirectory()
        let derived = CleanupRiskPolicy.xcode(
            kind: "clean", path: xcodeHome + "/Library/Developer/Xcode/DerivedData")
        let archive = CleanupRiskPolicy.xcode(
            kind: "keep", path: xcodeHome + "/Library/Developer/Xcode/Archives")
        try expect(derived.risk == .safe && derived.activityGuard == .xcode &&
                   derived.applyRoute == .xcodeTrash,
                   "DerivedData was not guarded Safe")
        try expect(archive.source == .xcodeArchive && archive.risk == .protected &&
                   archive.applyRoute == .none,
                   "Xcode Archives were not Protected")

        try expect(CleanupRiskPolicy.developerCache(path: "relative/cache",
                                                    homeDirectory: home).risk == .protected,
                   "relative developer path did not fail closed")
        try expect(CleanupRiskPolicy.ai(kind: "session", path: "relative/session",
                                        homeDirectory: home).risk == .protected,
                   "relative AI path did not fail closed")
        try expect(CleanupRiskPolicy.xcode(kind: "clean",
                                           path: "relative/DerivedData").risk == .protected,
                   "relative Xcode path did not fail closed")
        try expect(CleanupRiskPolicy.xcode(kind: "clean", path: "/tmp/DerivedData",
                                           homeDirectory: home).risk == .warning,
                   "lookalike Xcode cache outside its exact root was marked Safe")
    }

    private static func testRuntimeReassessment(home: String) throws {
        let path = home + "/Library/Caches/com.example.tool/data"
        let policy = CleanupRiskPolicy.core(section: "App caches", path: path,
                                            homeDirectory: home)
        let category = CleanupCategory(name: "Cache", paths: [path], bytes: 1,
                                       source: policy.source, risk: policy.risk,
                                       disposal: policy.disposal, applyRoute: policy.applyRoute,
                                       activityGuard: policy.activityGuard, reasonKey: policy.reasonKey)
        let idle = RunningApplicationSnapshot(bundleIdentifiers: [], processNames: [])
        let running = RunningApplicationSnapshot(bundleIdentifiers: ["com.example.tool"])
        try expect(CleanupRiskPolicy.reassess(category, running: idle,
                                              homeDirectory: home).risk == .safe,
                   "idle guarded cache did not remain Safe")
        try expect(CleanupRiskPolicy.reassess(category, running: running,
                                              homeDirectory: home).risk == .protected,
                   "running cache owner was not Protected")
        try expect(CleanupRiskPolicy.reassess(category, running: .unavailable,
                                              homeDirectory: home).risk == .protected,
                   "unknown process state did not fail closed")
        try expect(CleanupRiskPolicy.isEligible(category, mode: .quickClean, running: idle,
                                                homeDirectory: home),
                   "Safe Trash category was rejected by Quick Clean")

        let idlePath = home + "/Library/Caches/com.example.idle/data"
        let mixed = CleanupCategory(
            name: "App caches", paths: [path, idlePath], bytes: 3,
            pathBytes: [path: 1, idlePath: 2], source: .core, risk: .safe,
            disposal: .permanentDelete, applyRoute: .genericTrash,
            activityGuard: .reverseDNSCache,
            reasonKey: "cleanup.risk.rebuildableCache")
        let mixedSubset = try unwrap(CleanupRiskPolicy.runtimeEligibleSubset(
            mixed, running: running, homeDirectory: home), "mixed runtime subset")
        try expect(mixedSubset.paths == [path, idlePath] && mixedSubset.bytes == 3 &&
                   mixedSubset.selectedPathCount == 1 &&
                   mixedSubset.isPathSelected(idlePath),
                   "one running app suppressed unrelated cache selection")
        try expect(CleanupRiskPolicy.isEligible(mixedSubset, mode: .quickClean,
                                                running: running, homeDirectory: home),
                   "idle subset was rejected because a visible sibling is running")
        let unknownSubset = try unwrap(CleanupRiskPolicy.runtimeEligibleSubset(
            mixed, running: .unavailable, homeDirectory: home), "incomplete runtime subset")
        try expect(unknownSubset.paths == mixed.paths && !unknownSubset.selected,
                   "incomplete runtime inventory did not clear selection while preserving totals")

        let browser = CleanupCategory(
            name: "Browsers", paths: [home + "/Library/Caches/Google/Chrome"], bytes: 5,
            source: .core, risk: .safe, disposal: .permanentDelete, applyRoute: .genericTrash,
            activityGuard: .browser, reasonKey: "cleanup.risk.rebuildableCache")
        let browserRunning = try unwrap(CleanupRiskPolicy.runtimeEligibleSubset(
            browser, running: RunningApplicationSnapshot(processNames: ["Google Chrome"]),
            homeDirectory: home), "running browser subset")
        try expect(browserRunning.paths == browser.paths && !browserRunning.selected,
                   "running browser cache disappeared instead of staying visible")

        let warning = CleanupCategory(name: "Installer", paths: [home + "/Downloads/a.dmg"], bytes: 1,
                                      source: .installer, risk: .warning, disposal: .permanentDelete,
                                      applyRoute: .installerTrash, activityGuard: .unsupported,
                                      reasonKey: "cleanup.risk.installer")
        try expect(!CleanupRiskPolicy.isEligible(warning, mode: .quickClean, running: idle,
                                                 homeDirectory: home),
                   "Quick Clean accepted Warning")
        try expect(!CleanupRiskPolicy.isEligible(warning, mode: .manual, running: idle,
                                                 homeDirectory: home),
                   "manual cleanup accepted a Warning filesystem deletion")
        let command = CleanupCategory(name: "Owner command", paths: ["brew cleanup"], bytes: 1,
                                      source: .tool, risk: .warning, disposal: .command,
                                      applyRoute: .toolCommand, activityGuard: .unsupported,
                                      reasonKey: "cleanup.risk.ownerCommand")
        try expect(CleanupRiskPolicy.isEligible(command, mode: .manual, running: idle,
                                                homeDirectory: home),
                   "manual owner command was rejected with filesystem warnings")
    }

    private static func testAutomationProtection(home: String) throws {
        for path in [
            home + "/.codex/sessions",
            home + "/.claude/projects/active",
            home + "/.ollama/models",
            home + "/Library/Containers/com.docker.docker/Data"
        ] {
            try expect(CleanupRiskPolicy.isForbiddenAutomationPath(path, homeDirectory: home),
                       "automation accepted protected root: \(path)")
        }
        try expect(!CleanupRiskPolicy.isForbiddenAutomationPath(home + "/Caches/Rebuildable",
                                                                homeDirectory: home),
                   "automation rejected unrelated custom root")
        try expect(CleanupRiskPolicy.isForbiddenAutomationPath("relative/cache",
                                                               homeDirectory: home),
                   "automation accepted a relative path")
    }

    private static func testPathSelection() throws {
        let first = "/tmp/cache-a"
        let second = "/tmp/cache-b"
        var category = CleanupCategory(
            name: "Caches", paths: [first, second], bytes: 5,
            pathBytes: [first: 2, second: 3], source: .core, risk: .safe,
            disposal: .permanentDelete, applyRoute: .genericTrash, activityGuard: .none,
            reasonKey: "cleanup.risk.rebuildableCache")
        try expect(category.allSelected && category.selectedPathCount == 2 &&
                   category.selectedPathBytes == 5,
                   "Safe category did not select all child paths by default")
        try expect(category.pathsByDescendingSize == [second, first],
                   "child paths were not sorted by descending size")
        category.setPathSelected(first, selected: false)
        try expect(category.partiallySelected && category.selectedPathCount == 1 &&
                   category.selectedPathBytes == 3,
                   "child selection did not update parent count and bytes")
        let subset = try unwrap(category.selectedSubset, "selected category subset")
        try expect(subset.paths == [second] && subset.bytes == 3,
                   "cleanup subset retained an unselected child path")
        category.selected = false
        try expect(category.selectedSubset == nil && category.selectedPathCount == 0,
                   "parent deselection did not clear child selections")

        let smaller = CleanupCategory(name: "A", paths: ["/tmp/small"], bytes: 4)
        let larger = CleanupCategory(name: "B", paths: ["/tmp/large"], bytes: 9)
        try expect([smaller, larger].sorted(by: CleanupCategory.sizeDescending).map(\.bytes)
                   == [9, 4], "cleanup categories were not sorted by descending size")

        let zero = "/tmp/zero"
        let safeWithZero = CleanupCategory(
            name: "Safe", paths: [first, zero, second], bytes: 5,
            pathBytes: [first: 2, zero: 0, second: 3], source: .core, risk: .safe,
            disposal: .permanentDelete, applyRoute: .genericTrash, activityGuard: .none,
            reasonKey: "cleanup.risk.rebuildableCache")
        let warning = CleanupCategory(
            name: "node_modules", paths: ["/tmp/node_modules"], bytes: 999,
            pathBytes: ["/tmp/node_modules": 999], source: .developerCache,
            risk: .warning, disposal: .permanentDelete, applyRoute: .developerCacheTrash,
            activityGuard: .unsupported, reasonKey: "cleanup.risk.unverifiedDeveloperCache")
        let candidates = CleanupCategory.safeCleanupCandidates(from: [warning, safeWithZero])
        try expect(candidates.count == 1 && candidates[0].paths == [second, first]
                   && candidates[0].bytes == 5,
                   "cleanup candidate filter kept Warning/0B or lost size ordering")
    }

    private static func testAnalyzeEntrySafety() throws {
        let home = NSHomeDirectory()
        func entry(_ path: String, size: UInt64, isDir: Bool,
                   cleanable: Bool? = nil) -> AnalyzeEntry {
            AnalyzeEntry(name: URL(fileURLWithPath: path).lastPathComponent,
                         path: path, size: size, isDir: isDir,
                         insight: nil, cleanable: cleanable, lastAccess: nil)
        }

        let userFile = entry(home + "/Downloads/archive.zip", size: 1, isDir: false)
        let userFolder = entry(home + "/Movies", size: 700, isDir: true)
        let artifact = entry(home + "/Code/App/node_modules", size: 2,
                             isDir: true, cleanable: true)
        let appData = entry(home + "/Library/Application Support/App/data.db",
                            size: 800, isDir: false)
        let application = entry("/Applications/Example.app", size: 900, isDir: true)
        let system = entry("/Library/Application Support/System/data.db",
                           size: 1_000, isDir: false)

        try expect(userFile.canCleanDirectly && userFile.handling == .directCleanup,
                   "ordinary user file was not directly selectable")
        try expect(!userFolder.canCleanDirectly && userFolder.handling == .browse,
                   "ordinary directory was deletable instead of drill-down only")
        try expect(artifact.canCleanDirectly && artifact.handling == .directCleanup,
                   "engine-verified regenerable directory was not selectable")
        try expect(!appData.canCleanDirectly && appData.handling == .appData,
                   "ordinary app data was directly selectable")
        try expect(!application.canCleanDirectly && application.handling == .application,
                   "application bundle bypassed the uninstaller route")
        try expect(!system.canCleanDirectly && system.handling == .systemReadOnly,
                   "system content was directly selectable")

        let ordered = [system, application, appData, userFolder, userFile]
            .sorted(by: AnalyzeEntry.analysisOrder)
        try expect(ordered.map(\.handling) == [
            .systemReadOnly, .application, .appData, .browse, .directCleanup
        ], "disk analysis was not sorted by descending size")
    }

    private static func testDevEnvRelatedPackages() throws {
        let path = NSHomeDirectory() + "/.nvm/versions/node/v20.1.0"
        let modules = path + "/lib/node_modules"
        let rows = Parsers.devEnvEntries("4096\truntime\tnvm · v20.1.0\t\(path)\t3072\t\(modules)")
        let entry = try unwrap(rows.first, "nvm runtime with global packages")
        try expect(entry.bytes == 4_096 && entry.relatedBytes == 3_072 &&
                   entry.relatedPath == modules && entry.hasVersionGlobalPackages,
                   "nvm global package breakdown was not preserved")

        let legacy = Parsers.devEnvEntries("4096\truntime\tnvm · v18.0.0\t\(path)")
        try expect(legacy.first?.relatedBytes == 0 && legacy.first?.relatedPath == nil,
                   "legacy dev environment rows did not remain compatible")
    }

    private static func testCacheRoundTrip(fixture: URL) throws {
        try expect(ByteFormat.format(1_000_000_000) == "1.00 GB"
                   && ByteFormat.parse("1 GB") == 1_000_000_000,
                   "GB display and threshold bytes used different units")
        let path = fixture.appendingPathComponent("Library/Caches/com.example.tool/cache.bin")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("cache".utf8).write(to: path)
        let category = CleanupCategory(name: "Cache", paths: [path.path], bytes: 5,
                                       source: .core, risk: .safe, disposal: .permanentDelete,
                                       applyRoute: .genericTrash, activityGuard: .reverseDNSCache,
                                       reasonKey: "cleanup.risk.rebuildableCache")
        let cacheURL = fixture.appendingPathComponent("cleanup-cache.json")
        CleanupCache.save([category], to: cacheURL)
        let restored = try unwrap(CleanupCache.restore(from: cacheURL)?.categories.first,
                                  "cache round trip")
        try expect(restored.source == category.source && restored.risk == category.risk &&
                   restored.disposal == category.disposal &&
                   restored.applyRoute == category.applyRoute &&
                   restored.activityGuard == category.activityGuard &&
                   restored.reasonKey == category.reasonKey,
                   "cache lost risk metadata")

        // An empty, successful scan is a real result. It must be persisted so
        // Quick Clean can report a healthy machine without replaying the full
        // filesystem walk on every invocation.
        let emptyCacheURL = fixture.appendingPathComponent("cleanup-cache-empty.json")
        CleanupCache.save([], to: emptyCacheURL)
        let emptyRestored = CleanupCache.restore(from: emptyCacheURL)
        try expect(emptyRestored != nil && emptyRestored?.categories.isEmpty == true,
                   "empty cleanup result was not persisted")

        var json = try String(contentsOf: cacheURL, encoding: .utf8)
        // 把任意版本号降级为 10：测试不应与 CleanupCache.version 常量或
        // JSONEncoder 的键序实现漂移耦合（version 可能是最后一个键，后面
        // 紧跟 `}` 而不是 `,`），所以匹配到键名后吞掉整段连续数字。
        if let marker = json.range(of: "\"version\":") {
            var valueEnd = marker.upperBound
            while valueEnd < json.endIndex, json[valueEnd].isNumber {
                valueEnd = json.index(after: valueEnd)
            }
            json.replaceSubrange(marker.upperBound..<valueEnd, with: "10")
        }
        try Data(json.utf8).write(to: cacheURL, options: .atomic)
        try expect(CleanupCache.restore(from: cacheURL) == nil,
                   "old cache version was restored without risk metadata")
    }

    private static func testNetmonParsing() throws {
        // bytes：comm 含空格、pid 非法行丢弃。
        let samples = Parsers.netmonProcessSamples([
            "proc\t123\t100\t200\tGoogle Chrome Helper",
            "proc\t0\t1\t2\tkernel",
            "proc\t-5\t1\t2\tnegative",
            "proc\t42\tabc\t2\tbadbytes",
            "flow\t1\tx\tTCP\ta\tb",
            "garbage",
        ].joined(separator: "\n"))
        try expect(samples.count == 1,
                   "netmon bytes parser accepted invalid rows")
        try expect(samples[0] == NetmonProcessSample(pid: 123, bytesIn: 100,
                                                      bytesOut: 200,
                                                      command: "Google Chrome Helper"),
                   "netmon bytes row with spaced comm was parsed incorrectly")

        // flows：恰好六列且 remote 非空才收。
        let flows = Parsers.netmonFlows([
            "flow\t1131\tD-Chat\tTCP\t172.29.40.26:1\t221.229.52.251:80",
            "flow\t1131\tD-Chat\tUDP\t[fe80::1]:1\t[2606:4700::1]:443",
            "flow\t999\tNoRemote\tTCP\t1.2.3.4:5\t",
            "flow\t0\tZero\tTCP\ta\tb",
            "proc\t1\tx\tTCP\ta\tb",
        ].joined(separator: "\n"))
        try expect(flows.count == 2, "netmon flows parser accepted invalid rows")
        try expect(flows[0].proto == "TCP"
                   && flows[1].remote == "[2606:4700::1]:443" && flows[1].proto == "UDP",
                   "flow protocol or IPv6 endpoint was parsed incorrectly")

        // routes。
        let routes = Parsers.netmonRoutes([
            "route\t8.8.8.8\ten0",
            "route\t2606:4700::1\tunknown",
            "route\t\ten0",
        ].joined(separator: "\n"))
        try expect(routes.count == 2 && routes[1].interface == "unknown",
                   "netmon routes were parsed incorrectly")

    }

    private static func testCacheMapPolicy(home: String) throws {
        let appSupport = home + "/Library/Application Support"
        // 浏览器 Service Worker：整个目录 Safe + browser 守卫。
        for browser in ["Google/Chrome/Default", "Microsoft Edge/Default",
                        "BraveSoftware/Brave-Browser/Default", "Arc/User Data/Default"] {
            let sw = CleanupRiskPolicy.core(section: "Browsers",
                                            path: appSupport + "/\(browser)/Service Worker",
                                            homeDirectory: home)
            try expect(sw.risk == .safe && sw.activityGuard == .browser,
                       "\(browser) Service Worker was not Safe with a browser guard")
        }
        // ChromeDebug 整目录可重建。
        let debug = CleanupRiskPolicy.core(section: "Browsers",
                                           path: appSupport + "/Google/ChromeDebug",
                                           homeDirectory: home)
        try expect(debug.risk == .safe && debug.activityGuard == .browser,
                   "ChromeDebug profile was not Safe")
        // 持久用户数据：登录态/站点存储一律 Protected。
        for leaf in ["IndexedDB", "Local Storage", "Login Data", "Cookies", "Preferences"] {
            let durable = CleanupRiskPolicy.core(section: "Browsers",
                                                 path: appSupport + "/Google/Chrome/Default/\(leaf)",
                                                 homeDirectory: home)
            try expect(durable.risk == .protected,
                       "Chrome durable leaf \(leaf) was not Protected")
        }
        // Telegram：media 可清，db 与其余目录受保护。
        let telegram = home + "/Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram"
        let media = CleanupRiskPolicy.core(section: "IM",
                                           path: telegram + "/account-3/postbox/media",
                                           homeDirectory: home)
        try expect(media.risk == .safe && media.activityGuard == .messenger,
                   "Telegram media cache was not Safe with a messenger guard")
        for protected in [telegram + "/account-3/postbox/db", telegram + "/account-3"] {
            try expect(CleanupRiskPolicy.core(section: "IM", path: protected,
                                              homeDirectory: home).risk == .protected,
                       "Telegram durable path was not Protected")
        }
        // 飞书：profile_explorer 可清；sdk_storage / profile_main 受保护。
        let lark = appSupport + "/LarkShell"
        let explorer = CleanupRiskPolicy.core(section: "IM",
                                              path: lark + "/aha/users/700123/profile_explorer",
                                              homeDirectory: home)
        try expect(explorer.risk == .safe && explorer.activityGuard == .messenger,
                   "Lark profile_explorer was not Safe with a messenger guard")
        for protected in [lark + "/sdk_storage", lark + "/aha/users/700123/profile_main"] {
            try expect(CleanupRiskPolicy.core(section: "IM", path: protected,
                                              homeDirectory: home).risk == .protected,
                       "Lark durable path was not Protected")
        }
        // 禁止清单：钥匙串。
        try expect(CleanupRiskPolicy.isProtectedContent(home + "/Library/Keychains",
                                                        homeDirectory: home),
                   "Keychains was not protected content")

        // 运行态守卫：Telegram 运行中，媒体缓存升级为 Protected 且清空选择。
        let runningTelegram = RunningApplicationSnapshot(
            bundleIdentifiers: ["ru.keepcoder.Telegram"])
        let mediaCategory = CleanupCategory(
            name: "Telegram Media Cache",
            paths: [telegram + "/account-3/postbox/media"],
            bytes: 1024, selected: true,
            source: media.source, risk: media.risk,
            disposal: media.disposal, applyRoute: media.applyRoute,
            activityGuard: media.activityGuard, reasonKey: media.reasonKey)
        try expect(CleanupRiskPolicy.reassess(mediaCategory, running: runningTelegram,
                                              homeDirectory: home).risk == .protected,
                   "running Telegram did not protect its media cache")
        let subset = CleanupRiskPolicy.runtimeEligibleSubset(mediaCategory,
                                                             running: runningTelegram,
                                                             homeDirectory: home)
        try expect(subset?.selectedPathCount == 0,
                   "running Telegram kept its cache selected")
        // Brave 运行中 → 浏览器守卫同样拦截。
        let runningBrave = RunningApplicationSnapshot(processNames: ["Brave Browser"])
        let braveSW = CleanupCategory(
            name: "Brave Service Worker",
            paths: [appSupport + "/BraveSoftware/Brave-Browser/Default/Service Worker"],
            bytes: 1, selected: true,
            source: .core, risk: .safe, disposal: .permanentDelete,
            applyRoute: .genericTrash, activityGuard: .browser,
            reasonKey: "cleanup.risk.rebuildableCache")
        try expect(CleanupRiskPolicy.reassess(braveSW, running: runningBrave,
                                              homeDirectory: home).risk == .protected,
                   "running Brave did not protect its Service Worker")
    }

    /// 长尾合并：同一分桶里 <100MB 的 genericTrash 安全项凑满 3 个并成
    /// 「其他」；特殊路线、IM 守卫和不足 3 个的尾巴保持独立行。
    private static func testLongTailMerging(home: String) throws {
        let cachePath = home + "/Library/Caches/"
        func tail(_ name: String, _ suffix: String, megabytes: UInt64,
                  guard kind: CleanupActivityGuard = .openFile,
                  selected: Bool = true) -> CleanupCategory {
            let path = cachePath + suffix
            return CleanupCategory(
                name: name, paths: [path], bytes: megabytes * 1024 * 1024,
                pathBytes: [path: megabytes * 1024 * 1024],
                selected: selected, source: .core, risk: .safe,
                disposal: .permanentDelete, applyRoute: .genericTrash,
                activityGuard: kind, reasonKey: "cleanup.risk.rebuildableCache")
        }

        let smallA = tail("Media Analysis", "com.apple.mediaanalysis", megabytes: 24)
        let smallB = tail("helpd", "com.apple.helpd", megabytes: 8,
                          guard: .reverseDNSCache)
        let smallC = tail("GeoServices", "com.apple.geod", megabytes: 57,
                          guard: .reverseDNSCache, selected: false)
        let big = tail("Google", "Google", megabytes: 7300, guard: .browser)
        let merged = CleanupCategory.mergingLongTail(
            [smallA, smallB, smallC, big], homeDirectory: home)
        try expect(merged.count == 2, "long tail did not collapse into one Other row")
        let other = try unwrap(merged.first { $0.bytes < big.bytes }, "merged tail row")
        try expect(other.name == "cleanup.group.other", "merged row lost its l10n key name")
        try expect(other.paths.count == 3 && other.bytes == (24 + 8 + 57) * 1024 * 1024,
                   "merged row does not carry every tail path and byte")
        try expect(other.selectedPathCount == 2 && !other.isPathSelected(smallC.paths[0]),
                   "merged row selection is not the union of member selections")
        try expect(other.activityGuard == .reverseDNSCache,
                   "merged guard is not the strictest member guard")

        // 不足 3 个的尾巴不合并。
        let pair = CleanupCategory.mergingLongTail([smallA, smallB, big], homeDirectory: home)
        try expect(pair.count == 3, "tail below the minimum count was merged anyway")

        // 特殊执行路线与 IM 守卫不参与合并。
        let xcodeTail = CleanupCategory(
            name: "Xcode", paths: [home + "/Library/Developer/Xcode/DerivedData/a"],
            bytes: 5, source: .xcodeCache, risk: .safe, disposal: .permanentDelete,
            applyRoute: .xcodeTrash, activityGuard: .xcode,
            reasonKey: "cleanup.risk.rebuildableCache")
        let messengerTail = CleanupCategory(
            name: "Telegram", paths: [cachePath + "ru.keepcoder.Telegram"],
            bytes: 6, source: .core, risk: .safe, disposal: .permanentDelete,
            applyRoute: .genericTrash, activityGuard: .messenger,
            reasonKey: "cleanup.risk.rebuildableCache")
        let excluded = CleanupCategory.mergingLongTail(
            [smallA, smallB, smallC, xcodeTail, messengerTail], homeDirectory: home)
        try expect(excluded.count == 3,
                   "special routes or messenger guards must never be merged")
        try expect(excluded.contains { $0.activityGuard == .messenger },
                   "messenger tail row disappeared instead of staying standalone")
        try expect(excluded.contains { $0.applyRoute == .xcodeTrash },
                   "xcode tail row disappeared instead of staying standalone")

        // 跨分桶不合并：废纸篓与缓存各自成桶。
        let trashTail = CleanupCategory(
            name: "Trash item", paths: [home + "/.Trash/old.dmg"], bytes: 3,
            source: .core, risk: .safe, disposal: .permanentDelete, applyRoute: .genericTrash,
            activityGuard: .openFile, reasonKey: "cleanup.risk.rebuildableCache")
        let bucketed = CleanupCategory.mergingLongTail(
            [smallA, smallB, smallC, trashTail], homeDirectory: home)
        try expect(bucketed.count == 2,
                   "trash tail must merge within its own bucket, not with caches")

        // 浏览器守卫并进「其他」后，执行前评估只会更保守：任一浏览器在运行
        // 就整组跳过，绝不放宽到逐路径删除。
        let browserTail = tail("Edge", "com.microsoft.edgemac", megabytes: 15,
                               guard: .browser)
        let mixedTail = CleanupCategory.mergingLongTail(
            [smallA, browserTail, smallB], homeDirectory: home)
        let mixedOther = try unwrap(mixedTail.first { $0.name == "cleanup.group.other" },
                                    "mixed tail row")
        try expect(mixedOther.activityGuard == .browser,
                   "browser member must promote the merged guard to browser")
        let runningEdge = RunningApplicationSnapshot(
            bundleIdentifiers: ["com.microsoft.edgemac"], processNames: [])
        try expect(CleanupRiskPolicy.reassess(mixedOther, running: runningEdge,
                                              homeDirectory: home).risk == .protected,
                   "running browser must protect the whole merged row")
    }

    /// 7 天门槛的边界行为：恰好到期算未活跃；差一秒算活跃；时间缺失、
    /// 未来时间都不能升级为推荐清理。
    private static func testAgePolicyBoundaries() throws {
        let retention = CleanupAgePolicy.developerRetention
        try expect(retention == 7 * 24 * 3600, "developer retention must default to 7 days")
        let now = Date()
        try expect(CleanupAgePolicy.isStale(now.addingTimeInterval(-retention), now: now,
                                         retention: retention),
               "exactly 7 days old must count as stale (inclusive boundary)")
        try expect(!CleanupAgePolicy.isStale(now.addingTimeInterval(-retention + 1), now: now,
                                          retention: retention),
               "one second short of 7 days must stay active")
        try expect(!CleanupAgePolicy.isStale(nil, now: now, retention: retention),
               "missing evidence must never be promoted to stale")
        try expect(!CleanupAgePolicy.isStale(now.addingTimeInterval(600), now: now,
                                          retention: retention),
               "future timestamps must be treated as unusable evidence")
        try expect(!CleanupAgePolicy.isStale(now.addingTimeInterval(-retention), now: now,
                                          retention: 0),
               "retention 0 means no age gating")
        // 证据组合：mtime 与 atime 取最新——任何一个显示近期活动都算活跃。
        let combined = CleanupAgePolicy.activityEvidence(
            modified: now.addingTimeInterval(-retention * 2),
            accessed: now.addingTimeInterval(-10))
        try expect(combined != nil && !CleanupAgePolicy.isStale(combined, now: now, retention: retention),
               "a fresh access inside an old tree must keep the unit active")
    }


    private static func testDisposalDecoding() throws {
        let legacy = Data("\"trash\"".utf8)
        let decoded = try JSONDecoder().decode(CleanupDisposal.self, from: legacy)
        try expect(decoded == .permanentDelete, "legacy trash disposal must decode as permanent delete")
        let encoded = String(data: try JSONEncoder().encode(CleanupDisposal.permanentDelete),
                             encoding: .utf8) ?? ""
        try expect(encoded.contains("permanentDelete"), "permanent delete must encode under its own name")
    }

    /// messenger 守卫按具体应用收窄：微信在跑不能冻结 Telegram 的缓存。
    private static func testMessengerOwnerScoping(home: String) throws {
        let telegramMedia = home + "/Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram/account-0/postbox/media"
        let telegramCategory = CleanupCategory(
            name: "Telegram Media Cache", paths: [telegramMedia], bytes: 1,
            source: .core, risk: .safe, disposal: .permanentDelete,
            applyRoute: .genericTrash, activityGuard: .messenger,
            reasonKey: "cleanup.risk.rebuildableCache")
        let weChatRunning = RunningApplicationSnapshot(
            bundleIdentifiers: ["com.tencent.xinWeChat"], processNames: [])
        try expect(CleanupRiskPolicy.reassess(telegramCategory, running: weChatRunning,
                                          homeDirectory: home).risk == .safe,
               "WeChat running must not protect Telegram's cache")
        let telegramRunning = RunningApplicationSnapshot(
            bundleIdentifiers: [], processNames: ["Telegram"])
        try expect(CleanupRiskPolicy.reassess(telegramCategory, running: telegramRunning,
                                          homeDirectory: home).risk == .protected,
               "Telegram running must still protect its own cache")
        let unknownOwner = CleanupCategory(
            name: "IM Cache", paths: [home + "/Library/Application Support/Mystery/Cache"],
            bytes: 1, source: .core, risk: .safe, disposal: .permanentDelete,
            applyRoute: .genericTrash, activityGuard: .messenger,
            reasonKey: "cleanup.risk.rebuildableCache")
        try expect(CleanupRiskPolicy.reassess(unknownOwner, running: weChatRunning,
                                          homeDirectory: home).risk == .protected,
               "unrecognizable messenger paths must fall back to whole-family protection")
    }

    private static func unwrap<T>(_ value: T?, _ name: String) throws -> T {
        guard let value else { throw RiskTestFailure(description: "missing \(name)") }
        return value
    }
}
