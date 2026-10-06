import AppKit
import Darwin
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
        exit(1)
    }
}

private final class ScanProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [CleanupScanProgressEvent] = []
    func record(_ event: CleanupScanProgressEvent) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(event)
    }
    var events: [CleanupScanProgressEvent] {
        lock.lock(); defer { lock.unlock() }
        return recorded
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
        func allocatedBytes(_ path: String) -> UInt64 {
            var metadata = stat()
            expect(lstat(path, &metadata) == 0, "could not size allocated fixture bytes")
            return UInt64(max(0, metadata.st_blocks)) * 512
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
        // 端侧 AI 模型（Chrome/Edge/Brave 三个审计过的 profile 根）、
        // 更新器下载缓存，以及应归 Agent 页的 codex 环境缓存。
        try write("Library/Application Support/Google/Chrome/OptGuideOnDeviceModel/data.dat")
        try write("Library/Application Support/Google/Chrome/OptGuideOnDeviceClassifierModel/data.dat")
        try write("Library/Application Support/Google/Chrome/optimization_guide_model_store/data.dat")
        try write("Library/Application Support/Microsoft Edge/OptGuideOnDeviceModel/data.dat")
        try write("Library/Application Support/BraveSoftware/Brave-Browser/OptGuideOnDeviceModel/data.dat")
        try write("Library/Application Support/Google/GoogleUpdater/crx_cache/package.crx")
        try write("Library/Application Support/Microsoft/EdgeUpdater/crx_cache/package.crx")
        try write("Library/Application Support/Google/Chrome/Default/Preferences")
        try write(".cache/codex-blender/blender-4.5.9-macos-arm64.dmg")
        try write(".cache/codex-runtimes/codex-runtime-install-jnYG91/stage")
        // Hard-safety pattern: merged even though a user whitelist exists.
        try write("Library/Caches/CloudKit/entry")
        // Nori 自身存储：可再生缓存树、过期原子写孤儿，与必须受保护的
        // 密钥/备份/剪贴板/会话/搜索索引。
        try write("Library/Application Support/Nori/DirectorySizes/state.json")
        try write("Library/Application Support/Nori/Analysis/disk.json")
        try write("Library/Application Support/Nori/Analysis/duplicates.plist")
        try write("Library/Application Support/Nori/signing/identity.p12")
        try write("Library/Application Support/Nori/Backups/backup")
        try write("Library/Application Support/Nori/clipboard-history.plist")
        try write("Library/Application Support/Nori/DirectoryIndex/files.sqlite")
        try write("Library/Application Support/Nori/state.json.sb-orphan")
        let noriOrphan = home.appendingPathComponent(
            "Library/Application Support/Nori/state.json.sb-orphan").path
        let agedSeconds = Int(Date().addingTimeInterval(-2 * 3600).timeIntervalSince1970)
        var agedTimes = [timeval(tv_sec: agedSeconds, tv_usec: 0),
                         timeval(tv_sec: agedSeconds, tv_usec: 0)]
        expect(utimes(noriOrphan, &agedTimes) == 0, "could not age the Nori orphan fixture")
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
        expect(quickPaths.contains(home.path + "/Library/Application Support/Cursor/Cache"), "audited Cursor cache missing")
        expect(!quick.categories.contains { $0.name == "User Caches" }, "generic cache labels hide ownership")
        expect(quick.succeeded && quick.deferredPaths.isEmpty, "quick fixture did not complete")
        expect(quickPaths.contains(home.path + "/Library/Caches/com.example.ordinary"), "ordinary cache group lost")
        expect(quickPaths.contains(home.path + "/Library/Caches/com.example.second"), "sibling cache group lost")
        expect(!quickPaths.contains { $0 == home.path + "/Library/Caches/shared-agent-storage"
                || $0.hasPrefix(home.path + "/Library/Caches/shared-agent-storage/") },
               "custom Agent storage leaked through ordinary cache parent cleanup")
        expect(quickPaths.contains(home.path + "/Library/Caches/Codex/Default/Cache")
            && !quickPaths.contains(home.path + "/Library/Caches/Codex/Default/Cookies"),
               "Codex exact cache leaf missing or durable profile state included")
        expect(CleanupRiskPolicy.core(section: "Caches", path: home.path + "/Library/Caches/Codex",
            homeDirectory: home.path).risk == .protected, "empty-cache profile parent was not protected")
        expect(CleanupRiskPolicy.core(section: "Caches", path: home.path + "/Library/Caches/Codex/Default/Cookies",
            homeDirectory: home.path).risk == .protected, "profile cookies were not protected")
        expect(quickPaths.contains(home.path + "/.npm/_cacache"), "developer cache missing")
        expect(!quickPaths.contains(home.path + "/.npm"), "whole npm root must not be offered")
        expect(quickPaths.contains(where: { $0.contains("/.pnpm-store") || $0.contains("/Library/pnpm/store") }), "pnpm content-addressed store missing")
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
        expect(quickPaths.contains(home.path + "/Library/Application Support/Google/Chrome/OptGuideOnDeviceModel")
            && quickPaths.contains(home.path + "/Library/Application Support/Google/Chrome/OptGuideOnDeviceClassifierModel")
            && quickPaths.contains(home.path + "/Library/Application Support/Google/Chrome/optimization_guide_model_store"),
               "Chrome on-device model caches missing")
        expect(quickPaths.contains(home.path + "/Library/Application Support/Microsoft Edge/OptGuideOnDeviceModel")
            && quickPaths.contains(home.path + "/Library/Application Support/BraveSoftware/Brave-Browser/OptGuideOnDeviceModel"),
               "Edge/Brave on-device model caches missing")
        expect(quickPaths.contains(home.path + "/Library/Application Support/Google/GoogleUpdater/crx_cache")
            && quickPaths.contains(home.path + "/Library/Application Support/Microsoft/EdgeUpdater/crx_cache"),
               "updater component caches missing")
        expect(!quickPaths.contains(where: { $0.contains("/Google/Chrome/Default") }),
               "protected browser profile data offered")
        expect(!quickPaths.contains(where: { $0.contains("codex-blender") || $0.contains("codex-runtimes") }),
               "agent-owned Codex runtime caches leaked into the junk scan")
        expect(!quickPaths.contains(where: { $0.contains("/CloudKit") }),
               "Mole safety whitelist (CloudKit) was not merged into a user whitelist")
        // Nori 自身可再生缓存归 "Nori" 类目；密钥、备份、剪贴板、搜索索引
        // 永不进入原生候选。
        let noriSupport = home.path + "/Library/Application Support/Nori"
        let noriCategory = quick.categories.first {
            $0.name == NoriOwnedStorage.displayName && $0.source == .core
        }
        let noriPaths = Set(noriCategory?.paths ?? [])
        expect(noriPaths.contains(noriSupport + "/DirectorySizes"),
               "Nori size cache root missing from the Nori category")
        expect(noriPaths.contains(noriSupport + "/Analysis"),
               "Nori analysis inventory missing from the Nori category")
        expect(noriPaths.contains(noriOrphan),
               "aged .sb- orphan missing from the Nori category")
        expect(!quickPaths.contains(where: {
            $0.contains("/Nori/signing") || $0.contains("/Nori/release-signing")
                || $0.contains("/Nori/update-signing") || $0.contains("/Nori/Backups")
                || $0.contains("clipboard-history") || $0.contains("/Nori/DirectoryIndex")
                || $0.contains("traffic-") && $0.contains("/Nori/")
        }), "durable or managed Nori content was offered to the native scan")

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
            || $0.contains("build-cache-1") }),
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

        // Uninstalled Agent data includes user history and credentials; the
        // ordinary junk scan must not offer it under an orphan-data label.
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
        expect(residualScan.categories.flatMap(\.paths).allSatisfy {
            $0 == orphanHome.path + "/Library/Application Support/Cursor/Cache"
        } && !residualScan.categories.isEmpty, "uninstalled Agent data entered junk scan outside audited cache")
        let residualDeep = await NativeCore.shared.scanCleanup(homeDirectory: orphanHome.path,
            mode: .deep, agentPresence: orphanPresence)
        expect(residualDeep.categories.flatMap(\.paths).allSatisfy {
            $0 == orphanHome.path + "/Library/Application Support/Cursor/Cache"
        }, "deep scan admitted Agent data outside audited cache")

        // 真实账户 T/X 目录的只读预检：用户 T/C 子项 24 小时门槛生效，
        // X 只认 *.code_sign_clone。夹具建在真实 T/X 下，用完即删，
        // 验证只走到 preflight，不触发任何删除。
        var confBytes = [CChar](repeating: 0, count: 4096)
        expect(confstr(_CS_DARWIN_USER_TEMP_DIR, &confBytes, confBytes.count) > 0,
               "account temp root unavailable")
        let realT = CleanupRiskPolicy.canonicalOpenFilePath(String(cString: confBytes))
        let freshTDir = realT + "/nori-scan-fresh-" + UUID().uuidString
        let staleTDir = realT + "/nori-scan-stale-" + UUID().uuidString
        let xDir = (realT as NSString).deletingLastPathComponent + "/X"
        let cloneDir = xDir + "/nori-scan-" + UUID().uuidString + ".code_sign_clone"
        let plainDir = xDir + "/nori-scan-" + UUID().uuidString + "-plain"
        for dir in [freshTDir, staleTDir, cloneDir, plainDir] {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try Data(repeating: 97, count: 128).write(to: URL(fileURLWithPath: dir + "/payload"))
        }
        defer { for dir in [freshTDir, staleTDir, cloneDir, plainDir] { try? fm.removeItem(atPath: dir) } }
        let freshDate = Date().addingTimeInterval(-23 * 3600)
        let staleDate = Date().addingTimeInterval(-25 * 3600)
        for (dir, date) in [(freshTDir, freshDate), (staleTDir, staleDate)] {
            for path in [dir, dir + "/payload"] {
                // atime 与 mtime 都要超过保留期才算可回收，POSIX utimes 同时设置。
                let seconds = Int(date.timeIntervalSince1970)
                var times = [timeval(tv_sec: seconds, tv_usec: 0),
                             timeval(tv_sec: seconds, tv_usec: 0)]
                expect(utimes(path, &times) == 0, "could not age fixture " + path)
            }
        }
        let systemCore = NativeCore(cleanupOpenFileProbe: { [] })
        let systemCategory = CleanupCategory(name: "System", paths: [freshTDir, staleTDir, cloneDir, plainDir],
            bytes: 0, selected: true, source: .core, risk: .safe, disposal: .permanentDelete,
            applyRoute: .genericTrash, activityGuard: .openFile,
            reasonKey: "cleanup.risk.temporaryFile")
        let systemChecked = systemCore.preflightCleanupCategories([systemCategory],
            homeDirectory: home.path)
        expect(systemChecked.succeeded, "system preflight failed")
        let systemOffered = Set(systemChecked.categories.flatMap(\.paths))
        expect(systemOffered.contains(staleTDir), "25h user-T child blocked by the 24h gate")
        expect(!systemOffered.contains(freshTDir), "23h user-T child offered past the 24h gate")
        expect(systemOffered.contains(cloneDir), "code-sign clone blocked")
        expect(!systemOffered.contains(plainDir), "non-clone X child offered")
        expect(!systemChecked.administratorRequiredPaths.contains(cloneDir),
               "user-owned code-sign clone must not require administrator")

        // 统一日志子目录是保留壳：预检只产出直接子级 *.tracev3，目录本身
        // 永不成项（无论其 mtime 多旧）；伪造的目录条目在 apply 层被跳过，
        // 不会 rmdir。对真实目录做只读预检，不执行任何删除。
        let diagnosticsCore = NativeCore(cleanupOpenFileProbe: { [] })
        let diagnosticsCategory = CleanupCategory(name: "Unified Logs",
            paths: CleanupRiskPolicy.unifiedLogDirectories.sorted(),
            bytes: 0, selected: true, source: .core, risk: .safe,
            disposal: .permanentDelete, applyRoute: .genericTrash,
            activityGuard: .openFile, reasonKey: "cleanup.risk.unifiedLog")
        let diagnosticsChecked = diagnosticsCore.preflightCleanupCategories(
            [diagnosticsCategory], homeDirectory: home.path,
            includingAdministratorRequired: true)
        let diagnosticsOffered = diagnosticsChecked.categories.flatMap(\.paths)
        expect(diagnosticsOffered.allSatisfy {
            $0.hasSuffix(".tracev3")
                && CleanupRiskPolicy.unifiedLogDirectories.contains(
                    ($0 as NSString).deletingLastPathComponent)
        }, "unified log scan must only offer direct *.tracev3 children")
        expect(!diagnosticsOffered.contains { CleanupRiskPolicy.isUnifiedLogDirectory($0) },
               "diagnostics container directory offered as a deletable entry")
        let shellPath = "/private/var/db/diagnostics/Persist"
        let forgedShell = NativeCore(cleanupOpenFileProbe: { [] }).applyCleanup(
            items: [DeletionPlan.Item(record: shellPath,
                                      identity: DeletionPlan.identity(at: shellPath) ?? "")],
            permanent: true, homeDirectory: home.path)
        expect(forgedShell.removed == 0 && forgedShell.failed == 0
               && forgedShell.skipped == 1
               && forgedShell.messages.contains { $0.contains("retained diagnostics") }
               && fm.fileExists(atPath: shellPath),
               "forged diagnostics container item must be refused without deletion")

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
        let scanHardlinkHome = fixture.appendingPathComponent("scan-hardlink-home")
        let scanHardlinkRoot = scanHardlinkHome.appendingPathComponent("Library/Caches/hardlinks")
        try fm.createDirectory(at: scanHardlinkRoot, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 8192).write(to: scanHardlinkRoot.appendingPathComponent("first"))
        try fm.linkItem(at: scanHardlinkRoot.appendingPathComponent("first"),
                        to: scanHardlinkRoot.appendingPathComponent("second"))
        let hardlinkScan = await NativeCore(cleanupOpenFileProbe: { [] }).scanCleanup(
            homeDirectory: scanHardlinkHome.path)
        expect(hardlinkScan.categories.first?.pathBytes[scanHardlinkRoot.path]
               == CleanupScanWorker.measure(scanHardlinkRoot.path, control: .init(mode: .deep)).bytes,
               "whole-subtree preflight counted allocated hardlink bytes twice")
        let hardlinkBytes = allocatedBytes(scanHardlinkRoot.appendingPathComponent("first").path)
        let hardlinkRemoval = NativeCore(cleanupOpenFileProbe: { [] }).applyCleanup(
            items: DeletionPlan(paths: [scanHardlinkRoot.path]).items, permanent: true,
            homeDirectory: scanHardlinkHome.path)
        expect(hardlinkRemoval.reclaimedBytes == hardlinkBytes,
               "deleting a hardlink family must count allocated bytes only at its last link")

        // 废纸篓顶层条目是用户已丢弃的整体：.app、框架符号链接与内置 SQLite
        // 都不再阻止整体计量与删除；同样结构放在 Caches 下仍受内容保护。
        let trashHome = fixture.appendingPathComponent("trash-home")
        let trashedApp = trashHome.appendingPathComponent(".Trash/Old.app")
        let frameworkVersions = trashedApp.appendingPathComponent("Contents/Frameworks/Kit.framework/Versions")
        try fm.createDirectory(at: frameworkVersions.appendingPathComponent("A"), withIntermediateDirectories: true)
        try Data(repeating: 3, count: 16384).write(to: frameworkVersions.appendingPathComponent("A/Kit"))
        try fm.createSymbolicLink(atPath: frameworkVersions.appendingPathComponent("Current").path,
                                  withDestinationPath: "A")
        try (Data("SQLite format 3\0".utf8) + Data(repeating: 0, count: 4080))
            .write(to: trashedApp.appendingPathComponent("Contents/Resources.sqlite"))
        let cachedApp = trashHome.appendingPathComponent("Library/Caches/com.example.bundled/Inner.app")
        try fm.createDirectory(at: cachedApp.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try Data(repeating: 4, count: 4096).write(to: cachedApp.appendingPathComponent("Contents/Info.plist"))
        let trashScan = await NativeCore(cleanupOpenFileProbe: { [] }).scanCleanup(homeDirectory: trashHome.path)
        let trashPaths = trashScan.categories.flatMap(\.paths)
        let trashBytes = trashScan.categories.compactMap { $0.pathBytes[trashedApp.path] }.first ?? 0
        expect(trashPaths.contains(trashedApp.path) && trashBytes >= 16384,
               "a trashed app bundle with symlinks and SQLite must be offered as one measured entry")
        expect(!trashPaths.contains { $0.hasPrefix(trashedApp.path + "/") },
               "a trashed app bundle must not be split into protected fragments")
        expect(!trashPaths.contains { $0.hasPrefix(cachedApp.path) },
               "app bundles outside the Trash keep content protection")
        let trashRemoval = NativeCore(cleanupOpenFileProbe: { [] }).applyCleanup(
            items: DeletionPlan(paths: [trashedApp.path]).items, permanent: true,
            homeDirectory: trashHome.path)
        expect(trashRemoval.removed == 1 && trashRemoval.failed == 0 && !fm.fileExists(atPath: trashedApp.path),
               "emptying a trashed app bundle failed: \(trashRemoval.messages)")
        let cachedRemoval = NativeCore(cleanupOpenFileProbe: { [] }).applyCleanup(
            items: DeletionPlan(paths: [cachedApp.path]).items, permanent: true,
            homeDirectory: trashHome.path)
        expect(cachedRemoval.removed == 0 && fm.fileExists(atPath: cachedApp.path),
               "an app bundle outside the Trash was deleted")
        // SwiftUI 拖拽临时副本目录同样整体丢弃。
        let dragRoot = trashHome.appendingPathComponent("Library/Caches/com.apple.SwiftUI.Drag-0000-TEST")
        let dragApp = dragRoot.appendingPathComponent("Nori.app/Contents")
        try fm.createDirectory(at: dragApp, withIntermediateDirectories: true)
        try Data(repeating: 6, count: 8192).write(to: dragApp.appendingPathComponent("Info.plist"))
        let dragScan = await NativeCore(cleanupOpenFileProbe: { [] }).scanCleanup(homeDirectory: trashHome.path)
        expect(dragScan.categories.flatMap(\.paths).contains(dragRoot.path),
               "a SwiftUI drag copy directory must be offered as one entry")
        let dragRemoval = NativeCore(cleanupOpenFileProbe: { [] }).applyCleanup(
            items: DeletionPlan(paths: [dragRoot.path]).items, permanent: true, homeDirectory: trashHome.path)
        expect(dragRemoval.removed == 1 && !fm.fileExists(atPath: dragRoot.path),
               "removing a SwiftUI drag copy failed: \(dragRemoval.messages)")

        // 微信 4.x：cache/temp 默认勾选，聊天图片/视频默认不勾选，消息库、
        // 聊天文件与共享目录受保护；三者归入通讯工具分组。
        let wechatHome = fixture.appendingPathComponent("wechat-home")
        let account = wechatHome.appendingPathComponent(WeChatStorage.filesRelativeRoot + "/wxid_test_ab12")
        for relative in ["cache/c1", "temp/t1", "msg/video/v1.mp4", "msg/attach/a/1.dat",
                         "msg/file/report.pdf", "db_storage/message/message_0.db", "config/conf"] {
            let url = account.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 7, count: 8192).write(to: url)
        }
        let shared = wechatHome.appendingPathComponent(WeChatStorage.filesRelativeRoot + "/all_users/login/key")
        try fm.createDirectory(at: shared.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 8, count: 8192).write(to: shared)
        let wechatScan = await NativeCore(cleanupOpenFileProbe: { [] }).scanCleanup(homeDirectory: wechatHome.path)
        let wechat = wechatScan.categories.filter { $0.name.hasPrefix("WeChat") }
        let wechatPaths = Set(wechat.flatMap(\.paths))
        expect(wechatPaths == Set(["cache", "temp", "msg/video", "msg/attach"].map { account.appendingPathComponent($0).path }),
               "WeChat leaves mismatch: \(wechatPaths.sorted())")
        expect(!wechatScan.categories.flatMap(\.paths).contains { $0.contains("db_storage") || $0.contains("msg/file")
            || $0.contains("all_users") || $0.contains("/config") }, "protected WeChat data was offered")
        let media = wechat.filter { $0.reasonKey == WeChatStorage.mediaReasonKey }
        let caches = wechat.filter { $0.reasonKey == WeChatStorage.cacheReasonKey }
        expect(media.count == 2 && media.allSatisfy { $0.selectedPaths.isEmpty }
               && media.compactMap(\.safeCleanupCandidate).allSatisfy { $0.selectedPaths.isEmpty },
               "WeChat chat media must stay unselected by default")
        expect(caches.count == 1 && caches.allSatisfy(\.allSelected), "WeChat cache must be selected by default")
        expect(wechat.allSatisfy { CleanupGroupBucket(category: $0, homeDirectory: wechatHome.path) == .messenger }
               && CleanupCategory.mergingLongTail(wechat, homeDirectory: wechatHome.path).count == wechat.count,
               "WeChat categories must form the messaging group and never merge into the long tail")

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

        // Exercise the real secure scan (not just the size-only walker), with
        // parallel roots and nested progress while a large root is unfinished.
        let progressHome = fixture.appendingPathComponent("progress-home")
        for group in 0..<4 {
            let root = progressHome.appendingPathComponent("Library/Caches/com.example.group\(group)")
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            for file in 0..<1000 { try payload.write(to: root.appendingPathComponent("file-\(file)")) }
        }
        let recorder = ScanProgressRecorder()
        let secureBegan = Date()
        let secureScan = await NativeCore(cleanupOpenFileProbe: { [] }).scanCleanup(
            homeDirectory: progressHome.path, progress: .init(handler: recorder.record), mode: .deep)
        let secureSeconds = Date().timeIntervalSince(secureBegan)
        let events = recorder.events
        expect(secureScan.succeeded && secureScan.deferredPaths.isEmpty
               && secureScan.categories.count == 4 && secureScan.completedRoots.count == 4,
               "bounded parallel scan lost a complete fixture root")
        expect(events.contains { $0.phase == "discovery" }
               && events.contains { $0.phase == "occupancy" }
               && events.contains { $0.phase == "native" && $0.completed == 0 && $0.total == 4 }
               && events.contains { $0.phase == "native" && $0.completed == 4 && $0.total == 4 },
               "scan progress must include discovery, occupancy, start and completion")
        expect(events.contains { $0.currentPath.contains("/file-") && $0.completed < $0.total },
               "a large scan must report the current file before its root finishes")
        let carriedRoot = progressHome.appendingPathComponent("Library/Caches/com.example.group0").path
        let continued = await NativeCore(cleanupOpenFileProbe: { [] }).scanCleanup(
            homeDirectory: progressHome.path, mode: .deep, excludingScannedRoots: [carriedRoot])
        expect(continued.categories.count == 3
               && !continued.categories.flatMap(\.paths).contains { $0 == carriedRoot || $0.hasPrefix(carriedRoot + "/") },
               "deep continuation remeasured a root whose results are already carried")
        expect(partial.completedRoots.isEmpty, "an unfinished root was certified complete for continuation")
        print(String(format: "Secure scan: 4000 files across four roots in %.3fs; nested progress and selective continuation passed", secureSeconds))

        // Completed roots are literal paths rather than whitelist glob rules.
        // A carried descendant must also keep its parent out of the new plan,
        // while unrelated siblings remain discoverable with many carried roots.
        let continuationHome = fixture.appendingPathComponent("continuation-home")
        let continuationCache = continuationHome.appendingPathComponent("Library/Caches")
        let carriedLiteral = continuationCache.appendingPathComponent("com.example.cache[1]")
        let unrelatedLiteral = continuationCache.appendingPathComponent("com.example.cache1")
        let prefixSibling = continuationCache.appendingPathComponent("com.example.cache[1]-sibling")
        let mixedParent = continuationCache.appendingPathComponent("com.example.mixed")
        let carriedChild = mixedParent.appendingPathComponent("already-scanned")
        let remainingChild = mixedParent.appendingPathComponent("remaining")
        for root in [carriedLiteral, unrelatedLiteral, prefixSibling, carriedChild, remainingChild] {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            try payload.write(to: root.appendingPathComponent("entry"))
        }
        var carriedRoots = Set((0..<600).map {
            continuationCache.appendingPathComponent("com.example.completed\($0)").path
        })
        carriedRoots.formUnion([carriedLiteral.path, carriedChild.path])
        let literalContinuation = await NativeCore(cleanupOpenFileProbe: { [] }).scanCleanup(
            homeDirectory: continuationHome.path, mode: .deep, excludingScannedRoots: carriedRoots)
        expect(Set(literalContinuation.categories.flatMap(\.paths))
               == Set([unrelatedLiteral.path, prefixSibling.path, remainingChild.path]),
               "continuation treated a literal root as a glob, covered a carried child, or excluded a sibling")

        // ---- 7 天活跃门（扫描级）----
        func age(_ path: String, days: Double) throws {
            let url = home.appendingPathComponent(path)
            try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-days * 86400)],
                                 ofItemAtPath: url.path)
        }
        try write("Library/Developer/Xcode/DerivedData/ProjStale/build")
        try write("Library/Developer/Xcode/DerivedData/ProjActive/build")
        try age("Library/Developer/Xcode/DerivedData/ProjStale/build", days: 8)
        // Reading directory entries may change a directory's atime, but the
        // scanner captures regular-file activity before its SQLite header probe.
        let oldSeconds = Int(Date().addingTimeInterval(-8 * 86400).timeIntervalSince1970)
        var oldTimes = [timeval(tv_sec: oldSeconds, tv_usec: 0),
                        timeval(tv_sec: oldSeconds, tv_usec: 0)]
        let staleBuild = home.appendingPathComponent("Library/Developer/Xcode/DerivedData/ProjStale/build")
        expect(utimes(staleBuild.path, &oldTimes) == 0, "could not prepare old access-time evidence")
        let staleRoot = staleBuild.deletingLastPathComponent().path
        let evidenceBefore = CleanupScanWorker.measure(staleRoot, control: .init(mode: .deep))
        let evidenceAfter = CleanupScanWorker.measure(staleRoot, control: .init(mode: .deep))
        expect(evidenceBefore.complete && evidenceAfter.complete
               && evidenceBefore.activityEvidence == evidenceAfter.activityEvidence
               && CleanupAgePolicy.isStale(evidenceAfter.activityEvidence,
                   retention: CleanupAgePolicy.developerRetention),
               "repeated directory sizing must not refresh regular-file activity")
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
        var liveCurrentFiles: [String] = []
        let secureSummary = NativeCore.shared.applyCleanup(
            items: securePlan.items, permanent: true, homeDirectory: home.path,
            onCurrentFile: { liveCurrentFiles.append($0) })
        expect(secureSummary.removed == 3 && secureSummary.failed == 0,
               "secure removal of an identity-matching tree failed")
        expect(fm.fileExists(atPath: secureTree.path)
               && NativeCore.shared.directChildren(of: secureTree).isEmpty,
               "live cache root should remain while unused descendants are removed")
        expect(fm.fileExists(atPath: outsideKeep.appendingPathComponent("precious").path),
               "internal symlink must be unlinked without following it")
        expect(liveCurrentFiles.contains(secureTree.appendingPathComponent("inner/file").path),
               "live-cache progress must publish an actual nested file")
        let recursiveTree = home.appendingPathComponent("Downloads/recursive-progress")
        let recursiveLeaf = recursiveTree.appendingPathComponent("inner/nested/file")
        try fm.createDirectory(at: recursiveLeaf.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 5, count: 4096).write(to: recursiveLeaf)
        var permanentCurrentFiles: [String] = []
        let recursiveSummary = NativeCore.shared.applyCleanup(
            items: DeletionPlan(paths: [recursiveTree.path]).items, permanent: true, homeDirectory: home.path,
            onCurrentFile: { permanentCurrentFiles.append($0) })
        expect(recursiveSummary.removed == 1 && recursiveSummary.failed == 0
               && permanentCurrentFiles.contains(recursiveLeaf.path),
               "permanent recursive removal must publish the current nested file")

        // 身份不符（mtime 已变化）→ 跳过且目录保留。
        let tampered = home.appendingPathComponent("Downloads/tampered")
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

        // Root-based progress completes for removed, refused and failed work;
        // it must not turn into one callback per cache descendant.
        let progressFile = home.appendingPathComponent("Downloads/progress-success.txt")
        try fm.createDirectory(at: progressFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture garbage".utf8).write(to: progressFile)
        let progressItems = DeletionPlan(paths: [progressFile.path]).items
            + [.init(record: "relative/refused", identity: "")] + throughLink.items
        var progressEvents: [(Int, Int, String)] = []
        let fixtureCore = NativeCore(cleanupOpenFileProbe: { [] })
        let progressBytes = allocatedBytes(progressFile.path)
        let progressSummary = fixtureCore.applyCleanup(items: progressItems, permanent: true,
            homeDirectory: home.path, onProgress: { progressEvents.append(($0, $1, $2)) })
        expect(progressSummary.removed == 1 && progressSummary.skipped == 2 && progressSummary.failed == 0,
               "progress fixture did not exercise removed and safely refused root outcomes")
        expect(progressSummary.reclaimedBytes == progressBytes && progressBytes > 0,
               "reclaimed bytes included refused paths or omitted the confirmed deleted leaf")

        let partialSecureRoot = home.appendingPathComponent("Downloads/partial-secure")
        try fm.createDirectory(at: partialSecureRoot, withIntermediateDirectories: true)
        let partialSecureLeaf = partialSecureRoot.appendingPathComponent("first")
        try Data(repeating: 7, count: 4096).write(to: partialSecureLeaf)
        let partialSecureBytes = allocatedBytes(partialSecureLeaf.path)
        let partialSecureResult = fixtureCore.applyCleanup(
            items: DeletionPlan(paths: [partialSecureRoot.path]).items, permanent: true,
            homeDirectory: home.path, onCurrentFile: { path in
                if path == partialSecureLeaf.path {
                    try? Data("active lock".utf8).write(to: partialSecureRoot.appendingPathComponent("writer.open"))
                }
            })
        expect(partialSecureResult.removed > 0 && partialSecureResult.failed > 0
               && partialSecureResult.reclaimedBytes == partialSecureBytes
               && fm.fileExists(atPath: partialSecureRoot.appendingPathComponent("writer.open").path),
               "partial secure deletion lost its confirmed reclaimed bytes or removed a new lock")
        expect(progressEvents.map { $0.0 } == [0, 1, 2, 3]
               && progressEvents.allSatisfy { $0.1 == 3 }
               && Set(progressEvents.dropFirst().map { $0.2 }) == Set(progressItems.map(\.record)),
               "root progress was not monotonic or failed to complete all outcomes")
        var emptyProgress: [(Int, Int)] = []
        _ = fixtureCore.applyCleanup(items: [], permanent: true, homeDirectory: home.path,
            onProgress: { completed, total, _ in emptyProgress.append((completed, total)) })
        expect(emptyProgress.count == 1 && emptyProgress[0].0 == 0 && emptyProgress[0].1 == 0,
               "empty cleanup progress should start and finish at zero roots")

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

        // Coalescing must keep a selected parent even when a child appears
        // first, and covered paths must not be reported as skips.
        let coveringRoot = home.appendingPathComponent("Library/Caches/coalesced")
        try fm.createDirectory(at: coveringRoot, withIntermediateDirectories: true)
        let coveringChild = coveringRoot.appendingPathComponent("first")
        let otherChild = coveringRoot.appendingPathComponent("second")
        try Data("first cache entry".utf8).write(to: coveringChild)
        try Data("second cache entry".utf8).write(to: otherChild)
        let coveringPaths = [coveringChild.path, coveringRoot.path]
        expect(DeletionPlan.nonOverlappingPaths(coveringPaths) == [coveringRoot.path]
               && DeletionPlan.nonOverlappingPaths(Array(coveringPaths.reversed())) == [coveringRoot.path],
               "selected parent coverage must not depend on input order")
        let coveringItems = coveringPaths.map {
            DeletionPlan.Item(record: $0, identity: DeletionPlan.identity(at: $0)!)
        }
        let covered = NativeCore.shared.applyCleanup(items: coveringItems,
            permanent: true, homeDirectory: home.path)
        expect(covered.removed == 2 && covered.skipped == 0 && covered.failed == 0
               && covered.removedPaths == Set([coveringChild.path, otherChild.path])
               && covered.remainingPaths == [coveringRoot.path],
               "live cache accounting must identify deleted leaves and retain its root shell")
        expect(!fm.fileExists(atPath: otherChild.path), "coalescing a child left the selected parent's siblings behind")
        let literal = home.path + "/Library/Caches/coalesced/../ordinary"
        let safeLiteral = home.path + "/Library/Caches/ordinary"
        expect(DeletionPlan.nonOverlappingPaths([literal, safeLiteral]) == [literal, safeLiteral],
               "unsafe normalized path swallowed a valid deletion target")

        // Exercise the same immutable scan identities used by the app, with
        // actual deletion and a fresh scan. Open files must survive while
        // unrelated cache paths are removed and stay absent on a second scan.
        let roundTripHome = fixture.appendingPathComponent("round-trip-home")
        let idleCache = roundTripHome.appendingPathComponent("Library/Caches/com.example.idle")
        let openCache = roundTripHome.appendingPathComponent("Library/Caches/com.example.open")
        for root in [idleCache, openCache] {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            try Data(repeating: 9, count: 4096).write(to: root.appendingPathComponent("entry"))
        }
        let openedFD = open(openCache.appendingPathComponent("entry").path, O_RDONLY)
        expect(openedFD >= 0, "could not open cache fixture")
        let beforeDelete = await NativeCore.shared.scanCleanup(homeDirectory: roundTripHome.path)
        expect(beforeDelete.categories.flatMap(\.paths) == [idleCache.path],
               "round-trip scan must expose only currently deletable cache garbage")
        let scannedItems = beforeDelete.categories.flatMap { category in
            category.paths.map { DeletionPlan.Item(record: $0, identity: category.pathIdentities[$0]!) }
        }
        let partialDelete = NativeCore.shared.applyCleanup(items: scannedItems,
            permanent: true, homeDirectory: roundTripHome.path)
        expect(partialDelete.removed == 1 && partialDelete.skipped == 0 && partialDelete.failed == 0,
               "confirmed idle scan inventory did not clean without avoidable skips")
        let afterDelete = await NativeCore.shared.scanCleanup(homeDirectory: roundTripHome.path)
        expect(afterDelete.categories.isEmpty,
               "fresh scan rediscovered deleted garbage or admitted an occupied file")
        close(openedFD)
        let releasedScan = await NativeCore.shared.scanCleanup(homeDirectory: roundTripHome.path)
        let releasedItems = releasedScan.categories.flatMap { category in
            category.paths.map { DeletionPlan.Item(record: $0, identity: category.pathIdentities[$0]!) }
        }
        let retried = NativeCore.shared.applyCleanup(
            items: releasedItems,
            permanent: true, homeDirectory: roundTripHome.path)
        expect(retried.removed == 1 && retried.skipped == 0 && retried.failed == 0,
               "unchanged cache could not be retried after releasing its open file")
        let afterRetry = await NativeCore.shared.scanCleanup(homeDirectory: roundTripHome.path)
        expect(afterRetry.categories.isEmpty, "scan-delete-rescan did not converge to an empty inventory")

        // Live caches are cleaned per leaf. One open file or a durable child
        // must not freeze the unused garbage elsewhere in the same directory.
        let liveHome = fixture.appendingPathComponent("live-home")
        let liveRoot = liveHome.appendingPathComponent("Library/Caches/com.example.live")
        func liveWrite(_ relative: String, contents: Data = Data("rebuildable garbage".utf8)) throws -> URL {
            let url = liveRoot.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url)
            return url
        }
        let liveOpen = try liveWrite("nested/active")
        let liveLock = try liveWrite("agent.open")
        let liveUnused = try liveWrite("nested/unused")
        let liveSession = try liveWrite("sessions/history.jsonl")
        let liveConfig = try liveWrite("config.toml")
        let liveMCP = try liveWrite("mcp.json")
        let liveSkill = try liveWrite("skills/example/SKILL.md")
        let liveDatabase = try liveWrite("store.sqlite")
        let liveWAL = try liveWrite("store.sqlite-wal")
        let liveSHM = try liveWrite("store.sqlite-shm")
        let liveJournal = try liveWrite("store.sqlite-journal")
        let headerDatabase = try liveWrite("state-without-extension",
            contents: Data("SQLite format 3\0durable database".utf8))
        let whitelistedFile = try liveWrite("keep/selected")
        let whitelistedDirectory = try liveWrite("keep-directory/data")
        let whitelistedGlob = try liveWrite("glob/preserved")
        let liveFree = try liveWrite("other/unused")
        let liveDirectoryLeaf = try liveWrite("open-directory/unused")
        let liveOutside = fixture.appendingPathComponent("live-outside")
        try fm.createDirectory(at: liveOutside, withIntermediateDirectories: true)
        try Data("external data".utf8).write(to: liveOutside.appendingPathComponent("precious"))
        let liveLink = liveRoot.appendingPathComponent("external-link")
        try fm.createSymbolicLink(at: liveLink, withDestinationURL: liveOutside)
        let whitelistURL = liveHome.appendingPathComponent(".config/mole/whitelist")
        try fm.createDirectory(at: whitelistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(([whitelistedFile.path, whitelistedDirectory.deletingLastPathComponent().path,
                   liveRoot.appendingPathComponent("glob/*").path].joined(separator: "\n") + "\n").utf8)
            .write(to: whitelistURL)
        let livePlan = DeletionPlan(paths: [liveRoot.path])
        let liveFD = open(liveOpen.path, O_RDONLY)
        let liveDirectoryFD = open(liveDirectoryLeaf.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY)
        expect(liveFD >= 0, "could not hold the live cache file open")
        expect(liveDirectoryFD >= 0, "could not hold the live cache directory open")
        let safeLiveScan = await NativeCore.shared.scanCleanup(homeDirectory: liveHome.path)
        let safeLivePaths = safeLiveScan.categories.flatMap(\.paths)
        func offered(_ path: String, in paths: [String]) -> Bool {
            paths.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
        for deletable in [liveUnused, liveFree, liveDirectoryLeaf] {
            expect(offered(deletable.path, in: safeLivePaths),
                   "mixed cache scan lost a deletable sibling: \(deletable.path)")
        }
        for preserved in [liveOpen, liveLock, liveSession, liveConfig, liveMCP, liveSkill, liveDatabase,
                          liveWAL, liveSHM, liveJournal, headerDatabase, whitelistedFile,
                          whitelistedDirectory, whitelistedGlob, liveLink] {
            expect(!offered(preserved.path, in: safeLivePaths),
                   "mixed cache scan offered occupied or protected content: \(preserved.path)")
        }
        let oldInventory = CleanupCategory(name: "cached broad parent", paths: [liveRoot.path],
            bytes: 999999, pathIdentities: [liveRoot.path: "0:0:0"], selected: true,
            source: .core, risk: .safe, disposal: .permanentDelete,
            applyRoute: .genericTrash, activityGuard: .openFile)
        let refreshedInventory = NativeCore.shared.preflightCleanupCategories([oldInventory],
            homeDirectory: liveHome.path)
        expect(Set(refreshedInventory.categories.flatMap(\.paths)) == Set(safeLivePaths)
               && refreshedInventory.categories.allSatisfy { $0.allSelected }
               && refreshedInventory.categories.flatMap { Array($0.pathIdentities.values) }
                    .allSatisfy { $0 != "0:0:0" },
               "cached preflight did not materialize safe descendants or refresh scan identities")
        for category in refreshedInventory.categories {
            for path in category.paths {
                expect(category.pathBytes[path] == CleanupScanWorker.measure(path,
                    control: .init(mode: .deep)).bytes,
                    "cached preflight counted protected bytes under a split cache")
            }
        }
        var liveProgress: [(Int, Int, String)] = []
        let liveDeletedBytes = [liveUnused, liveFree, liveDirectoryLeaf, liveLink]
            .reduce(UInt64(0)) { $0 &+ allocatedBytes($1.path) }
        let livePartial = NativeCore.shared.applyCleanup(items: livePlan.items,
            permanent: true, homeDirectory: liveHome.path,
            onProgress: { liveProgress.append(($0, $1, $2)) })
        expect(liveProgress.map { $0.0 } == [0, 1] && liveProgress.allSatisfy { $0.1 == 1 && $0.2 == liveRoot.path },
               "partial live cleanup progress should complete its root without counting nested leaves")
        expect(livePartial.failed == 0 && livePartial.removedPaths.contains(liveUnused.path)
               && livePartial.removedPaths.contains(liveFree.path)
               && livePartial.removedPaths.contains(liveDirectoryLeaf.path)
               && livePartial.removedPaths.contains(liveLink.path)
               && !livePartial.removedPaths.contains(liveRoot.path)
               && livePartial.remainingPaths == [liveRoot.path],
               "one occupied cache leaf froze unrelated garbage or misreported the directory as removed")
        expect(livePartial.reclaimedBytes == liveDeletedBytes,
               "partial live cleanup reported selected capacity instead of confirmed deleted leaf bytes")
        for preserved in [liveOpen, liveLock, liveSession, liveConfig, liveMCP, liveSkill, liveDatabase, liveWAL, liveSHM, liveJournal,
                          headerDatabase, whitelistedFile, whitelistedDirectory, whitelistedGlob] {
            expect(fm.fileExists(atPath: preserved.path), "live cleanup removed a protected child: \(preserved.path)")
        }
        expect(fm.fileExists(atPath: liveOutside.appendingPathComponent("precious").path),
               "live cleanup followed a descendant symlink")
        expect(fm.fileExists(atPath: liveDirectoryLeaf.deletingLastPathComponent().path),
               "live cleanup removed an occupied directory shell")
        close(liveFD)
        close(liveDirectoryFD)
        let liveRetry = NativeCore.shared.applyCleanup(items: livePlan.items,
            permanent: true, homeDirectory: liveHome.path)
        expect(liveRetry.removedPaths.contains(liveOpen.path)
               && !fm.fileExists(atPath: liveOpen.path),
               "a partial live cleanup changed root mtime and prevented retry of the released leaf")

        // Directory content churn keeps the same authorized cache object;
        // replacing that directory object must still reject the old plan.
        let churnRoot = liveHome.appendingPathComponent("Library/Caches/churning")
        try fm.createDirectory(at: churnRoot, withIntermediateDirectories: true)
        let churnOld = churnRoot.appendingPathComponent("modified")
        try Data("old cache".utf8).write(to: churnOld)
        let churnPlan = DeletionPlan(paths: [churnRoot.path])
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: churnRoot.path)
        try Data("updated cache".utf8).write(to: churnOld)
        let churnNew = churnRoot.appendingPathComponent("new")
        try Data("new cache".utf8).write(to: churnNew)
        let churnClean = NativeCore.shared.applyCleanup(items: churnPlan.items,
            permanent: true, homeDirectory: liveHome.path)
        expect(churnClean.failed == 0 && churnClean.skipped == 0
               && churnClean.removedPaths == Set([churnOld.path, churnNew.path]),
               "cache content changes incorrectly invalidated its stable directory identity")
        let replacementPlan = DeletionPlan(paths: [churnRoot.path])
        let originalRoot = liveHome.appendingPathComponent("Library/Caches/original-churning")
        try fm.moveItem(at: churnRoot, to: originalRoot)
        try fm.createDirectory(at: churnRoot, withIntermediateDirectories: true)
        let replacementLeaf = churnRoot.appendingPathComponent("replacement")
        try Data("new directory object".utf8).write(to: replacementLeaf)
        let replaced = NativeCore.shared.applyCleanup(items: replacementPlan.items,
            permanent: true, homeDirectory: liveHome.path)
        expect(replaced.removed == 0 && replaced.skipped == 1
               && fm.fileExists(atPath: replacementLeaf.path),
               "a replaced cache inode was accepted as the old directory")

        // Unknown open-file state fails closed even for an explicitly trusted
        // live target outside the generic macOS cache catalog.
        let customLive = liveHome.appendingPathComponent(".codex/tmp")
        try fm.createDirectory(at: customLive, withIntermediateDirectories: true)
        let customLeaf = customLive.appendingPathComponent("unused")
        try Data("temporary garbage".utf8).write(to: customLeaf)
        let customPlan = DeletionPlan(paths: [customLive.path])
        let unavailableCore = NativeCore(cleanupOpenFileProbe: { nil })
        let unavailableScan = await unavailableCore.scanCleanup(homeDirectory: liveHome.path)
        expect(!unavailableScan.succeeded && unavailableScan.categories.isEmpty,
               "unknown open-file evidence was incorrectly presented as deletable garbage")
        let unavailable = unavailableCore.applyCleanup(items: customPlan.items,
            permanent: true, homeDirectory: liveHome.path, liveCleanupTargets: [customLive.path])
        expect(unavailable.removed == 0 && unavailable.skipped == 1
               && fm.fileExists(atPath: customLeaf.path),
               "unknown open-file state must preserve an explicitly declared live cache")
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: customLive.path)
        let customClean = NativeCore.shared.applyCleanup(items: customPlan.items,
            permanent: true, homeDirectory: liveHome.path, liveCleanupTargets: [customLive.path])
        expect(customClean.removedPaths == [customLeaf.path] && customClean.skipped == 0,
               "fresh catalog live target was not admitted outside generic cache roots")

        // Permission-only content is shown only when its signed administrator
        // execution route is available. Immutable content remains excluded.
        let permissionsHome = fixture.appendingPathComponent("permissions-home")
        let permissionsRoot = permissionsHome.appendingPathComponent("Library/Caches/readonly-parent")
        try fm.createDirectory(at: permissionsRoot, withIntermediateDirectories: true)
        let permissionLeaf = permissionsRoot.appendingPathComponent("cache")
        try Data("administrator-removable cache".utf8).write(to: permissionLeaf)
        expect(chmod(permissionsRoot.path, 0o555) == 0, "could not prepare permission fixture")
        let userPermissionScan = await fixtureCore.scanCleanup(homeDirectory: permissionsHome.path)
        expect(userPermissionScan.categories.isEmpty, "ordinary scan offered administrator-only junk")
        let administratorScan = await fixtureCore.scanCleanup(homeDirectory: permissionsHome.path,
            includingAdministratorRequired: true)
        expect(administratorScan.categories.flatMap(\.paths) == [permissionsRoot.path]
               && administratorScan.administratorRequiredPaths == [permissionsRoot.path]
               && fixtureCore.requiresAdministratorDeletion(permissionsRoot.path),
               "administrator-enabled scan lost readable confirmed junk or recursive permission metadata")
        expect(chmod(permissionsRoot.path, 0o755) == 0, "could not release permission fixture")
        let aclRoot = permissionsHome.appendingPathComponent("Library/Caches/acl-parent")
        try fm.createDirectory(at: aclRoot, withIntermediateDirectories: true)
        let aclLeaf = aclRoot.appendingPathComponent("cache")
        try Data("ACL protected cache".utf8).write(to: aclLeaf)
        let aclCommand = Process()
        aclCommand.executableURL = URL(fileURLWithPath: "/bin/chmod")
        aclCommand.arguments = ["+a", "\(NSUserName()) deny delete", aclLeaf.path]
        try aclCommand.run(); aclCommand.waitUntilExit()
        expect(aclCommand.terminationStatus == 0, "could not prepare ACL deletion fixture")
        let aclUserScan = await fixtureCore.scanCleanup(homeDirectory: permissionsHome.path)
        let aclAdministratorScan = await fixtureCore.scanCleanup(homeDirectory: permissionsHome.path,
            includingAdministratorRequired: true)
        let aclRequiresAdministrator = fixtureCore.requiresAdministratorDeletion(aclRoot.path)
        let releaseACL = Process()
        releaseACL.executableURL = URL(fileURLWithPath: "/bin/chmod")
        releaseACL.arguments = ["-N", aclLeaf.path]
        try releaseACL.run(); releaseACL.waitUntilExit()
        expect(!offered(aclLeaf.path, in: aclUserScan.categories.flatMap(\.paths))
               && offered(aclLeaf.path, in: aclAdministratorScan.categories.flatMap(\.paths))
               && aclAdministratorScan.administratorRequiredPaths.contains(aclRoot.path)
               && aclRequiresAdministrator,
               "ACL-only restrictions were missed by recursive administrator routing")
        let immutableRoot = permissionsHome.appendingPathComponent("Library/Caches/immutable")
        try fm.createDirectory(at: immutableRoot, withIntermediateDirectories: true)
        let immutableLeaf = immutableRoot.appendingPathComponent("cache")
        try Data("immutable cache".utf8).write(to: immutableLeaf)
        expect(chflags(immutableLeaf.path, UInt32(UF_IMMUTABLE)) == 0, "could not prepare immutable fixture")
        let immutableScan = await fixtureCore.scanCleanup(homeDirectory: permissionsHome.path,
            includingAdministratorRequired: true)
        expect(chflags(immutableLeaf.path, 0) == 0, "could not release immutable fixture")
        expect(!offered(immutableLeaf.path, in: immutableScan.categories.flatMap(\.paths)),
               "administrator-enabled scan offered immutable content")

        let templateHome = fixture.appendingPathComponent("template-home")
        let templateRoot = templateHome.appendingPathComponent("Library/Caches/pnpm/dlx/hash/node_modules/create-ui/templates/spa/src")
        try fm.createDirectory(at: templateRoot.appendingPathComponent("models"), withIntermediateDirectories: true)
        try Data("export interface Task {}".utf8).write(to: templateRoot.appendingPathComponent("models/Task.ts"))
        try Data("export const config = {}".utf8).write(to: templateRoot.appendingPathComponent("config.json"))
        let templateScan = await fixtureCore.scanCleanup(homeDirectory: templateHome.path)
        expect(!templateScan.categories.isEmpty, "downloaded pnpm source template was excluded as persistent data")
        let templateItems = templateScan.categories.flatMap { category in
            category.paths.map { DeletionPlan.Item(record: $0, identity: category.pathIdentities[$0]!) }
        }
        let templateApply = fixtureCore.applyCleanup(items: templateItems, permanent: true,
            homeDirectory: templateHome.path)
        expect(templateApply.skipped == 0 && templateApply.failed == 0
               && !fm.fileExists(atPath: templateRoot.appendingPathComponent("models/Task.ts").path),
               "scan/apply source-template protection diverged")

        let browserHome = fixture.appendingPathComponent("browser-home")
        var browserCaches: [String] = []
        var browserDatabases: [String] = []
        var browserProtectedCacheContent: [String] = []
        for browser in ["Arc/User Data", "Microsoft Edge"] {
            let serviceWorker = browserHome.appendingPathComponent(
                "Library/Application Support/" + browser + "/Default/Service Worker")
            for leaf in ["CacheStorage/hash/cache", "ScriptCache/cache", "Database/000001.log"] {
                let file = serviceWorker.appendingPathComponent(leaf)
                try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(repeating: 5, count: 4096).write(to: file)
                if leaf.hasPrefix("Database/") { browserDatabases.append(file.path) }
                else { browserCaches.append(file.path) }
            }
            for leaf in ["CacheStorage/credentials/plain", "CacheStorage/Database/metadata",
                         "CacheStorage/records.sqlite/plain"] {
                let file = serviceWorker.appendingPathComponent(leaf)
                try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(repeating: 7, count: 4096).write(to: file)
                browserProtectedCacheContent.append(file.path)
            }
        }
        let browserScan = await fixtureCore.scanCleanup(homeDirectory: browserHome.path)
        let browserPaths = browserScan.categories.flatMap(\.paths)
        expect(browserCaches.allSatisfy { offered($0, in: browserPaths) }
               && (browserDatabases + browserProtectedCacheContent).allSatisfy { !offered($0, in: browserPaths) },
               "Arc/Edge Service Worker database or durable ancestry diverged from cache discovery")
        let staleBrowserDatabase = CleanupCategory(name: "stale browser cache",
            paths: browserDatabases.map { ($0 as NSString).deletingLastPathComponent }, bytes: 999999,
            selected: true, source: .core, risk: .safe, disposal: .permanentDelete,
            applyRoute: .genericTrash, activityGuard: .browser)
        expect(fixtureCore.preflightCleanupCategories([staleBrowserDatabase],
            homeDirectory: browserHome.path).categories.isEmpty,
            "cached Service Worker databases were republished as ordinary junk")
        let staleBrowserProtectedLeaves = CleanupCategory(name: "stale browser leaves",
            paths: browserProtectedCacheContent, bytes: 999999,
            selected: true, source: .core, risk: .safe, disposal: .permanentDelete,
            applyRoute: .genericTrash, activityGuard: .browser)
        expect(fixtureCore.preflightCleanupCategories([staleBrowserProtectedLeaves],
            homeDirectory: browserHome.path).categories.isEmpty,
            "split browser cache records discarded protected content ancestry")
        let staleBrowserApply = fixtureCore.applyCleanup(
            items: DeletionPlan(paths: browserProtectedCacheContent).items,
            permanent: true, homeDirectory: browserHome.path)
        expect(staleBrowserApply.removed == 0 && staleBrowserApply.reclaimedBytes == 0
               && browserProtectedCacheContent.allSatisfy { fm.fileExists(atPath: $0) },
               "split browser cache removal discarded protected content ancestry")
        let browserBytes = browserCaches.reduce(UInt64(0)) { $0 &+ allocatedBytes($1) }
        let browserRemoval = fixtureCore.applyCleanup(items: browserScan.categories.flatMap { category in
            category.paths.map { DeletionPlan.Item(record: $0, identity: category.pathIdentities[$0]!) }
        }, permanent: true, homeDirectory: browserHome.path)
        expect(browserRemoval.skipped == 0 && browserRemoval.failed == 0
               && browserRemoval.reclaimedBytes == browserBytes
               && (browserDatabases + browserProtectedCacheContent).allSatisfy { fm.fileExists(atPath: $0) },
               "Arc/Edge cache scan/apply proof diverged or database bytes were claimed as reclaimed")

        // Generic inference cannot override the Agent executor's decision to
        // keep a verified directory with embedded registrations non-live.
        let verifiedRoot = liveHome.appendingPathComponent("Library/Caches/verified-resource")
        try fm.createDirectory(at: verifiedRoot, withIntermediateDirectories: true)
        let verifiedOpen = verifiedRoot.appendingPathComponent("active")
        let verifiedUnused = verifiedRoot.appendingPathComponent("unused")
        try Data("active resource".utf8).write(to: verifiedOpen)
        try Data("registered resource".utf8).write(to: verifiedUnused)
        let verifiedFD = open(verifiedOpen.path, O_RDONLY)
        expect(verifiedFD >= 0, "could not hold a verified non-live resource")
        let verifiedClean = NativeCore.shared.applyCleanup(items: DeletionPlan(paths: [verifiedRoot.path]).items,
            permanent: true, homeDirectory: liveHome.path, verifiedTargets: [verifiedRoot.path])
        close(verifiedFD)
        expect(verifiedClean.removed == 0 && verifiedClean.skipped == 1
               && fm.fileExists(atPath: verifiedUnused.path),
               "generic cache inference bypassed a verified Agent resource's whole-item protection")

        let cacheFile = liveHome.appendingPathComponent("Library/Caches/identity-file")
        try Data("planned file".utf8).write(to: cacheFile)
        let cacheFilePlan = DeletionPlan(paths: [cacheFile.path])
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: cacheFile.path)
        let changedFile = NativeCore.shared.applyCleanup(items: cacheFilePlan.items,
            permanent: true, homeDirectory: liveHome.path, liveCleanupTargets: [cacheFile.path])
        expect(changedFile.removed == 0 && changedFile.skipped == 1 && fm.fileExists(atPath: cacheFile.path),
               "live mode relaxed a regular file's full planned identity")

        // Fresh catalog caches can live below a durable Agent data parent.
        // Its broad parent prefix must not veto each unused cache descendant.
        let codexCache = liveHome.appendingPathComponent("Library/Application Support/Codex/Cache")
        try fm.createDirectory(at: codexCache, withIntermediateDirectories: true)
        let codexOpen = codexCache.appendingPathComponent("active")
        let codexUnused = codexCache.appendingPathComponent("unused")
        let codexConfig = codexCache.appendingPathComponent("config.toml")
        for leaf in [codexOpen, codexUnused, codexConfig] { try Data("fixture resource".utf8).write(to: leaf) }
        let codexFD = open(codexOpen.path, O_RDONLY)
        expect(codexFD >= 0, "could not hold a nested Codex cache leaf")
        let codexClean = NativeCore.shared.applyCleanup(items: DeletionPlan(paths: [codexCache.path]).items,
            permanent: true, homeDirectory: liveHome.path, verifiedTargets: [codexCache.path],
            liveCleanupTargets: [codexCache.path])
        close(codexFD)
        expect(codexClean.removedPaths == [codexUnused.path]
               && fm.fileExists(atPath: codexOpen.path) && fm.fileExists(atPath: codexConfig.path),
               "a sensitive Agent parent froze a fresh cache or let a durable child be removed")
        let codexLogs = liveHome.appendingPathComponent(".codex/log")
        try fm.createDirectory(at: codexLogs, withIntermediateDirectories: true)
        let codexLog = codexLogs.appendingPathComponent("old.log")
        try Data("log garbage".utf8).write(to: codexLog)
        let logPlan = DeletionPlan(paths: [codexLogs.path])
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: codexLogs.path)
        let logClean = NativeCore.shared.applyCleanup(items: logPlan.items, permanent: true,
            homeDirectory: liveHome.path, verifiedTargets: [codexLogs.path], liveCleanupTargets: [codexLogs.path])
        expect(logClean.removedPaths == [codexLog.path] && logClean.skipped == 0,
               "fresh log garbage below an Agent data root was blanket protected")

        // A running app's real bundle ID is used only as read-only ownership
        // evidence; all paths being cleaned still belong to this fixture home.
        if let owner = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
            .first(where: { CleanupRiskPolicy.isValidReverseDNSOwner($0) }) {
            let ownedRoot = liveHome.appendingPathComponent("Library/Caches/" + owner)
            try fm.createDirectory(at: ownedRoot, withIntermediateDirectories: true)
            let ownedLeaf = ownedRoot.appendingPathComponent("unused")
            try Data("unoccupied cache".utf8).write(to: ownedLeaf)
            let ownedClean = NativeCore.shared.applyCleanup(items: DeletionPlan(paths: [ownedRoot.path]).items,
                permanent: true, homeDirectory: liveHome.path)
            expect(ownedClean.removedPaths.contains(ownedLeaf.path) && ownedClean.skipped == 0,
                   "running application ownership froze unoccupied fixture cache garbage")
        }

        let dataHome = fixture.appendingPathComponent("app-data-home")
        func writeData(_ relative: String, bytes: Int = 600 * 1024) throws {
            let url = dataHome.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 101, count: bytes).write(to: url)
        }
        let gone = "com.example.nori-gone-app"
        try writeData("Library/Application Support/\(gone)/state.db")
        try writeData("Library/Containers/\(gone)/Data/Library/Cookies/Cookies.binarycookies")
        try writeData("Library/Preferences/\(gone).plist", bytes: 512)
        try writeData("Library/Application Support/com.apple.private-fixture/keep", bytes: 2 * 1024 * 1024)
        try writeData("Library/Application Support/com.example.tiny-gone/keep", bytes: 64)
        for project in ["Code/web-a", "Code/clients/web-b"] {
            try writeData(project + "/package.json", bytes: 32)
            try writeData(project + "/node_modules/lib/index.js", bytes: 30 * 1024 * 1024)
            try writeData(project + "/node_modules/lib/node_modules/nested/index.js", bytes: 1024)
        }
        try writeData("Code/no-marker/node_modules/stray.js", bytes: 30 * 1024 * 1024)
        try writeData("Code/py/.venv/pyvenv.cfg", bytes: 32)
        try writeData("Code/py/.venv/lib/site.py", bytes: 64)
        try writeData("Library/Application Support/Tool/project/package.json", bytes: 32)
        let artifactPaths = Set(NativeCore.shared.projectArtifactPaths(home: dataHome))
        expect(artifactPaths == Set([
                   dataHome.appendingPathComponent("Code/web-a/node_modules").path,
                   dataHome.appendingPathComponent("Code/clients/web-b/node_modules").path,
                   dataHome.appendingPathComponent("Code/py/.venv").path]),
               "project artifacts need their marker and must not descend into nested artifacts: \(artifactPaths)")
        let reviewCategories = NativeCore.shared.appDataReviewCategories(
            home: dataHome, offered: [], whitelist: [])
        let leftover = reviewCategories.first { $0.name == gone + " leftovers" }
        expect(leftover?.isAppDataReview == true && leftover?.source == .appLeftover && leftover?.selected == false
               && Set(leftover?.paths ?? []) == Set([
                   dataHome.appendingPathComponent("Library/Application Support/\(gone)").path,
                   dataHome.appendingPathComponent("Library/Containers/\(gone)").path,
                   dataHome.appendingPathComponent("Library/Preferences/\(gone).plist").path]),
               "an uninstalled app's full data set must be offered as one unselected review item")
        expect(!reviewCategories.contains { category in
            category.paths.contains { $0.contains("com.apple.") }
        }, "Apple data must not be offered")
        let orphanedSettings = reviewCategories.first { $0.name == "Orphaned Settings" }
        expect(orphanedSettings?.paths == [dataHome.appendingPathComponent("Library/Application Support/com.example.tiny-gone").path]
               && orphanedSettings?.selected == false,
               "small leftovers collapse into one unselected settings row")
        try writeData("Library/LaunchAgents/com.example.gone-agent.plist", bytes: 0)
        try (["Label": "com.example.gone-agent",
              "ProgramArguments": [dataHome.appendingPathComponent("Applications/Gone.app/Contents/MacOS/agent").path]] as NSDictionary)
            .write(to: dataHome.appendingPathComponent("Library/LaunchAgents/com.example.gone-agent.plist"))
        try (["Label": "com.example.live-agent", "ProgramArguments": ["/bin/ls"]] as NSDictionary)
            .write(to: dataHome.appendingPathComponent("Library/LaunchAgents/com.example.live-agent.plist"))
        let brokenAgents = NativeCore.shared.appDataReviewCategories(home: dataHome, offered: [], whitelist: [])
            .first { $0.name == "Broken Login Agents" }
        expect(brokenAgents?.paths == [dataHome.appendingPathComponent("Library/LaunchAgents/com.example.gone-agent.plist").path]
               && CleanupRiskPolicy.reviewTargetKind(brokenAgents!.paths[0], homeDirectory: dataHome.path) == .brokenLaunchAgent
               && CleanupRiskPolicy.reviewTargetKind(dataHome.appendingPathComponent("Library/LaunchAgents/com.example.live-agent.plist").path,
                                                     homeDirectory: dataHome.path) == nil,
               "only launch agents whose program is missing are offered")
        let modules = reviewCategories.first { $0.name == "Project node_modules" }
        expect(modules?.paths.count == 2 && modules?.selected == false && modules?.source == .developerCache
               && CleanupGroupBucket(category: modules!, homeDirectory: dataHome.path) == .developer,
               "project dependencies must be offered as one unselected developer review item")
        expect(CleanupRiskPolicy.isAppDataRoot(dataHome.path + "/Library/Application Support/Foo/Bar",
                                               homeDirectory: dataHome.path)
               && !CleanupRiskPolicy.isAppDataRoot(dataHome.path + "/Library/Application Support/Foo/Bar/Baz",
                                                   homeDirectory: dataHome.path)
               && !CleanupRiskPolicy.isAppDataRoot(dataHome.path + "/Documents/Foo", homeDirectory: dataHome.path)
               && !CleanupRiskPolicy.isAppDataRoot(dataHome.path + "/Library/Preferences/.GlobalPreferences.plist",
                                                   homeDirectory: dataHome.path),
               "app data shapes must stay limited to known per-app roots")
        if var leftover {
            expect(!CleanupRiskPolicy.isEligible(leftover, mode: .quickClean, running: RunningApplicationSnapshot())
                   && !CleanupRiskPolicy.isEligible(leftover, mode: .automatic, running: RunningApplicationSnapshot()),
                   "app data review items must never run in quick or automatic cleanup")
            leftover.selected = true
            expect(CleanupCategory.manualCleanupCandidates(from: [leftover]).map(\.id) == [leftover.id]
                   && CleanupCategory.safeCleanupCandidates(from: [leftover]).isEmpty,
                   "selected app data must reach manual execution but never safe/quick candidate lists")
            expect(CleanupRiskPolicy.isEligible(leftover, mode: .manual, running: RunningApplicationSnapshot())
                   && !CleanupRiskPolicy.isEligible(leftover, mode: .manual, running: .unavailable)
                   && !CleanupRiskPolicy.isEligible(leftover, mode: .manual,
                        running: RunningApplicationSnapshot(bundleIdentifiers: [gone])),
                   "manual app data cleanup requires a complete snapshot and an idle owner")
            var trashed: [String] = []
            let applied = NativeCore.shared.applyAppDataReview([leftover], homeDirectory: dataHome.path,
                                                              trashHandler: { trashed.append($0.path) })
            expect(Set(trashed) == Set(leftover.paths) && applied.failed == 0,
                   "selected app data must reach the Trash route: \(applied.messages)")
            try fm.createDirectory(at: dataHome.appendingPathComponent("Documents"), withIntermediateDirectories: true)
            let descriptor = CleanupRiskPolicy.appDataReview(leftover: true)
            let forged = CleanupCategory(name: "forged", paths: [dataHome.appendingPathComponent("Documents").path],
                bytes: 1, selected: true, source: descriptor.source, risk: descriptor.risk,
                disposal: descriptor.disposal, applyRoute: descriptor.applyRoute,
                activityGuard: descriptor.activityGuard, reasonKey: descriptor.reasonKey)
            let refusedForged = NativeCore.shared.applyAppDataReview([forged], homeDirectory: dataHome.path,
                                                                    trashHandler: { _ in preconditionFailure("forged path trashed") })
            expect(refusedForged.removed == 0 && refusedForged.skipped >= 1,
                   "paths outside app data shapes must be refused at execution")
        }

        print(String(format: "PASS: catalog, grouping, deep scan, manual Agent residuals, exclusions, cancellation, partial sizes, hardlinks, pipe output, 7-day gate, sizing activity, custom locations, lexical guards, secure fd-walk deletion, leaf-level live caches, protected descendants, stable directory identity, open-file retry, scan-delete-rescan; 10000 files in %.3fs", benchmark.elapsed))
        print(quick.diagnostics)
        print(deep.diagnostics)
        print(aged.diagnostics)
    }
}
