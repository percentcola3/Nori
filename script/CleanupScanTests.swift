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
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
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

        let quick = await NativeCore.shared.scanCleanup(homeDirectory: home.path)
        let quickPaths = quick.categories.flatMap(\.paths)
        let cursor = quick.categories.filter { $0.name == "Cursor" }
        expect(cursor.count == 1 && cursor[0].paths.count == 3, "Cursor cache leaves must share one policy-preserving group")
        expect(!quick.categories.contains { $0.name == "User Caches" }, "generic cache labels hide ownership")
        expect(quick.succeeded && quick.deferredPaths.isEmpty, "quick fixture did not complete")
        expect(quickPaths.contains(home.path + "/Library/Caches/com.example.ordinary"), "ordinary cache group lost")
        expect(quickPaths.contains(home.path + "/Library/Caches/com.example.second"), "sibling cache group lost")
        expect(quickPaths.contains(home.path + "/Library/Caches/Codex/Default/Cache"), "AI cache missing")
        expect(!quickPaths.contains(home.path + "/Library/Caches/Codex"), "AI profile parent offered")
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
        let deep = await NativeCore.shared.scanCleanup(homeDirectory: home.path, mode: .deep)
        let deepPaths = Set(deep.categories.flatMap(\.paths))
        expect(deepPaths.isSuperset(of: quickPaths), "deep scan lost quick results")
        expect(deepPaths.contains(home.path + "/Library/Application Support/Example/Cache"), "deep support cache missing")
        expect(deepPaths.contains(home.path + "/Library/Containers/com.example.other/Data/Library/Caches/entry"),
               "deep container cache missing")
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
        print(String(format: "PASS: catalog, grouping, deep scan, exclusions, cancellation, partial sizes, hardlinks, pipe output; 10000 files in %.3fs", benchmark.elapsed))
        print(quick.diagnostics)
        print(deep.diagnostics)
    }
}
