import Darwin
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
        exit(1)
    }
}

@main
struct CleanupScanTests {
    static func main() async throws {
        let fm = FileManager.default
        // The production policy excludes /private and /var, including the
        // macOS temporary directory. Use the script's isolated workspace home.
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: fixture) }
        let home = fixture.appendingPathComponent("home")
        func write(_ path: String, bytes: Int = 4096) throws {
            let url = home.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 97, count: bytes).write(to: url)
        }
        try write("Library/Caches/com.example.ordinary/cache")
        try write("Library/Caches/com.example.second/cache")
        try write("Library/Caches/Homebrew/downloads/package")
        try write("Library/Caches/Codex/Default/Cache/entry")
        try write("Library/Caches/Codex/Default/Cookies")
        try write("Library/Application Support/Cursor/Cache/entry")
        try write("Library/Application Support/Cursor/CachedData/entry")
        try write("Library/Application Support/Cursor/logs/entry")
        try write("Library/Application Support/Cursor/User/settings.json")
        try write(".cache/huggingface/models/weights")
        try write(".codex/sessions/history.jsonl")
        try write("Applications/Codex.app/Contents/Info.plist")
        try write("Applications/Cursor.app/Contents/Info.plist")
        try write("Library/Caches/shared-agent-storage/state_5.sqlite")
        try write("Library/Caches/shared-agent-storage/codex-tui.log")
        try write("Library/Caches/shared-agent-storage/keep.txt")
        try Data(("sqlite_home = '" + home.path + "/Library/Caches/shared-agent-storage'\n"
                  + "log_dir = '" + home.path + "/Library/Caches/shared-agent-storage'\n").utf8)
            .write(to: home.appendingPathComponent(".codex/config.toml"))
        try write(".npm/_cacache/package")
        try write(".npm/custom-data/keep")
        try write(".pnpm-store/v3/files/keep")
        try write("Library/pnpm/store/v3/files/keep")
        try write(".Trash/old.log")
        try write("Library/Application Support/Example/Cache/entry")
        try write("Library/Containers/com.example.other/Data/Library/Caches/entry")
        try write("Library/Caches/whitelisted/entry")
        try write("Library/Caches/tilde-whitelisted/entry")
        try write("Library/Caches/glob-whitelisted/entry")
        try write("Library/Caches/keep-parent/child/entry")
        // Mole parity fixtures: sandboxed tmp, IM container cache children,
        // Gradle build cache vs. module cache, firmware, Chrome CRX cache.
        try write("Library/Containers/com.apple.mediaanalysisd/Data/tmp/scratch.bin")
        try write("Library/Containers/com.tencent.xinWeChat/Data/Library/Caches/blob")
        try write(".gradle/caches/build-cache-1/entry")
        try write(".gradle/caches/modules-2/entry.jar")
        try write(".m2/repository/org/artifact.jar")
        try write("Library/iTunes/iPhone Software Updates/iPhone.ipsw")
        try write("Library/Application Support/Google/Chrome/component_crx_cache/entry")
        try write("Library/Application Support/Google/Chrome/Default/Login Data")
        // Hard-safety pattern: merged even though a user whitelist exists.
        try write("Library/Caches/CloudKit/entry")
        try write(".config/mole/whitelist", bytes: 0)
        // Same grammar Mole accepts: literal, ~, $HOME, glob, comment, and a
        // whitelisted child that must protect its parent from being offered.
        try Data(("# managed by mo clean --whitelist\n"
                  + home.path + "/Library/Caches/whitelisted\n"
                  + "~/Library/Caches/tilde-whitelisted\n"
                  + "$HOME/Library/Caches/glob-*\n"
                  + "~/Library/Caches/keep-parent/child\n").utf8)
            .write(to: home.appendingPathComponent(".config/mole/whitelist"))
        let outside = fixture.appendingPathComponent("outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data(repeating: 98, count: 8192).write(to: outside.appendingPathComponent("entry"))
        try fm.createSymbolicLink(at: home.appendingPathComponent("Library/Caches/linked"),
                                  withDestinationURL: outside)
        // Ancestor symlinks must also be rejected before profile discovery.
        try fm.createSymbolicLink(at: home.appendingPathComponent("Library/Application Support/Claude"),
                                  withDestinationURL: outside)

        let installedPresence = AgentPresenceContext(applicationDirs: [home.path + "/Applications"], searchPath: [])
        let quick = await NativeCore.shared.scanCleanup(homeDirectory: home.path, agentPresence: installedPresence)
        let quickPaths = quick.categories.flatMap(\.paths)
        // AI Agent 的缓存与会话归 Agent 专清页，磁盘清理默认流程一律不收。
        expect(!quickPaths.contains(where: {
            CleanupRiskPolicy.isAgentOwnedPath($0, homeDirectory: home.path)
        }), "agent-owned paths leaked into the default disk cleanup")
        expect(!quick.categories.contains { $0.name == "Cursor" }, "Cursor caches must move to the Agent tab")
        expect(!quick.categories.contains { $0.name == "User Caches" }, "generic cache labels hide ownership")
        expect(quick.succeeded && quick.deferredPaths.isEmpty, "quick fixture did not complete")
        expect(quickPaths.contains(home.path + "/Library/Caches/com.example.ordinary"), "ordinary cache group lost")
        expect(quickPaths.contains(home.path + "/Library/Caches/com.example.second"), "sibling cache group lost")
        expect(!quickPaths.contains { $0 == home.path + "/Library/Caches/shared-agent-storage"
                || $0.hasPrefix(home.path + "/Library/Caches/shared-agent-storage/") },
               "custom Agent storage leaked through ordinary cache parent cleanup")
        expect(!quickPaths.contains(where: { $0.hasPrefix(home.path + "/Library/Caches/Codex") }),
               "Codex caches must move to the Agent tab")
        expect(CleanupRiskPolicy.core(section: "Caches", path: home.path + "/Library/Caches/Codex",
            homeDirectory: home.path).risk == .protected, "empty-cache profile parent was not protected")
        expect(CleanupRiskPolicy.core(section: "Caches", path: home.path + "/Library/Caches/Codex/Default/Cookies",
            homeDirectory: home.path).risk == .protected, "profile cookies were not protected")
        expect(quickPaths.contains(home.path + "/.npm/_cacache"), "developer cache missing")
        expect(!quickPaths.contains(home.path + "/.npm"), "whole npm root must not be offered")
        expect(!quickPaths.contains(where: { $0.contains("/.pnpm-store") || $0.contains("/Library/pnpm/store") }), "pnpm store must not be deleted directly")
        expect(quickPaths.contains(home.path + "/.Trash/old.log"), "Trash missing")
        expect(!quickPaths.contains(where: { $0.contains("huggingface") || $0.contains("sessions")
            || $0.contains("linked") || $0.contains("whitelisted") }), "protected path admitted")
        expect(!quickPaths.contains(where: { $0.contains("tilde-whitelisted") || $0.contains("glob-whitelisted")
            || $0.contains("keep-parent") }), "Mole whitelist grammar (~, $HOME, glob, child) was not honoured")
        expect(quickPaths.contains(home.path + "/Library/Containers/com.apple.mediaanalysisd/Data/tmp/scratch.bin"),
               "sandboxed tmp child missing")
        expect(quickPaths.contains(home.path + "/Library/Containers/com.tencent.xinWeChat/Data/Library/Caches/blob")
            && !quickPaths.contains(home.path + "/Library/Containers/com.tencent.xinWeChat/Data/Library/Caches"),
               "IM container cache must be offered per child, not as the Caches root")
        expect(quickPaths.contains(home.path + "/.gradle/caches/build-cache-1"), "Gradle build cache missing")
        expect(!quickPaths.contains(where: { $0.contains("modules-2") || $0.contains("/.m2/") }),
               "dependency store offered by the native scan")
        expect(quickPaths.contains(home.path + "/Library/iTunes/iPhone Software Updates"), "device firmware missing")
        expect(quickPaths.contains(home.path + "/Library/Application Support/Google/Chrome/component_crx_cache"),
               "Chrome CRX cache missing")
        expect(!quickPaths.contains(where: { $0.contains("Login Data") }), "durable browser data offered")
        expect(!quickPaths.contains(where: { $0.contains("/CloudKit") }),
               "Mole safety whitelist (CloudKit) was not merged into a user whitelist")

        // No whitelist file: Mole's convenience defaults apply (Gradle,
        // JetBrains, Playwright), and the safety patterns still merge.
        let defaultsHome = fixture.appendingPathComponent("defaults-home")
        func writeDefaults(_ path: String) throws {
            let url = defaultsHome.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 99, count: 4096).write(to: url)
        }
        try writeDefaults("Library/Caches/com.example.ok/entry")
        try writeDefaults("Library/Caches/JetBrains/IntelliJIdea2024.1/index")
        try writeDefaults("Library/Caches/com.apple.FontRegistry/fontd/annex")
        try writeDefaults(".gradle/caches/build-cache-1/entry")
        try writeDefaults("Library/Caches/ms-playwright/chromium-1234/chrome")
        let defaults = await NativeCore.shared.scanCleanup(homeDirectory: defaultsHome.path)
        let defaultPaths = defaults.categories.flatMap(\.paths)
        expect(defaultPaths.contains(defaultsHome.path + "/Library/Caches/com.example.ok"),
               "ordinary cache lost when defaults apply")
        expect(!defaultPaths.contains(where: { $0.contains("JetBrains") || $0.contains("FontRegistry")
            || $0.contains("build-cache-1") || $0.contains("ms-playwright") }),
               "Mole default whitelist was not applied without a user whitelist file")
        for a in quickPaths {
            expect(!quickPaths.contains { $0 != a && $0.hasPrefix(a + "/") }, "overlapping scan work")
        }
        let deep = await NativeCore.shared.scanCleanup(homeDirectory: home.path, mode: .deep,
                                                     agentPresence: installedPresence)
        let deepPaths = Set(deep.categories.flatMap(\.paths))
        expect(deepPaths.isSuperset(of: quickPaths), "deep scan lost quick results")
        expect(deepPaths.contains(home.path + "/Library/Application Support/Example/Cache"), "deep support cache missing")
        // 未安装应用（含已不在废纸篓）的沙盒容器按“历史残留”整叶呈现：
        // Caches/Logs 叶子可回收，容器根与其余数据保持复核态。
        expect(deepPaths.contains(home.path + "/Library/Containers/com.example.other/Data/Library/Caches"),
               "deep orphan container cache missing")
        expect(!deepPaths.contains(home.path + "/Library/Containers/com.example.other/Data/Library/Caches/entry"),
               "orphan container cache must not be double-listed per child")

        // 数据目录不能充当安装证明。卸载后的历史与凭据进入清理页，仍须人工选择。
        let orphanHome = fixture.appendingPathComponent("agent-residual-home")
        func writeResidual(_ relative: String) throws {
            let url = orphanHome.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 4, count: 4096).write(to: url)
        }
        try writeResidual(".codex/sessions/rollout.jsonl")
        try writeResidual(".codex/auth.json")
        try writeResidual(".codex/tmp/probe.log")
        try writeResidual(".gemini/tmp/session/history.json")
        try writeResidual(".local/share/opencode/openCode.db")
        try writeResidual(".local/share/opencode/openCode.db-wal")
        try writeResidual(".local/share/opencode/log/probe.log")
        try writeResidual("Library/Application Support/Cursor/Cache/entry")
        try writeResidual("Library/Application Support/Cursor/User/history.json")
        let orphanPresence = AgentPresenceContext(applicationDirs: [orphanHome.path + "/Applications"], searchPath: [])
        let residualScan = await NativeCore.shared.scanCleanup(homeDirectory: orphanHome.path,
                                                              agentPresence: orphanPresence)
        expect(residualScan.succeeded && residualScan.deferredPaths.isEmpty,
               "isolated Agent residual scan did not complete")
        let residualRoots = [".codex", ".gemini/tmp", ".local/share/opencode",
                             "Library/Application Support/Cursor"]
        for relative in residualRoots {
            let path = orphanHome.path + "/" + relative
            let category = residualScan.categories.first { $0.paths.contains(path) }
            expect(category?.source == .appLeftover && category?.risk == .warning
                   && category?.canSelect == true && category?.selected == false
                   && category?.activityGuard == .aiAgent && category?.activityOwners.isEmpty == false,
                   "Agent residual was omitted, default-selected or lost its manual owner guard: " + relative)
        }
        expect(CleanupCategory.safeCleanupCandidates(from: residualScan.categories).isEmpty,
               "uninstalled Agent history entered quick-clean recommendations")
        expect(CleanupCategory.manualCleanupCandidates(from: residualScan.categories).count
               == residualScan.categories.count,
               "manual cleanup filtering omitted scanned Agent residuals")
        let residualDeep = await NativeCore.shared.scanCleanup(homeDirectory: orphanHome.path,
            mode: .deep, agentPresence: orphanPresence)
        let residualDeepPaths = Set(residualDeep.categories.flatMap(\.paths))
        expect(residualRoots.allSatisfy { residualDeepPaths.contains(orphanHome.path + "/" + $0) },
               "deep cache-leaf discovery displaced an entire Agent history residual")
        expect(!residualDeepPaths.contains(orphanHome.path + "/Library/Application Support/Cursor/Cache"),
               "a narrow Safe cache replaced the manually cleanable whole Agent residual")
        let cancelled = CleanupScanControl(mode: .quick)
        cancelled.cancel()
        let stopped = await NativeCore.shared.scanCleanup(homeDirectory: home.path, control: cancelled)
        expect(!stopped.succeeded && stopped.categories.isEmpty, "cancel returned a successful snapshot")
        let budget = CleanupScanControl(mode: .quick, directoryBudget: 0)
        let partial = await NativeCore.shared.scanCleanup(homeDirectory: home.path, control: budget)
        expect(!partial.deferredPaths.isEmpty && partial.categories.isEmpty, "partial sizes offered as complete")
        let missing = CleanupScanWorker.measure(fixture.appendingPathComponent("missing").path,
                                                control: CleanupScanControl(mode: .deep))
        expect(!missing.complete, "missing directory reported as a complete empty scan")

        let links = fixture.appendingPathComponent("hardlinks")
        try fm.createDirectory(at: links, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 8192).write(to: links.appendingPathComponent("first"))
        try fm.linkItem(at: links.appendingPathComponent("first"), to: links.appendingPathComponent("second"))
        try fm.createSymbolicLink(at: links.appendingPathComponent("external"), withDestinationURL: outside)
        let measured = CleanupScanWorker.measure(links.path, control: CleanupScanControl(mode: .deep))
        var directoryStat = stat()
        var fileStat = stat()
        lstat(links.path, &directoryStat)
        lstat(links.appendingPathComponent("first").path, &fileStat)
        let expected = UInt64(directoryStat.st_blocks + fileStat.st_blocks) * 512
        expect(measured.complete && measured.files == 1 && measured.bytes == expected,
               "hardlink accounting or symlink exclusion failed")

        // Enough output to exceed a pipe buffer; no real process list is read.
        let watchdog = DispatchWorkItem { exit(2) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 12, execute: watchdog)
        let output = SystemMetrics.commandOutput("/usr/bin/head", arguments: ["-c", "262144", "/dev/zero"])
        let timeoutStart = Date()
        let timedOut = SystemMetrics.commandOutput("/bin/sleep", arguments: ["10"], timeoutSeconds: 0.1)
        expect(timedOut == nil && Date().timeIntervalSince(timeoutStart) < 2, "command timeout failed")
        watchdog.cancel()
        expect(output?.utf8.count == 262144, "process output deadlocked or was truncated")

        // Repeatable, isolated throughput sample; creation time is excluded.
        let many = fixture.appendingPathComponent("many")
        try fm.createDirectory(at: many, withIntermediateDirectories: true)
        let payload = Data(repeating: 2, count: 1024)
        for index in 0..<10000 { try payload.write(to: many.appendingPathComponent("file-\(index)")) }
        let benchmark = CleanupScanControl(mode: .deep)
        let sized = CleanupScanWorker.measure(many.path, control: benchmark)
        expect(sized.complete && sized.files == 10000, "benchmark did not count all files")

        // ---- 7 天活跃门（扫描级）----
        func age(_ path: String, days: Double) throws {
            let url = home.appendingPathComponent(path)
            try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-days * 86400)],
                                 ofItemAtPath: url.path)
        }
        try write("Library/Developer/Xcode/DerivedData/ProjStale/build")
        try write("Library/Developer/Xcode/DerivedData/ProjActive/build")
        try age("Library/Developer/Xcode/DerivedData/ProjStale/build", days: 8)
        let aged = await NativeCore.shared.scanCleanup(homeDirectory: home.path)
        func category(containing path: String) -> CleanupCategory? {
            aged.categories.first { $0.paths.contains(home.path + "/" + path) }
        }
        let staleProject = category(containing: "Library/Developer/Xcode/DerivedData/ProjStale")
        let activeProject = category(containing: "Library/Developer/Xcode/DerivedData/ProjActive")
        expect(staleProject != nil
               && staleProject!.isPathSelected(home.path + "/Library/Developer/Xcode/DerivedData/ProjStale"),
               "8-day-old project build output should be recommended")
        expect(activeProject != nil
               && !activeProject!.isPathSelected(home.path + "/Library/Developer/Xcode/DerivedData/ProjActive"),
               "recently active project must stay visible but unselected")
        expect(activeProject?.reasonKey == "cleanup.risk.recentlyActive",
               "active entries must explain the 7-day retention reason")
        let npmCache = category(containing: ".npm/_cacache")
        expect(npmCache != nil && !npmCache!.isPathSelected(home.path + "/.npm/_cacache"),
               "npm cache written moments ago must not be default-selected")

        // ---- 执行前复核：扫描后重新活跃的单元必须被跳过 ----
        try fm.setAttributes([.modificationDate: Date()],
                             ofItemAtPath: home.appendingPathComponent(
                                "Library/Developer/Xcode/DerivedData/ProjStale/build").path)
        let recheckControl = CleanupScanControl(mode: .deep)
        let recheck = CleanupScanWorker.measure(
            home.appendingPathComponent("Library/Developer/Xcode/DerivedData/ProjStale").path,
            control: recheckControl)
        expect(!recheck.complete || !CleanupAgePolicy.isStale(
            recheck.activityEvidence, retention: CleanupAgePolicy.developerRetention),
            "entry touched after the scan must fail the apply-time re-check")

        // ---- 自定义缓存位置（GRADLE_USER_HOME / npmrc cache=）----
        try write(".gradle-custom/caches/build-cache-9/entry")
        try write(".gradle-custom/caches/modules-2/dependency.jar")
        try age(".gradle-custom/caches/build-cache-9/entry", days: 9)
        try Data("cache=\(home.path)/.npm-custom\n".utf8).write(
            to: home.appendingPathComponent(".npmrc"))
        let located = DeveloperCacheLocations.resolve(
            home: home.path, environment: [:], readText: { path in
                path == home.path + "/.npmrc"
                    ? "cache=\(home.path)/.npm-custom\n" : nil
            })
        expect(located.gradleUserHome == nil, "gradle home must come from the environment only")
        DeveloperCacheLocations.override = DeveloperCacheLocations(
            npmCache: located.npmCache, yarnCache: nil, pipCache: nil,
            gradleUserHome: home.path + "/.gradle-custom", cargoHome: nil,
            goModCache: nil, goBuildCache: nil, xdgCacheHome: nil, poetryCache: nil)
        defer { DeveloperCacheLocations.override = nil }
        expect(CleanupRiskPolicy.isGradleBuildCachePath(
            home.path + "/.gradle-custom/caches/build-cache-9", home: home.path),
            "custom GRADLE_USER_HOME build cache must classify as rebuildable")
        expect(CleanupRiskPolicy.dependencyStoreRoots(home: home.path)
            .contains(home.path + "/.gradle-custom/caches"),
            "custom gradle module cache must stay review-only")
        let customScan = await NativeCore.shared.scanCleanup(homeDirectory: home.path)
        let customPaths = Set(customScan.categories.flatMap(\.paths))
        expect(customPaths.contains(home.path + "/.gradle-custom/caches/build-cache-9"),
               "custom gradle build cache missing from discovery")
        expect(!customPaths.contains(where: { $0.contains("gradle-custom/caches/modules-2") }),
               "custom gradle dependency store must not be offered")
        expect(CleanupRiskPolicy.core(section: "Cache", path: home.path + "/.npm-custom",
                                      homeDirectory: home.path).risk == .safe,
               "npmrc cache= location must be recognized by the policy")

        // ---- 词法校验（删除漏斗第一道）----
        expect(DeletionPlan.isLexicallySafePath(home.path + "/Library/Caches/ok")
            && DeletionPlan.isLexicallySafePath(home.path + "/Downloads/name..files"),
               "normal absolute paths (including `name..files`) must pass lexical checks")
        expect(!DeletionPlan.isLexicallySafePath("relative/path"),
               "relative paths must be rejected")
        expect(!DeletionPlan.isLexicallySafePath(home.path + "/Caches/\(Character(unicodeScalarLiteral: "\u{07}"))bad"),
               "control characters must be rejected")
        expect(!DeletionPlan.isLexicallySafePath(home.path + "/Caches/../Keychains"),
               "dot-dot path components must be rejected")
        expect(!DeletionPlan.isLexicallySafePath(""),
               "empty paths must be rejected")

        // ---- fd 链永久删除：身份一致才删、内部符号链接只删链接本身 ----
        let secureTree = home.appendingPathComponent("Library/Caches/secure-tree")
        try fm.createDirectory(at: secureTree.appendingPathComponent("inner"),
                               withIntermediateDirectories: true)
        try Data(repeating: 5, count: 4096).write(to: secureTree.appendingPathComponent("inner/file"))
        let outsideKeep = fixture.appendingPathComponent("outside-keep")
        try fm.createDirectory(at: outsideKeep, withIntermediateDirectories: true)
        try Data(repeating: 6, count: 4096).write(to: outsideKeep.appendingPathComponent("precious"))
        try fm.createSymbolicLink(at: secureTree.appendingPathComponent("inner/link"),
                                  withDestinationURL: outsideKeep)
        let securePlan = DeletionPlan(paths: [secureTree.path])
        let secureSummary = NativeCore.shared.applyCleanup(
            items: securePlan.items, permanent: true, homeDirectory: home.path)
        expect(secureSummary.removed == 1 && secureSummary.failed == 0,
               "secure removal of an identity-matching tree failed")
        expect(!fm.fileExists(atPath: secureTree.path),
               "identity-matching tree was not removed")
        expect(fm.fileExists(atPath: outsideKeep.appendingPathComponent("precious").path),
               "internal symlink must be unlinked without following it")

        // 身份不符（mtime 已变化）→ 跳过且目录保留。
        let tampered = home.appendingPathComponent("Library/Caches/tampered")
        try fm.createDirectory(at: tampered, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 4096).write(to: tampered.appendingPathComponent("file"))
        let tamperedPlan = DeletionPlan(paths: [tampered.path])
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-60)],
                             ofItemAtPath: tampered.path)
        expect(DeletionPlan.identity(at: tampered.path) != tamperedPlan.items[0].identity,
               "fixture should produce a changed identity for the tamper case")
        let tamperedSummary = NativeCore.shared.applyCleanup(
            items: tamperedPlan.items, permanent: true, homeDirectory: home.path)
        expect(tamperedSummary.skipped >= 1 && tamperedSummary.removed == 0,
               "changed identity must be skipped, not deleted")
        expect(fm.fileExists(atPath: tampered.path), "tampered tree must survive")

        // 父目录链上的符号链接：fd 链拒绝跟随，删除失败且真实目录保留。
        let realParent = home.appendingPathComponent("Library/Caches/real-parent")
        try fm.createDirectory(at: realParent.appendingPathComponent("target"),
                               withIntermediateDirectories: true)
        try Data(repeating: 8, count: 4096).write(
            to: realParent.appendingPathComponent("target/file"))
        try fm.createSymbolicLink(at: home.appendingPathComponent("Library/Caches/link-parent"),
                                  withDestinationURL: realParent)
        let throughLink = DeletionPlan(
            paths: [home.path + "/Library/Caches/link-parent/target"])
        let linkSummary = NativeCore.shared.applyCleanup(
            items: throughLink.items, permanent: true, homeDirectory: home.path)
        expect(linkSummary.removed == 0,
               "a path through a symlinked parent must never be deleted")
        expect(fm.fileExists(atPath: realParent.appendingPathComponent("target/file").path),
               "the real target behind the symlinked parent must survive")

        // 内容相关删除必须在运行态探测后仍可否决，不能绕过最后一道校验。
        let finalGuardFile = home.appendingPathComponent("Downloads/final-guard.txt")
        try fm.createDirectory(at: finalGuardFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("reviewed duplicate".utf8).write(to: finalGuardFile)
        let finalGuardPlan = DeletionPlan(paths: [finalGuardFile.path])
        var finalGuardCalled = false
        let guardedSummary = NativeCore.shared.applyCleanup(
            items: finalGuardPlan.items, permanent: false, homeDirectory: home.path,
            finalValidation: { path in
                finalGuardCalled = path == finalGuardFile.path
                return false
            })
        expect(finalGuardCalled && guardedSummary.removed == 0 && guardedSummary.skipped == 1,
               "final content validation must be called and prevent Trash")
        expect(fm.fileExists(atPath: finalGuardFile.path), "final-validation rejection must preserve the file")

        print(String(format: "PASS: catalog, grouping, deep scan, manual Agent residuals, exclusions, cancellation, partial sizes, hardlinks, pipe output, 7-day gate, custom locations, lexical guards, secure fd-walk deletion; 10000 files in %.3fs", benchmark.elapsed))
        print(quick.diagnostics)
        print(deep.diagnostics)
        print(aged.diagnostics)
    }
}
