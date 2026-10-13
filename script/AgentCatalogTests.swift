import Darwin
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
        exit(1)
    }
}

@main
struct AgentCatalogTests {
    static func main() async throws {
        if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "--probe" {
            probe(home: CommandLine.arguments[2])
            return
        }
        let fm = FileManager.default
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: fixture) }
        let home = fixture.appendingPathComponent("home").path
        let trashRoot = fixture.appendingPathComponent("trash")
        let trashHandler: (URL) throws -> Void = { url in
            try fm.createDirectory(at: trashRoot, withIntermediateDirectories: true)
            let destination = trashRoot.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
            try fm.moveItem(at: url, to: destination)
        }
        let sandboxPresence = AgentPresenceContext(
            applicationDirs: [home + "/Applications"], searchPath: [home + "/.local/bin"])

        func write(_ relative: String, bytes: Int = 4096) throws {
            let url = URL(fileURLWithPath: home + "/" + relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 97, count: bytes).write(to: url)
        }
        func link(_ relative: String, to destination: String) throws {
            let url = URL(fileURLWithPath: home + "/" + relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createSymbolicLink(atPath: url.path, withDestinationPath: destination)
        }
        func touch(_ relative: String, secondsAgo: TimeInterval) throws {
            try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-secondsAgo)],
                                 ofItemAtPath: home + "/" + relative)
        }
        func executable(_ relative: String) throws {
            try write(relative)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home + "/" + relative)
        }
        func run(_ executable: String, _ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            let errors = Pipe()
            process.standardError = errors
            try process.run()
            process.waitUntilExit()
            let output = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            expect(process.terminationStatus == 0,
                   "command failed: \(executable) \(arguments.joined(separator: " ")): \(output)")
        }
        // 存在性检测只检查夹具中的 app / CLI，避免本机是否装过工具改变测试结果。
        try executable(".local/bin/codex")
        try executable(".local/bin/opencode")
        try executable(".local/bin/grok")
        try write("Applications/Cursor.app/Contents/Info.plist")
        // 可搜索的同名目录不是 CLI 程序，也不能被列成可卸载安装。
        try fm.createDirectory(atPath: home + "/.local/bin/gemini", withIntermediateDirectories: false)
        let gemini = AgentCatalog.definitions.first { $0.id == "gemini" }!
        expect(AgentCatalog.resolveExecutable("gemini", searchPath: sandboxPresence.searchPath, home: home) == nil
               && !AgentCatalog.isInstalled(gemini, home: home, presence: sandboxPresence)
               && AgentCLIService.installations(for: gemini, home: home, presence: sandboxPresence).isEmpty,
               "a searchable PATH directory was mistaken for an installed/uninstallable CLI")

        let retentionSuite = "NoriAgentRetentionTests-" + UUID().uuidString
        let retentionDefaults = UserDefaults(suiteName: retentionSuite)!
        defer { retentionDefaults.removePersistentDomain(forName: retentionSuite) }
        var retentionRoundTrip = AgentRetentionPreferences()
        retentionRoundTrip.conversations = .never
        retentionRoundTrip.artifacts = .days(30)
        retentionRoundTrip.save(to: retentionDefaults)
        expect(AgentRetentionPreferences.load(from: retentionDefaults) == retentionRoundTrip,
               "Agent retention preferences did not encode/decode never and days rules")

        let legacyRetention = Data(#"{"conversations":{"kind":"days","days":180},"artifacts":{"kind":"never"}}"#.utf8)
        retentionDefaults.set(legacyRetention, forKey: AgentRetentionPreferences.storageKey)
        var perAgent = AgentRetentionPreferences.load(from: retentionDefaults)
        expect(perAgent.rule(for: .conversations, agentID: "codex") == .days(180)
               && perAgent.rule(for: .artifacts, agentID: "cursor") == .never,
               "legacy shared retention was lost during per-Agent migration")
        perAgent.set(.days(7), for: .conversations, agentID: "codex")
        perAgent.set(.days(30), for: .artifacts, agentID: "codex")
        perAgent.set(.never, for: .conversations, agentID: "cursor")
        perAgent.save(to: retentionDefaults)
        let perAgentReloaded = AgentRetentionPreferences.load(from: retentionDefaults)
        expect(perAgentReloaded == perAgent
               && perAgentReloaded.rule(for: .conversations, agentID: "codex") == .days(7)
               && perAgentReloaded.rule(for: .artifacts, agentID: "codex") == .days(30)
               && perAgentReloaded.rule(for: .conversations, agentID: "cursor") == .never
               && perAgentReloaded.rule(for: .artifacts, agentID: "cursor") == .never
               && perAgentReloaded.rule(for: .conversations, agentID: "grok") == .days(180),
               "per-Agent rules did not persist independently or altered inherited defaults")

        let featureHome = fixture.appendingPathComponent("codex-feature-home").path
        let featureConfig = featureHome + "/.codex/config.toml"
        expect(AgentCodexFeatureEditor.threadStoreCompression(home: featureHome) == .disabled,
               "missing Codex config did not default compression to disabled")
        guard case .success = AgentCodexFeatureEditor.setThreadStoreCompression(true, home: featureHome) else {
            expect(false, "Codex compression editor could not create config.toml")
            return
        }
        expect(AgentCodexFeatureEditor.threadStoreCompression(home: featureHome) == .enabled,
               "created Codex compression setting was not readable")
        let featureOriginal = "[features]\njs_repl = false\n\n[model]\nname = 'fixture'\n"
        try featureOriginal.write(toFile: featureConfig, atomically: true, encoding: .utf8)
        guard case .success = AgentCodexFeatureEditor.setThreadStoreCompression(true, home: featureHome) else {
            expect(false, "Codex compression editor could not append to [features]")
            return
        }
        let featureEnabled = try String(contentsOfFile: featureConfig, encoding: .utf8)
        expect(featureEnabled == "[features]\njs_repl = false\nlocal_thread_store_compression = true\n\n[model]\nname = 'fixture'\n"
               && AgentCodexFeatureEditor.threadStoreCompression(home: featureHome) == .enabled,
               "Codex compression editor changed unrelated TOML bytes")
        guard case .success = AgentCodexFeatureEditor.setThreadStoreCompression(false, home: featureHome) else {
            expect(false, "Codex compression editor could not disable the feature")
            return
        }
        let featureDisabled = try String(contentsOfFile: featureConfig, encoding: .utf8)
        expect(featureDisabled
                == featureEnabled.replacingOccurrences(of: "compression = true", with: "compression = false")
               && AgentCodexFeatureEditor.threadStoreCompression(home: featureHome) == .disabled
               && fm.fileExists(atPath: featureConfig + ".nori-backup"),
               "Codex compression editor did not replace one value or preserve its backup")
        let ambiguousFeature = "description = \"\"\"multi\nline\"\"\"\n"
        try ambiguousFeature.write(toFile: featureConfig, atomically: true, encoding: .utf8)
        let ambiguousResult = AgentCodexFeatureEditor.setThreadStoreCompression(true, home: featureHome)
        expect(AgentCodexFeatureEditor.threadStoreCompression(home: featureHome) == .unknown
               && { if case .failure = ambiguousResult { return true }; return false }()
               && (try? String(contentsOfFile: featureConfig, encoding: .utf8)) == ambiguousFeature,
               "ambiguous multiline TOML was edited instead of failing closed")

        // --- 版本判定：链接指向的版本 + 最新版本保留，其余为旧版本。
        try write(".local/share/claude/versions/2.1.100", bytes: 8192)
        try write(".local/share/claude/versions/2.1.200", bytes: 8192)
        try write(".local/share/claude/versions/2.1.300", bytes: 8192)
        try touch(".local/share/claude/versions/2.1.100", secondsAgo: 300)
        try touch(".local/share/claude/versions/2.1.200", secondsAgo: 200)
        try touch(".local/share/claude/versions/2.1.300", secondsAgo: 100)
        try link(".local/bin/claude", to: home + "/.local/share/claude/versions/2.1.200")
        try fm.setAttributes([.posixPermissions: 0o755],
                             ofItemAtPath: home + "/.local/share/claude/versions/2.1.200")
        let claude = AgentCatalog.definitions.first { $0.id == "claude-code" }!
        let claudeTargets = AgentCatalog.resolve(claude, home: home)
        let stale = claudeTargets.first { $0.labelKey == "agents.label.oldVersions" }?.paths ?? []
        expect(stale == [home + "/.local/share/claude/versions/2.1.100"],
               "old-version detection must keep the linked and newest versions: \(stale)")

        // 链接不指向 root 内任何版本时无法证明谁在用：整个目标不产出。
        try write(".copilot/pkg/universal/1.0.0/copilot")
        try write(".copilot/pkg/universal/1.1.0/copilot")
        try link(".local/bin/copilot", to: "/usr/bin/true")
        let copilot = AgentCatalog.definitions.first { $0.id == "copilot" }!
        expect(!AgentCatalog.resolve(copilot, home: home).contains { $0.labelKey == "agents.label.oldVersions" },
               "versions without an active launcher link must not be offered")

        // 相对链接（grok 的 ../downloads/...）同样要解析到版本目录。
        try write(".grok/downloads/grok-1.0.4-macos-aarch64/grok")
        try write(".grok/downloads/grok-1.0.5-macos-aarch64/grok")
        try write(".grok/downloads/grok-1.0.6-macos-aarch64/grok")
        try touch(".grok/downloads/grok-1.0.4-macos-aarch64", secondsAgo: 300)
        try touch(".grok/downloads/grok-1.0.5-macos-aarch64", secondsAgo: 200)
        try touch(".grok/downloads/grok-1.0.6-macos-aarch64", secondsAgo: 100)
        try link(".grok/bin/agent", to: "../downloads/grok-1.0.5-macos-aarch64")
        let grok = AgentCatalog.definitions.first { $0.id == "grok" }!
        let grokStale = AgentCatalog.resolve(grok, home: home)
            .filter { $0.labelKey == "agents.label.oldVersions" }.flatMap(\.paths)
        expect(grokStale == [home + "/.grok/downloads/grok-1.0.4-macos-aarch64"],
               "relative launcher links must resolve: \(grokStale)")

        // --- 符号链接祖先一律拒绝。
        let outside = fixture.appendingPathComponent("outside").path
        try fm.createDirectory(atPath: outside + "/Cache", withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: URL(fileURLWithPath: outside + "/Cache/entry"))
        try link("Library/Application Support/Antigravity", to: outside)
        let antigravity = AgentCatalog.definitions.first { $0.id == "antigravity" }!
        expect(AgentCatalog.resolve(antigravity, home: home).flatMap(\.paths).isEmpty,
               "a symlinked Application Support root was followed")

        // --- SQLite 族：主文件与伴随文件一起列出。
        try write(".codex/logs_2.sqlite")
        try write(".codex/logs_2.sqlite-wal")
        try write(".codex/logs_2.sqlite-shm")
        try write(".codex/state_5.sqlite")
        try write(".codex/sessions/2026/03/05/rollout-a.jsonl")
        try write(".codex/sessions/2026/06/01/rollout-b.jsonl")
        try write(".codex/sessions/2026/06/02/rollout-future.jsonl")
        try touch(".codex/sessions/2026/03/05/rollout-a.jsonl", secondsAgo: 100 * 24 * 3600)
        try touch(".codex/sessions/2026/06/01/rollout-b.jsonl", secondsAgo: 10 * 24 * 3600)
        try touch(".codex/sessions/2026/06/02/rollout-future.jsonl", secondsAgo: -3600)
        try write(".codex/..codex-global-state.json.tmp-1")
        try write(".codex/..codex-global-state.json.bak.tmp-2")
        try write(".codex/.codex-global-state.json")
        try write(".nori-user-temp/.com.openai.codex.aaa")
        try write(".nori-user-temp/.com.openai.codex.bbb")
        try write(".nori-user-temp/playwright-artifacts-x/output.bin")
        try write(".nori-user-temp/unrelated-file")
        try write(".nori-system-tmp/codex-browser-use/output.bin")
        try write(".nori-system-tmp/codex-browser-use-recent/output.bin")
        try touch(".nori-user-temp/.com.openai.codex.aaa", secondsAgo: 3 * 24 * 3600)
        try touch(".nori-user-temp/.com.openai.codex.bbb", secondsAgo: 3600)
        try touch(".nori-user-temp/playwright-artifacts-x/output.bin", secondsAgo: 3 * 24 * 3600)
        try touch(".nori-user-temp/playwright-artifacts-x", secondsAgo: 3 * 24 * 3600)
        try touch(".nori-system-tmp/codex-browser-use/output.bin", secondsAgo: 10 * 24 * 3600)
        try touch(".nori-system-tmp/codex-browser-use", secondsAgo: 10 * 24 * 3600)
        try touch(".nori-system-tmp/codex-browser-use-recent/output.bin", secondsAgo: 3 * 24 * 3600)
        try touch(".nori-system-tmp/codex-browser-use-recent", secondsAgo: 3 * 24 * 3600)
        let codex = AgentCatalog.definitions.first { $0.id == "codex" }!
        let codexTargets = AgentCatalog.resolve(codex, home: home)
        let logDB = codexTargets.first { $0.labelKey == "agents.label.logDatabase" }!
        expect(logDB.tier == .review && Set(logDB.paths) == Set([
            home + "/.codex/logs_2.sqlite", home + "/.codex/logs_2.sqlite-wal",
            home + "/.codex/logs_2.sqlite-shm"]), "SQLite companions missing: \(logDB.paths)")
        expect(Set(codexTargets.first { $0.labelKey == "agents.label.stateDatabase" }?.owners ?? [])
                .isSuperset(of: ["codex", "Codex", "com.openai.codex"]),
               "Codex state database lost its owner process guard")
        let prefixed = codexTargets.first { target in
            target.paths.contains(home + "/.codex/..codex-global-state.json.tmp-1")
        }?.paths ?? []
        expect(Set(prefixed) == Set([home + "/.codex/..codex-global-state.json.tmp-1",
                                    home + "/.codex/..codex-global-state.json.bak.tmp-2"])
               && !prefixed.contains(home + "/.codex/.codex-global-state.json"),
               "prefixed atomic-write leftovers included the live global state file: \(prefixed)")
        let oldCodexTemp = home + "/.nori-user-temp/.com.openai.codex.aaa"
        let recentCodexTemp = home + "/.nori-user-temp/.com.openai.codex.bbb"
        let systemCodexTemp = home + "/.nori-system-tmp/codex-browser-use"
        let recentSystemCodexTemp = home + "/.nori-system-tmp/codex-browser-use-recent"
        let temporaryReport = AgentInventory.scan(home: home, presence: sandboxPresence,
            onlyAgentIDs: ["codex"])
        let temporaryCategories = temporaryReport.categories.filter { $0.retentionClass == .temporary }
        let temporaryPaths = Set(temporaryCategories.flatMap(\.paths))
        let selectedTemporaryPaths = Set(temporaryCategories.flatMap { category in
            category.paths.filter(category.isPathSelected)
        })
        let userTemporaryCategory = temporaryCategories.first { $0.paths.contains(oldCodexTemp) }
        let systemTemporaryCategory = temporaryCategories.first { $0.paths.contains(systemCodexTemp) }
        expect(temporaryPaths.isSuperset(of: [oldCodexTemp, recentCodexTemp,
                                              systemCodexTemp, recentSystemCodexTemp])
               && !temporaryPaths.contains(home + "/.nori-user-temp/unrelated-file")
               && selectedTemporaryPaths.contains(oldCodexTemp)
               && selectedTemporaryPaths.contains(systemCodexTemp)
               && !selectedTemporaryPaths.contains(recentCodexTemp)
               && !selectedTemporaryPaths.contains(recentSystemCodexTemp)
               && userTemporaryCategory?.retention == 24 * 3600
               && systemTemporaryCategory?.retention == 7 * 24 * 3600,
               "Codex temporary targets ignored prefix, per-root age or retention policy")
        let playwrightReport = AgentInventory.scan(home: home, presence: sandboxPresence,
            onlyAgentIDs: ["playwright"])
        expect(playwrightReport.groups.contains { $0.id == "playwright" }
               && playwrightReport.categories.contains {
                    $0.retentionClass == .temporary
                        && $0.paths.contains(home + "/.nori-user-temp/playwright-artifacts-x")
               }, "Playwright temporary artifacts did not produce a dedicated group")
        expect(!AgentCatalog.dataRoots(for: codex, home: home).contains {
            $0.hasPrefix(home + "/.nori-user-temp/") || $0.hasPrefix(home + "/.nori-system-tmp/")
        }, "temporary targets changed Codex data-root presence semantics")
        var immutableTemporaryRetention = AgentRetentionPreferences()
        immutableTemporaryRetention.set(.never, for: .temporary)
        expect(immutableTemporaryRetention.rule(for: .temporary) == .days(1),
               "the fixed temporary retention rule became user-configurable")
        let recentTemporary = temporaryCategories.first { $0.paths.contains(recentCodexTemp) }!
            .selectingPaths([recentCodexTemp])
        expect(AgentCleanupExecutor.plan([recentTemporary], running: RunningApplicationSnapshot(),
                   home: home, presence: sandboxPresence).items.isEmpty,
               "a temporary file newer than 24 hours entered the deletion plan")
        let oldTemporary = temporaryCategories.first { $0.paths.contains(oldCodexTemp) }!
            .selectingPaths([oldCodexTemp])
        expect(AgentCleanupExecutor.plan([oldTemporary], running: RunningApplicationSnapshot(),
                   home: home, presence: sandboxPresence).items.map(\.record) == [oldCodexTemp],
               "an expired temporary file did not enter the deletion plan")
        let removedTemporary = AgentCleanupExecutor.execute([oldTemporary],
            running: RunningApplicationSnapshot(), home: home, presence: sandboxPresence,
            trashHandler: trashHandler)
        expect(removedTemporary.summary.removed == 1 && !fm.fileExists(atPath: oldCodexTemp),
               "expired Agent temporary file was not permanently removed: \(removedTemporary.summary.messages)")
        let allowedCodex = AgentCatalog.deletablePaths(home: home, presence: sandboxPresence)
        // A selection made by an older Nori must not delete a rollout while
        // leaving its independent Codex index behind.
        let rolloutPath = home + "/.codex/sessions/2026/03/05/rollout-a.jsonl"
        var legacyHistory = CleanupCategory(name: "Legacy history selection", paths: [rolloutPath],
            bytes: 4096, selected: true, source: .aiSession, risk: .warning,
            disposal: .permanentDelete, applyRoute: .aiTrash, activityGuard: .aiAgent,
            reasonKey: "agents.reason.review")
        legacyHistory.pathIdentities[rolloutPath] = DeletionPlan.identity(at: rolloutPath)
        let historyRemoval = AgentCleanupExecutor.execute([legacyHistory],
            running: RunningApplicationSnapshot(), home: home, presence: sandboxPresence,
            trashHandler: trashHandler)
        expect(historyRemoval.summary.removed == 0 && historyRemoval.refused == 1
               && fm.fileExists(atPath: rolloutPath)
               && fm.fileExists(atPath: home + "/.codex/state_5.sqlite"),
               "filesystem history cleanup removed the rollout while leaving the Codex index")
        expect(!allowedCodex.contains(home + "/.codex/sessions/2026/03/05/rollout-a.jsonl")
               && !allowedCodex.contains(home + "/.codex/state_5.sqlite"),
               "Codex history/state entered the filesystem cleanup allowlist")

        // Forged Safe categories and explicit uninstall scope must also keep
        // archived history, secondary indexes, attachments and app bindings.
        for relative in [".codex/archived_sessions/archived.jsonl",
                         ".codex/thread_history_1.sqlite", ".codex/attachments/retained.bin",
                         ".codex/automations/fixture/automation.toml",
                         ".codex/worktrees/fixture/source.swift", ".codex/db-backups/state.sqlite"] {
            try write(relative)
            let retainedPath = home + "/" + relative
            let stale = CleanupCategory(name: "Legacy Safe selection", paths: [retainedPath],
                bytes: 4096, pathIdentities: [retainedPath: DeletionPlan.identity(at: retainedPath)!],
                selected: true, source: .aiCache, risk: .safe, disposal: .permanentDelete,
                applyRoute: .aiTrash, activityGuard: .aiAgent, reasonKey: "agents.reason.review")
            let denied = AgentCleanupExecutor.plan([stale], running: RunningApplicationSnapshot(),
                home: home, presence: sandboxPresence, removingAgentIDs: ["codex"])
            expect(denied.items.isEmpty && denied.refused == 1 && fm.fileExists(atPath: retainedPath),
                   "Safe/uninstall scope bypassed retained Codex data: " + relative)
        }
        // The generic deletion boundary cannot bypass the guard by claiming a
        // verified catalog target, including a parent containing other data.
        for protectedPath in [rolloutPath, home + "/.codex"] {
            let bypass = NativeCore.shared.applyCleanup(
                items: [.init(record: protectedPath, identity: DeletionPlan.identity(at: protectedPath)!)],
                permanent: true, homeDirectory: home, verifiedTargets: [protectedPath])
            expect(bypass.removed == 0 && fm.fileExists(atPath: protectedPath)
                   && bypass.messages.contains { $0.contains("owning application") },
                   "verified generic deletion bypassed managed history protection")
        }

        // opencode 对话库可由用户选择清理，但必须带伴随文件和进程守卫。
        try write(".local/share/opencode/opencode.db")
        try write(".local/share/opencode/opencode.db-wal")
        try write(".local/share/opencode/auth.json")
        let opencode = AgentCatalog.definitions.first { $0.id == "opencode" }!
        let conversation = AgentCatalog.resolve(opencode, home: home)
            .first { $0.labelKey == "agents.label.conversationDatabase" }
        expect(conversation?.tier == .showOnly && conversation?.owners == ["opencode"]
               && conversation?.paths.count == 2, "opencode database credentials lost the high-risk owner guard")
        // Warp's sensitive database remains an explicit manual selection.
        let warpRoot = AgentCatalog.warpDataRoots[0]
        let warpRelatives = ["warp.sqlite", "warp.sqlite-wal", "warp.sqlite-shm"].map { warpRoot + "/" + $0 }
        let warpPaths = Set(warpRelatives.map { home + "/" + $0 })
        try write("Applications/Warp.app/Contents/Info.plist")
        for path in warpRelatives { try write(path) }

        // 默认 APFS 不区分大小写，因此先移除旧名字再创建历史拼写。
        try fm.removeItem(atPath: home + "/.local/share/opencode/opencode.db")
        try fm.removeItem(atPath: home + "/.local/share/opencode/opencode.db-wal")
        try write(".local/share/opencode/openCode.db")
        try write(".local/share/opencode/openCode.db-shm")
        let historicalDB = AgentCatalog.resolve(opencode, home: home)
            .first { $0.labelKey == "agents.label.conversationDatabase" }
        expect(historicalDB?.paths.count == 2
               && historicalDB?.paths.contains(home + "/.local/share/opencode/openCode.db") == true,
               "historical openCode.db spelling or companion was missed")
        expect(!AgentCatalog.deletablePaths(home: home, presence: sandboxPresence)
            .contains(home + "/.local/share/opencode/auth.json"),
               "opencode credentials entered the filesystem cleanup allowlist")

        // 持久 memory 与可单独删除的转录拆开，不能删除“转录”时隐式删记忆。
        try write(".claude/projects/project/session.jsonl")
        try write(".claude/projects/project/subagents/agent.jsonl")
        try write(".claude/projects/project/memory/MEMORY.md")
        let projectTargets = AgentCatalog.resolve(claude, home: home)
        let transcripts = projectTargets.first { $0.labelKey == "agents.label.transcripts" }!
        let memory = projectTargets.first { $0.labelKey == "agents.label.knowledge" }!
        expect(transcripts.paths.contains(home + "/.claude/projects/project/session.jsonl")
               && !transcripts.paths.contains(where: { $0.contains("/memory") })
               && memory.tier == .showOnly
               && memory.paths == [home + "/.claude/projects/project/memory"],
               "Claude transcript cleanup includes persistent auto memory")

        // 已知聊天树中定位数据库，限制深度且不跟随链接进入外部目录。
        try write(".cursor/chats/project/chat/store.db")
        try write(".cursor/chats/project/chat/store.db-wal")
        try write(".cursor/chats/too/deep/for/scan/store.db")
        try link(".cursor/chats/external", to: outside)
        let cursorCLI = AgentCatalog.definitions.first { $0.id == "cursor-cli" }!
        let cursorDBs = AgentCatalog.resolve(cursorCLI, home: home)
            .first { $0.labelKey == "agents.label.conversationDatabase" }!
        expect(Set(cursorDBs.paths) == Set([home + "/.cursor/chats/project/chat/store.db",
               home + "/.cursor/chats/project/chat/store.db-wal"]),
               "Cursor chat tree crosses its depth or symlink boundary")

        try write(".cursor/extensions/publisher.a-1.0.0/package.json")
        try write(".cursor/extensions/publisher.b-1.0.0/package.json")
        try Data("{\"publisher.a-1.0.0\":true,\"publisher.b-1.0.0\":true}".utf8)
            .write(to: URL(fileURLWithPath: home + "/.cursor/extensions/.obsolete"))
        try Data("[{\"relativeLocation\":\"publisher.b-1.0.0\"}]".utf8)
            .write(to: URL(fileURLWithPath: home + "/.cursor/extensions/extensions.json"))
        expect(AgentCatalog.resolve(.obsoleteExtensions(root: ".cursor/extensions"), home: home)
            == [home + "/.cursor/extensions/publisher.a-1.0.0"],
               "obsolete extension resolution kept an installed version or missed an obsolete one")
        try write(".devin/extensions/extensions.json")
        expect(AgentCatalog.resolve(.obsoleteExtensions(root: ".devin/extensions"), home: home).isEmpty,
               "obsolete extension resolution proceeded without .obsolete")

        if let git = AgentWorktreeInspector.resolvedGit() {
            let mainRepository = home + "/worktree-main"
            try fm.createDirectory(atPath: mainRepository, withIntermediateDirectories: true)
            try run(git, ["-C", mainRepository, "init", "-b", "main"])
            try run(git, ["-C", mainRepository, "config", "user.name", "Nori Tests"])
            try run(git, ["-C", mainRepository, "config", "user.email", "nori@example.invalid"])
            try Data("base".utf8).write(to: URL(fileURLWithPath: mainRepository + "/README.md"))
            try run(git, ["-C", mainRepository, "add", "README.md"])
            try run(git, ["-C", mainRepository, "-c", "commit.gpgsign=false", "commit", "-m", "base"])
            let cleanWorktree = home + "/.cursor/worktrees/repo/wt-clean"
            let dirtyWorktree = home + "/.cursor/worktrees/repo/wt-dirty"
            let unmergedWorktree = home + "/.cursor/worktrees/repo/wt-unmerged"
            try fm.createDirectory(atPath: (cleanWorktree as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            try run(git, ["-C", mainRepository, "worktree", "add", cleanWorktree, "-b", "wt-clean"])
            try run(git, ["-C", mainRepository, "worktree", "add", dirtyWorktree, "-b", "wt-dirty"])
            try run(git, ["-C", mainRepository, "worktree", "add", unmergedWorktree, "-b", "wt-unmerged"])
            try Data("dirty".utf8).write(to: URL(fileURLWithPath: dirtyWorktree + "/untracked.txt"))
            try Data("commit".utf8).write(to: URL(fileURLWithPath: unmergedWorktree + "/new.txt"))
            try run(git, ["-C", unmergedWorktree, "add", "new.txt"])
            try run(git, ["-C", unmergedWorktree, "-c", "commit.gpgsign=false", "commit", "-m", "new"])

            let orphanMain = home + "/worktree-orphan-main"
            try fm.createDirectory(atPath: orphanMain, withIntermediateDirectories: true)
            try run(git, ["-C", orphanMain, "init", "-b", "main"])
            try run(git, ["-C", orphanMain, "config", "user.name", "Nori Tests"])
            try run(git, ["-C", orphanMain, "config", "user.email", "nori@example.invalid"])
            try Data("base".utf8).write(to: URL(fileURLWithPath: orphanMain + "/README.md"))
            try run(git, ["-C", orphanMain, "add", "README.md"])
            try run(git, ["-C", orphanMain, "-c", "commit.gpgsign=false", "commit", "-m", "base"])
            let orphanWorktree = home + "/.cursor/worktrees/orphan/wt-orphan"
            try fm.createDirectory(atPath: (orphanWorktree as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            try run(git, ["-C", orphanMain, "worktree", "add", orphanWorktree, "-b", "wt-orphan"])
            try fm.moveItem(atPath: orphanMain, toPath: home + "/worktree-orphan-main-moved")

            expect(AgentWorktreeInspector.inspect(cleanWorktree, git: git).state == .clean,
                   "merged clean worktree was not classified clean")
            expect(AgentWorktreeInspector.inspect(dirtyWorktree, git: git).state == .dirty,
                   "worktree with untracked changes was not classified dirty")
            expect(AgentWorktreeInspector.inspect(unmergedWorktree, git: git).state == .unmerged,
                   "worktree with an unmerged commit was not classified unmerged")
            expect(AgentWorktreeInspector.inspect(orphanWorktree, git: git).state == .orphaned,
                   "worktree whose main repository moved was not classified orphaned")

            let oldDate = Date().addingTimeInterval(-100 * 24 * 3600)
            for relative in try fm.subpathsOfDirectory(atPath: cleanWorktree) {
                try fm.setAttributes([.modificationDate: oldDate],
                    ofItemAtPath: cleanWorktree + "/" + relative)
            }
            try fm.setAttributes([.modificationDate: oldDate], ofItemAtPath: cleanWorktree)
            try executable(".local/bin/cursor-agent")
            let worktreeReport = AgentInventory.scan(home: home, localize: { key in
                if key == "agents.worktree.clean" { return "clean, merged" }
                if key == "agents.worktree.dirty" { return "uncommitted changes" }
                return key
            }, presence: sandboxPresence, onlyAgentIDs: ["cursor-cli"])
            let worktrees = worktreeReport.categories.first { $0.paths.contains(cleanWorktree) }!
            expect(worktrees.risk == .protected && !worktrees.canSelect
                   && !worktrees.isPathSelected(cleanWorktree) && !worktrees.isPathSelected(dirtyWorktree)
                   && worktrees.pathNotes[cleanWorktree]?.contains("clean, merged") == true
                   && worktrees.pathNotes[dirtyWorktree]?.contains("uncommitted changes") == true
                   && worktrees.pathRetentionBlocked.contains(dirtyWorktree)
                   && !worktrees.pathRetentionBlocked.contains(cleanWorktree),
                   "worktree scan ignored Git state, retention age or status notes")
            try Data("changed".utf8).write(to: URL(fileURLWithPath: cleanWorktree + "/after-scan.txt"))
            let guarded = AgentCleanupExecutor.plan([worktrees.selectingPaths([cleanWorktree])],
                running: RunningApplicationSnapshot(), home: home, presence: sandboxPresence)
            expect(guarded.items.isEmpty, "worktree reached file deletion after scanning")
        } else {
            print("Agent worktree tests: skipped (git unavailable)")
        }

        // 各工具的 home override 语义不同，路径按字面解析，不执行 shell 内容。
        let relocated = home + "/agent roots"
        expect(AgentCatalog.absolute(".gemini/tmp", home: home,
                   environment: ["GEMINI_CLI_HOME": relocated]) == relocated + "/.gemini/tmp"
               && AgentCatalog.absolute(".pi/agent/mcp.json", home: home,
                   environment: ["PI_CODING_AGENT_DIR": relocated]) == relocated + "/mcp.json"
               && AgentCatalog.absolute(".local/share/opencode/log", home: home,
                   environment: ["XDG_DATA_HOME": relocated]) == relocated + "/opencode/log",
               "Agent-specific home override semantics were conflated")
        try write(".codex/config.toml")
        let codexConfig = home + "/.codex/config.toml"
        try ("sqlite_home = '" + relocated + "/databases' # exact setting\nlog_dir = '" + relocated
             + "/logs'\n[profiles.other]\nsqlite_home = '/ignored/profile'\n")
            .write(toFile: codexConfig, atomically: true, encoding: .utf8)
        try write("agent roots/databases/memories_1.sqlite")
        try write("agent roots/databases/memories_1.sqlite-shm")
        let relocatedDBs = AgentCatalog.resolve(codex, home: home)
            .filter { $0.labelKey == "agents.label.stateDatabase" }.flatMap(\.paths)
        expect(AgentCatalog.codexSQLiteDirectory(home: home,
                   environment: ["CODEX_SQLITE_HOME": home + "/ignored-env"]) == relocated + "/databases"
               && relocatedDBs.contains(relocated + "/databases/memories_1.sqlite-shm")
               && AgentCatalog.absolute(".codex/log", home: home) == relocated + "/logs",
               "Codex database/log relocation disagrees with top-level config precedence")
        // 自定义日志/数据库根可以是普通文档目录，绝不能选其父目录。
        try write("Documents/keep.txt")
        try write("Documents/codex-tui.log")
        try write("Documents/state_5.sqlite")
        try ("log_dir = '" + home + "/Documents'\nsqlite_home = '" + home + "/Documents'\n")
            .write(toFile: codexConfig, atomically: true, encoding: .utf8)
        let preciseTargets = AgentCatalog.resolve(codex, home: home)
        expect(preciseTargets.filter { $0.labelKey == "agents.label.logs" }.flatMap(\.paths)
                == [home + "/Documents/codex-tui.log"]
               && !AgentCatalog.dataRoots(for: codex, home: home).contains(home + "/Documents"),
               "custom Codex storage claimed a shared parent directory")
        let absentPresence = AgentPresenceContext(applicationDirs: [], searchPath: [])
        let customOrphans = AgentCatalog.orphanedDataRoots(codex, home: home, presence: absentPresence)
        expect(customOrphans.contains(home + "/Documents/codex-tui.log")
               && !customOrphans.contains(home + "/Documents/state_5.sqlite")
               && !customOrphans.contains(home + "/Documents")
               && !customOrphans.contains(home + "/Documents/keep.txt"),
               "custom Codex orphan roots exceeded exact owned files")
        expect(CleanupRiskPolicy.uninstalledAgentLeftover(path: home + "/Documents/state_5.sqlite",
                   homeDirectory: home, verifiedPaths: Set(customOrphans)).risk == .protected
               && CleanupRiskPolicy.uninstalledAgentLeftover(path: home + "/Documents/keep.txt",
                   homeDirectory: home, verifiedPaths: Set(customOrphans)).risk == .protected,
               "verified orphan policy widened beyond exact candidates")
        try ("developer_instructions = \"\"\"\nlog_dir = '" + home
             + "/Documents'\nsqlite_home = '" + home + "/Documents'\n\"\"\"\n")
            .write(toFile: codexConfig, atomically: true, encoding: .utf8)
        expect(AgentCatalog.absolute(".codex/log", home: home) == home + "/.codex/log"
               && AgentCatalog.codexSQLiteDirectory(home: home) == home + "/.codex",
               "TOML instruction examples were treated as storage settings")
        try fm.removeItem(atPath: codexConfig)
        let crush = AgentCatalog.definitions.first { $0.id == "crush" }!
        let crushCache = crush.targets.first { if case .path(".cache/crush") = $0.kind { return true }; return false }!
        expect(AgentCatalog.targetPaths(crushCache, home: home,
                   environment: ["CRUSH_CACHE_DIR": home + "/Documents"]).isEmpty,
               "custom Crush cache claimed an unrelated shared root")

        try write(".aider/caches/models.json")
        try write(".aider/oauth-keys.env")
        try write(".aider.conf.yml")
        try write(".local/state/goose/logs/server/main.log")
        try write(".local/share/goose/sessions/legacy.jsonl")
        try write(".local/share/goose/sessions/sessions.db")
        try write(".config/goose/secrets.yaml")
        try write("Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/tasks/task-1/history.json")
        try write("Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json")
        try write(".cline/data/secrets.json")
        try write(".cline/data/sessions/session-1/messages.json")
        try write(".continue/sessions/session-1.json")
        try write(".continue/sessions/sessions.json")
        try write(".continue/index/index.sqlite")
        try write(".continue/index/globalContext.json")
        try write(".continue/.env")
        let newAgentIDs = ["aider", "goose", "cline", "continue"]
        for id in newAgentIDs {
            let definition = AgentCatalog.definitions.first { $0.id == id }!
            let targets = AgentCatalog.resolve(definition, home: home, presence: sandboxPresence)
            expect(!targets.isEmpty && targets.contains { $0.tier == .showOnly
                && ($0.labelKey == "agents.label.credentials" || $0.labelKey == "agents.label.configuration") },
                   "\(id) did not expose its documented high-risk configuration or credentials")
            expect(AgentCatalog.isOrphaned(definition, home: home, presence: sandboxPresence),
                   "\(id) data without an app, CLI or host extension was not orphaned")
        }
        let aider = AgentCatalog.definitions.first { $0.id == "aider" }!
        expect(AgentCatalog.resolve(aider, home: home, presence: sandboxPresence).contains {
            $0.labelKey == "agents.label.cache" && $0.tier == .safe
        }, "Aider cache lost its safe classification")
        let goose = AgentCatalog.definitions.first { $0.id == "goose" }!
        let gooseTargets = AgentCatalog.resolve(goose, home: home, presence: sandboxPresence)
        expect(gooseTargets.contains { $0.labelKey == "agents.label.sessions" && $0.tier == .review }
               && gooseTargets.contains { $0.labelKey == "agents.label.conversationDatabase" && $0.tier == .showOnly },
               "Goose legacy sessions or conversation database lost its tier")
        try write("agent roots/data/sessions/redirected.jsonl")
        let gooseSessions = goose.targets.first { $0.labelKey == "agents.label.sessions" }!
        expect(AgentCatalog.targetPaths(gooseSessions, home: home,
                   environment: ["GOOSE_PATH_ROOT": relocated])
                   == [relocated + "/data/sessions/redirected.jsonl"],
               "GOOSE_PATH_ROOT did not redirect the Goose data root")
        let cline = AgentCatalog.definitions.first { $0.id == "cline" }!
        expect(AgentCatalog.resolve(cline, home: home, presence: sandboxPresence).contains {
            $0.labelKey == "agents.label.transcripts" && $0.tier == .review
        }, "Cline host task transcripts were not discovered")
        let continueAgent = AgentCatalog.definitions.first { $0.id == "continue" }!
        let continueTargets = AgentCatalog.resolve(continueAgent, home: home, presence: sandboxPresence)
        let continueSessions = continueTargets.first { $0.labelKey == "agents.label.sessions" }?.paths ?? []
        expect(continueSessions == [home + "/.continue/sessions/session-1.json"]
               && continueTargets.contains { $0.labelKey == "agents.label.credentials"
                   && $0.tier == .showOnly && $0.paths.contains(home + "/.continue/index/globalContext.json") },
               "Continue included sessions.json or merged OAuth state into its derived index")

        // 隐式读取不是所有权：卸载 Cursor 不得把全局 Skill 变成其垃圾。
        try write(".agents/skills/global/SKILL.md")
        let instructionExample = "developer_instructions = '''\n[[skills.config]]\npath = '" + home
            + "/.agents/skills/example'\n[mcp_servers.example]\nurl = 'https://example.invalid/example'\n'''\n"
        try (instructionExample + "[[skills.config]]\npath = '" + home
             + "/.agents/skills/global'\n[mcp_servers.real]\nurl = 'https://example.invalid/real'\n")
            .write(toFile: codexConfig, atomically: true, encoding: .utf8)
        expect(AgentSkillConfigEditor.scan(home: home).map(\.skillPath) == [home + "/.agents/skills/global"]
               && AgentInventory.scanMCP(agents: [codex], home: home, presence: sandboxPresence).map(\.name) == ["real"],
               "TOML multiline examples became real Skill or MCP registrations")
        let removeRealServer = AgentMCPConfigEditor.apply([.init(configPath: codexConfig,
            format: .toml(table: "mcp_servers"), serverName: "real", scope: nil)])
        let removeRealSkill = AgentSkillConfigEditor.apply(AgentSkillConfigEditor.scan(home: home))
        let afterExampleEdits = try String(contentsOfFile: codexConfig, encoding: .utf8)
        expect(removeRealServer.removed == 1 && removeRealSkill.removed == 1
               && afterExampleEdits.hasPrefix(String(instructionExample.dropLast()))
               && AgentSkillConfigEditor.scan(home: home).isEmpty
               && AgentSkillConfigEditor.scanResult(home: home).unresolvedConfigPaths.isEmpty
               && AgentInventory.scanMCP(agents: [codex], home: home, presence: sandboxPresence).isEmpty,
               "TOML resource unlinking damaged multiline text or left real registrations: MCP=\(removeRealServer.removed), Skill=\(removeRealSkill.removed)")
        try "developer_instructions = '''\nunclosed".write(toFile: codexConfig,
            atomically: true, encoding: .utf8)
        let unresolvedSkill = AgentInventory.scanSkills(home: home,
            control: CleanupScanControl(mode: .deep), agents: [codex]).first {
                $0.path == home + "/.agents/skills/global"
            }!
        let uncertainDelete = AgentCleanupExecutor.execute([], running: RunningApplicationSnapshot(),
            home: home, presence: sandboxPresence, trashHandler: trashHandler, skills: [unresolvedSkill])
        expect(!AgentSkillConfigEditor.scanResult(home: home).unresolvedConfigPaths.isEmpty
               && uncertainDelete.refused > 0 && fm.fileExists(atPath: unresolvedSkill.path),
               "an unparseable Skill configuration was treated as proof of no registrations")
        try fm.removeItem(atPath: codexConfig)
        let cursor = AgentCatalog.definitions.first { $0.id == "cursor" }!
        expect(!AgentCatalog.dataRoots(for: cursor, home: home).contains(home + "/.agents/skills")
               && !AgentCatalog.orphanedDataRoots(cursor, home: home, presence: absentPresence)
                    .contains(home + "/.agents/skills"),
               "Cursor compatibility consumers became owners of global Skills")
        let noAgentsReport = AgentInventory.scan(home: home, presence: absentPresence)
        expect(noAgentsReport.skills.contains { $0.path == home + "/.agents/skills/global" && $0.agentID == "shared" },
               "global Skills were hidden after consumer uninstall")
        try write(".claude/skills/implicit/SKILL.md")
        let claudeLeftovers = AgentCatalog.orphanedDataRoots(claude, home: home, presence: sandboxPresence)
        // claude 是安装着的，另用只含 Cursor 的 context 验证隐式消费者保护。
        expect(claudeLeftovers.isEmpty, "an installed CLI produced leftover candidates")
        let cursorOnly = AgentPresenceContext(applicationDirs: sandboxPresence.applicationDirs, searchPath: [])
        let sharedLeftovers = AgentCatalog.orphanedDataRoots(claude, home: home, presence: cursorOnly)
        expect(!sharedLeftovers.contains { $0 == home + "/.claude" || $0.hasPrefix(home + "/.claude/skills") }
               && !sharedLeftovers.contains(home + "/.claude/projects"),
               "orphaned Claude cleanup exposed Skills or retained conversation history")

        // 两个已安装客户端共用实体：分类和勾选只出现一次，守卫保留两方。
        try write("Applications/Devin.app/Contents/Info.plist")
        try write("Applications/Windsurf.app/Contents/Info.plist")
        try write(".codeium/windsurf/cascade/session")
        let sharedReport = AgentInventory.scan(home: home, presence: sandboxPresence)
        let sharedCategories = sharedReport.categories.filter { $0.paths.contains(home + "/.codeium/windsurf/cascade") }
        expect(sharedCategories.count == 1
               && Set(sharedCategories[0].activityOwners).isSuperset(of: ["Devin", "Windsurf"]),
               "shared desktop data was duplicated or lost a consumer guard")
        try fm.removeItem(atPath: home + "/Applications/Devin.app")
        try fm.removeItem(atPath: home + "/Applications/Windsurf.app")

        // IDE 扩展的活宿主既是安装证据，也是目录/Skill/MCP 的运行归属者。
        try executable(".local/bin/code")
        try write(".vscode/extensions/anthropic.claude-code/package.json")
        try Data("{\"publisher\":\"anthropic\",\"name\":\"claude-code\"}".utf8)
            .write(to: URL(fileURLWithPath: home + "/.vscode/extensions/anthropic.claude-code/package.json"))
        let ideOnly = AgentPresenceContext(applicationDirs: [], searchPath: sandboxPresence.searchPath)
        expect(AgentCatalog.isInstalled(claude, home: home, presence: ideOnly)
               && Set(AgentCatalog.runtimeOwners(for: claude, home: home, presence: ideOnly))
                    .isSuperset(of: ["Code", "com.microsoft.VSCode"]),
               "Claude host extension did not contribute installation and runtime owners")
        let ideReport = AgentInventory.scan(home: home, presence: ideOnly)
        var memoryCategory = ideReport.categories.first {
            $0.paths.contains(home + "/.claude/projects/project/memory")
        }!
        memoryCategory.selected = true
        let runningCode = RunningApplicationSnapshot(processNames: ["Code"])
        expect(AgentCleanupExecutor.blockingOwners([memoryCategory], running: runningCode,
                   home: home, presence: ideOnly).isEmpty
               && AgentCleanupExecutor.blockingOwners([memoryCategory.clearingSelection()],
                   running: runningCode, home: home, presence: ideOnly).isEmpty,
               "protected Agent memory requested an unnecessary application close")
        expect(AgentCleanupExecutor.plan([memoryCategory], running: runningCode, home: home,
                   presence: ideOnly).items.isEmpty,
               "a running IDE could lose Agent persistent memory")
        let ideSkill = ideReport.skills.first { $0.path == home + "/.claude/skills/implicit" }!
        expect(AgentCleanupExecutor.blockingOwners([], skills: [ideSkill],
                   running: RunningApplicationSnapshot(processNames: ["Code", "unrelated"]),
                   home: home, presence: ideOnly) == ["Code"]
               && AgentCleanupExecutor.blockingOwners([], skills: [ideSkill],
                   running: RunningApplicationSnapshot(), home: home, presence: ideOnly).isEmpty,
               "Skill owner preflight missed an implicit consumer or retained a closed owner")
        let blockedSkill = AgentCleanupExecutor.execute([], running: runningCode, home: home,
            presence: ideOnly, trashHandler: trashHandler, skills: [ideSkill])
        expect(blockedSkill.refused > 0 && fm.fileExists(atPath: ideSkill.path)
               && blockedSkill.summary.messages.contains { $0.contains("owner is running (Code)") && $0.contains(ideSkill.path) },
               "a running IDE could lose its implicitly consumed Skill")
        try Data("{\"mcpServers\":{\"fixture\":{\"url\":\"https://example.invalid/mcp\"}}}".utf8)
            .write(to: URL(fileURLWithPath: home + "/.claude.json"))
        let ideServer = AgentInventory.scanMCP(agents: [claude], home: home, presence: ideOnly).first!
        expect(AgentCleanupExecutor.blockingOwners([], servers: [ideServer], running: runningCode,
                   home: home, presence: ideOnly) == ["Code"],
               "MCP registration preflight missed its live host IDE")
        let blockedServer = AgentCleanupExecutor.execute([], running: runningCode, home: home,
            presence: ideOnly, trashHandler: trashHandler, servers: [ideServer])
        expect(blockedServer.refused > 0
               && blockedServer.summary.messages.contains { $0.contains("owner is running (Code)") && $0.contains(ideServer.configPath) }
               && AgentInventory.scanMCP(agents: [claude], home: home, presence: ideOnly).count == 1,
               "a running IDE could lose its MCP registration")
        try fm.removeItem(atPath: home + "/.claude.json")
        try fm.removeItem(atPath: home + "/.vscode/extensions")
        try fm.removeItem(atPath: home + "/.local/bin/code")

        // 用户产物和持久 VM 磁盘不得因能再次下载而成为默认安全项。
        let claudeDesktop = AgentCatalog.definitions.first { $0.id == "claude-desktop" }!
        expect(claudeDesktop.targets.first { $0.labelKey == "agents.label.vmBundles" }?.tier != .safe
               && antigravity.targets.first { $0.labelKey == "agents.label.browserRecordings" }?.tier != .safe,
               "VM state or task recordings are preselected as rebuildable cache")
        let chromeMCP = AgentCatalog.definitions.first { $0.id == "chrome-devtools-mcp" }!
        expect(chromeMCP.targets.contains {
            if case .path(let path) = $0.kind { return path.hasSuffix("Service Worker/CacheStorage") && $0.tier == .review }
            return false
        }, "offline site CacheStorage is still default-selected as harmless cache")

        // --- 目录不变量。
        for agent in AgentCatalog.definitions {
            for target in agent.targets where agent.documented && target.tier == .review {
                let openFileGuardedTarget = (target.owners ?? agent.owners).isEmpty
                    && (agent.id == "codex" && target.labelKey == "agents.label.sessions"
                        || agent.id == "grok" && target.labelKey == "agents.label.worktrees"
                        || agent.id == "playwright" && target.labelKey == "agents.label.runtime")
                expect(openFileGuardedTarget || !(target.owners ?? agent.owners).isEmpty,
                       "\(agent.id) review target \(target.labelKey) has no owner process guard")
            }
        }
        // --- 残留判定：已卸载工具整体退出 Agent 漏斗，交由清理扫描按磁盘垃圾收录。
        try write("Library/Application Support/Kiro/Cache/entry")
        let kiro = AgentCatalog.definitions.first { $0.id == "kiro" }!
        expect(AgentCatalog.resolve(kiro, home: home, presence: sandboxPresence)
            .allSatisfy { $0.tier == .review },
               "orphaned undocumented tool stayed show-only")
        expect(!AgentCatalog.deletablePaths(home: home, presence: sandboxPresence)
            .contains(home + "/Library/Application Support/Kiro"),
               "orphaned leftovers must move to the cleanup funnel, not the agent funnel")
        let sandboxReport = AgentInventory.scan(home: home, presence: sandboxPresence)
        expect(sandboxReport.groups.contains { $0.id == "kiro" && $0.orphaned }
               && sandboxReport.categories.filter { $0.paths.contains(home + "/Library/Application Support/Kiro") }
                   .allSatisfy { !$0.selected },
               "orphaned Agent data must remain visible without becoming selected")
        try write("Applications/Kiro.app/Contents/Info.plist")
        expect(AgentCatalog.resolve(kiro, home: home, presence: sandboxPresence)
            .allSatisfy { $0.tier != .safe && !$0.owners.isEmpty },
               "installed undocumented tool lost its risk/owner review guard")
        let kiroReport = AgentInventory.scan(home: home, presence: sandboxPresence)
        expect(kiroReport.groups.contains { $0.id == "kiro" }
               && kiroReport.categories.filter { $0.paths.contains(home + "/Library/Application Support/Kiro") }
                   .allSatisfy { !$0.canSelect && $0.risk == .protected && !$0.selected },
               "installed undocumented tool exposed unknown state to filesystem deletion")
        try? fm.removeItem(atPath: home + "/Applications/Kiro.app")

        // --- 扫描报告：清理建议默认勾选，当前会话和状态数据仍须手动选择。
        try write(".claude/projects/-Users-me-repo/session.jsonl")
        try write(".claude/statsig/cache")
        try write("Library/Application Support/Cursor/snapshots/checkpoint")
        try write(".codex/cache/rebuildable-entry")
        try write(".claude/debug/diagnostic.log")
        try write(".claude/skills/writer/SKILL.md")
        try Data("---\nname: writer\ndescription: \"Writes docs\"\n---\nbody\n".utf8)
            .write(to: URL(fileURLWithPath: home + "/.claude/skills/writer/SKILL.md"))
        try fm.createDirectory(atPath: home + "/.agents/skills/shared-skill", withIntermediateDirectories: true)
        try write(".agents/skills/shared-skill/SKILL.md")
        try link(".cursor/skills/shared-skill", to: home + "/.agents/skills/shared-skill")
        let report = AgentInventory.scan(home: home, presence: sandboxPresence)
        let statsig = report.categories.first { $0.paths.contains(home + "/.claude/statsig") }
        expect(statsig?.risk == .safe && statsig?.allSelected == true, "safe agent cache not preselected")
        let pageReport = AgentInventory.scan(home: home, presence: sandboxPresence, excludingGlobalCleanupCaches: true)
        expect(!pageReport.categories.contains { $0.paths.contains(home + "/.claude/statsig") }
               && CleanupRiskPolicy.isCoveredByGlobalCleanup(home + "/.claude/statsig", homeDirectory: home)
               && pageReport.categories.contains { $0.paths.contains(home + "/.claude/projects/-Users-me-repo/session.jsonl") },
               "the Agent page must leave rebuildable caches to the cleanup page and keep Agent data")
        let checkpoints = report.categories.first {
            $0.paths.contains(home + "/Library/Application Support/Cursor/snapshots")
        }
        expect(checkpoints?.selected == false && checkpoints?.risk == .protected
               && checkpoints?.retentionClass == nil
               && checkpoints?.activityOwners == ["Cursor", "com.todesktop.230313mzl4w4u92"],
               "recent checkpoints ignored retention or lost their risk/owner guard")
        let oldSession = home + "/.codex/sessions/2026/03/05/rollout-a.jsonl"
        let recentSession = home + "/.codex/sessions/2026/06/01/rollout-b.jsonl"
        let futureSession = home + "/.codex/sessions/2026/06/02/rollout-future.jsonl"
        let sessions = report.categories.first { $0.paths.contains(oldSession) }!
        expect(sessions.paths.contains(recentSession) && sessions.paths.contains(futureSession)
               && !sessions.isPathSelected(oldSession) && !sessions.isPathSelected(recentSession)
               && !sessions.isPathSelected(futureSession) && sessions.pathNotes[oldSession] != nil
               && sessions.pathNotes[recentSession] != nil && sessions.retentionClass == nil
               && sessions.retention == 0 && sessions.risk == .protected && !sessions.canSelect,
               "session retention exposed history files to cleanup")
        var neverRetention = AgentRetentionPreferences()
        neverRetention.conversations = .never
        let neverSessions = AgentInventory.scan(home: home, presence: sandboxPresence,
            onlyAgentIDs: ["codex"], retention: neverRetention).categories.first {
                $0.paths.contains(oldSession)
            }!
        expect(!neverSessions.selected && neverSessions.paths.contains(recentSession),
               "never-clean retention hid or selected conversation history")
        var sevenDayRetention = AgentRetentionPreferences()
        sevenDayRetention.conversations = .days(7)
        let sevenDaySessions = AgentInventory.scan(home: home, presence: sandboxPresence,
            onlyAgentIDs: ["codex"], retention: sevenDayRetention).categories.first {
                $0.paths.contains(oldSession)
            }!
        expect(!sevenDaySessions.selected && !sevenDaySessions.canSelect,
               "seven-day retention bypassed managed history protection")
        let policyHome = fixture.appendingPathComponent("per-agent-retention-home").path
        for agent in ["codex", "grok"] {
            try fm.createDirectory(atPath: policyHome + "/.local/bin", withIntermediateDirectories: true)
            let executablePath = policyHome + "/.local/bin/" + agent
            try Data("#!/bin/sh\n".utf8).write(to: URL(fileURLWithPath: executablePath))
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executablePath)
            let sessionRoot = policyHome + "/." + agent + "/sessions"
            try fm.createDirectory(atPath: sessionRoot, withIntermediateDirectories: true)
            let sessionPath = sessionRoot + "/old.jsonl"
            try Data("history".utf8).write(to: URL(fileURLWithPath: sessionPath))
            try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-100 * 24 * 3600)],
                ofItemAtPath: sessionPath)
        }
        var scopedRetention = AgentRetentionPreferences()
        scopedRetention.set(.never, for: .conversations, agentID: "codex")
        scopedRetention.set(.days(7), for: .conversations, agentID: "grok")
        let scopedReport = AgentInventory.scan(home: policyHome,
            presence: AgentPresenceContext(applicationDirs: [policyHome + "/Applications"],
                searchPath: [policyHome + "/.local/bin"]), onlyAgentIDs: ["codex", "grok"],
            retention: scopedRetention)
        let keptHistory = scopedReport.categories.first { $0.paths.contains(policyHome + "/.codex/sessions/old.jsonl") }!
        let expiredHistory = scopedReport.categories.first { $0.paths.contains(policyHome + "/.grok/sessions/old.jsonl") }!
        expect(!keptHistory.selected && keptHistory.retention == 0
               && !expiredHistory.selected && expiredHistory.retention == 0
               && keptHistory.risk == .protected && expiredHistory.risk == .protected,
               "another Agent's retention bypassed managed history protection")

        let activityHome = fixture.appendingPathComponent("activity-home").path
        let activityPresence = AgentPresenceContext(applicationDirs: [activityHome + "/Applications"],
            searchPath: [activityHome + "/.local/bin"])
        try fm.createDirectory(atPath: activityHome + "/.local/bin", withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: URL(fileURLWithPath: activityHome + "/.local/bin/codex"))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: activityHome + "/.local/bin/codex")
        let activitySession = activityHome + "/.codex/sessions/2025/old.jsonl"
        try fm.createDirectory(atPath: (activitySession as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        try Data("old".utf8).write(to: URL(fileURLWithPath: activitySession))
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-200 * 24 * 3600)],
            ofItemAtPath: activitySession)
        let unusedGroup = AgentInventory.scan(home: activityHome, presence: activityPresence,
            onlyAgentIDs: ["codex"]).groups.first { $0.id == "codex" }!
        expect(unusedGroup.unused && unusedGroup.lastActivity != nil,
               "an Agent with only 200-day-old targets was not marked unused")
        let recentActivity = activityHome + "/.codex/sessions/2026/recent.jsonl"
        try fm.createDirectory(atPath: (recentActivity as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        try Data("recent".utf8).write(to: URL(fileURLWithPath: recentActivity))
        let activeGroup = AgentInventory.scan(home: activityHome, presence: activityPresence,
            onlyAgentIDs: ["codex"]).groups.first { $0.id == "codex" }!
        expect(!activeGroup.unused, "recent Agent activity did not clear the unused badge")
        expect(report.categories.first { $0.paths.contains(home + "/.codex/cache") }?.allSelected == true
               && report.categories.first { $0.paths.contains(home + "/.claude/debug") }?.allSelected == true,
               "reviewed Agent caches/logs were discarded from default cleanup selection")
        let projects = report.categories.first { $0.paths.contains(home + "/.claude/projects/-Users-me-repo/session.jsonl") }
        expect(projects?.risk == .protected && projects?.selected == false
               && projects?.activityOwners == ["claude"], "review item preselected or unguarded")
        let state = report.categories.first { $0.paths.contains(home + "/.codex/state_5.sqlite") }
        expect(state?.risk == .protected && state?.canSelect == false && state?.selected == false,
               "state database must remain read-only")
        let warpDatabase = report.categories.first { $0.paths.contains(home + "/" + warpRelatives[0]) }!
        expect(warpDatabase.risk == .protected && !warpDatabase.canSelect && !warpDatabase.selected
               && warpDatabase.reasonKey == "agents.reason.managedHistory" && Set(warpDatabase.paths) == warpPaths,
               "Warp database must remain read-only")
        let selectedWarp = warpDatabase.selectingPaths(warpDatabase.paths)
        expect(!selectedWarp.selected,
               "protected Warp database accepted a manual selection")
        expect(report.categories.allSatisfy { $0.activityGuard == .aiAgent }, "agent category lost its guard")
        let writer = report.skills.first { $0.path == home + "/.claude/skills/writer" }
        expect(writer?.name == "writer" && writer?.summary == "Writes docs" && writer?.linked == false,
               "SKILL.md front matter not parsed")
        let linked = report.skills.first { $0.path == home + "/.cursor/skills/shared-skill" }
        expect(linked?.linked == true && linked?.identity.isEmpty == false,
               "linked skill has no unlink identity")

        // --- 策略：Warning + aiAgent 仅在手动模式、归属者未运行、进程表完整时可执行。
        let review = projects!
        let idle = RunningApplicationSnapshot(processNames: ["Finder"])
        let staleSession = sessions.selectingPaths([oldSession])
        expect(AgentCleanupExecutor.plan([staleSession], running: idle, home: home,
                   presence: sandboxPresence).items.isEmpty,
               "an expired session entered the filesystem execution plan")
        try touch(".codex/sessions/2026/03/05/rollout-a.jsonl", secondsAgo: 0)
        let reactivatedSession = AgentCleanupExecutor.plan([staleSession], running: idle,
            home: home, presence: sandboxPresence)
        expect(reactivatedSession.items.isEmpty,
               "a session used after scanning entered the execution plan")
        try touch(".codex/sessions/2026/03/05/rollout-a.jsonl", secondsAgo: 100 * 24 * 3600)

        try write(".codex/models_cache.json")
        try write(".codex/attachments/mixed-review.bin")
        try touch(".codex/attachments/mixed-review.bin", secondsAgo: 100 * 24 * 3600)
        let mixedTrashRoot = fixture.appendingPathComponent("mixed-trash")
        let mixedReport = AgentInventory.scan(home: home, presence: sandboxPresence,
            onlyAgentIDs: ["codex"])
        let mixedSafe = mixedReport.categories.first {
            $0.paths.contains(home + "/.codex/models_cache.json")
        }!
        let mixedReview = mixedReport.categories.first {
            $0.paths.contains(home + "/.codex/attachments/mixed-review.bin")
        }!
        let mixedDisposal = AgentCleanupExecutor.execute([mixedSafe, mixedReview], running: idle,
            home: home, presence: sandboxPresence, trashHandler: { url in
                try fm.createDirectory(at: mixedTrashRoot, withIntermediateDirectories: true)
                try fm.moveItem(at: url, to: mixedTrashRoot.appendingPathComponent(url.lastPathComponent))
            })
        expect(mixedDisposal.summary.removed == 1
               && !fm.fileExists(atPath: home + "/.codex/models_cache.json")
               && !fm.fileExists(atPath: mixedTrashRoot.appendingPathComponent("models_cache.json").path)
               && fm.fileExists(atPath: home + "/.codex/attachments/mixed-review.bin"),
               "mixed cleanup did not preserve history attachments beside disposable cache: \(mixedDisposal.summary.messages)")
        let busy = RunningApplicationSnapshot(processNames: ["claude"])
        var selectedReview = review
        selectedReview.selected = true
        expect(!CleanupRiskPolicy.isEligible(selectedReview, mode: .manual, running: idle),
               "idle agent history became executable")
        expect(!CleanupRiskPolicy.isEligible(selectedReview, mode: .manual, running: busy),
               "review item executable while its agent runs")
        expect(!CleanupRiskPolicy.isEligible(selectedReview, mode: .manual, running: .unavailable),
               "review item executable without a process snapshot")
        expect(!CleanupRiskPolicy.isEligible(selectedReview, mode: .quickClean, running: idle)
               && !CleanupRiskPolicy.isEligible(selectedReview, mode: .automatic, running: idle),
               "review item reached quick or automatic cleanup")
        let plainWarning = CleanupCategory(name: "x", paths: [home + "/.claude/projects/-Users-me-repo"],
                                           bytes: 1, selected: true, risk: .warning,
                                           disposal: .permanentDelete, applyRoute: .genericTrash,
                                           activityGuard: .unsupported)
        expect(!CleanupRiskPolicy.isEligible(plainWarning, mode: .manual, running: idle),
               "an ordinary Warning filesystem deletion became executable")
        var selectedState = state!
        selectedState.selected = true
        expect(AgentCleanupExecutor.plan([selectedState], running: idle, home: home,
            presence: sandboxPresence).items.isEmpty,
               "a manually selected state database reached the deletion plan")
        expect(AgentCleanupExecutor.plan([selectedState], running: RunningApplicationSnapshot(processNames: ["codex"]),
            home: home, presence: sandboxPresence).items.isEmpty,
               "sensitive state deletion ignored a running owner")
        let runningWarp = RunningApplicationSnapshot(bundleIdentifiers: ["dev.warp.Warp-Stable"])
        for snapshot in [runningWarp, .unavailable] {
            expect(AgentCleanupExecutor.plan([selectedWarp], running: snapshot, home: home,
                presence: sandboxPresence).items.isEmpty,
                   "Warp database deletion must wait until its owner is verified idle")
        }
        expect(Set(AgentCleanupExecutor.blockingResources([selectedWarp], running: runningWarp,
            home: home, presence: sandboxPresence).paths).isEmpty,
               "protected Warp database requested an unnecessary application close")
        expect(Set(AgentCleanupExecutor.plan([selectedWarp], running: idle, home: home,
            presence: sandboxPresence).items.map(\.record)).isEmpty,
               "idle Warp data reached the deletion plan")

        // 卸载后父节点清理：CLI 消失仍可清理已确认的精确目录，不能扩大到其它 Agent。
        let noCLI = AgentPresenceContext(applicationDirs: [], searchPath: [])
        expect(AgentCleanupExecutor.plan([selectedState], running: idle, home: home,
            presence: noCLI).items.isEmpty, "ordinary cleanup accepted an absent agent")
        let removalPlan = AgentCleanupExecutor.plan([selectedState], running: idle, home: home,
            presence: noCLI, removingAgentID: "codex")
        expect(removalPlan.items.isEmpty,
               "CLI uninstall authorized deletion of retained Codex state")
        var expandedRemoval = selectedState
        expandedRemoval.appendPath(home + "/.claude/projects/-Users-me-repo/session.jsonl", bytes: 1)
        expandedRemoval.selected = true
        expect(!AgentCleanupExecutor.plan([expandedRemoval], running: idle, home: home,
            presence: noCLI, removingAgentID: "codex").items.contains {
                $0.record.contains("/.claude/")
            }, "CLI removal expanded to another agent")
        expect(AgentCleanupExecutor.plan([selectedState], running: RunningApplicationSnapshot(processNames: ["codex"]),
            home: home, presence: noCLI, removingAgentID: "codex").items.isEmpty,
               "CLI removal cleanup ignored a running owner")

        // --- 执行计划：目录不再认领的路径与伪造的 Skill 被拒绝。
        var forged = review
        forged.risk = .warning
        forged.disposal = .permanentDelete
        forged.applyRoute = .aiTrash
        forged.retention = 0
        forged.appendPath(home + "/.claude/skills/writer", bytes: 1)
        forged.selected = true
        let plan = AgentCleanupExecutor.plan([forged], running: idle, home: home, presence: sandboxPresence)
        expect(plan.items.isEmpty && plan.refused == forged.paths.count,
               "catalog revalidation admitted history or a path outside the review target")
        let bogusSkill = CleanupCategory(
            name: "Skills", paths: [home + "/.claude/projects/-Users-me-repo"], bytes: 1,
            selected: true, source: .aiSession, risk: .warning, disposal: .permanentDelete,
            applyRoute: .aiTrash, activityGuard: .aiAgent, reasonKey: "agents.reason.skill")
        expect(AgentCleanupExecutor.plan([bogusSkill], running: idle, home: home,
                                        presence: sandboxPresence).items.isEmpty,
               "a non-skill path passed the skill revalidation")

        // 运行中的客户端不应挡住普通缓存；只有同一分类中的注册资源继续要求关闭消费者。
        try write("Library/Application Support/Cursor/Cache/entry")
        try write("Library/Application Support/Cursor/Code Cache/entry")
        try write("Applications/Codex.app/Contents/Info.plist")
        try write("Library/Caches/com.openai.codex/entry")
        try write("Library/Application Support/Codex/Cache/entry")
        try write(".codex/log/idle.log")
        // Codex 环境缓存：Blender 安装镜像/校验值可弃，Blender.app 与主运行时
        // 只做复核，无关同名邻居不认领。
        try write(".cache/codex-blender/blender-4.5.9-macos-arm64.dmg")
        try write(".cache/codex-blender/blender-4.5.9-macos-arm64.dmg.sha256")
        try write(".cache/codex-blender/Blender.app/Contents/Info.plist")
        try write(".cache/codex-runtimes/codex-runtime-install-jnYG91/payload")
        try write(".cache/codex-runtimes/codex-primary-runtime/bin/python")
        try write(".cache/codex-runtimes/codex-unrelated/keep")
        let cursorCache = home + "/Library/Application Support/Cursor/Cache"
        let cursorCodeCache = home + "/Library/Application Support/Cursor/Code Cache"
        let liveReport = AgentInventory.scan(home: home, presence: sandboxPresence)
        let cacheCategory = liveReport.categories.first { $0.paths.contains(cursorCache) }!
        let codexCacheCategory = liveReport.categories.first {
            $0.paths.contains(home + "/Library/Caches/com.openai.codex")
        }!
        let codexAppCacheCategory = liveReport.categories.first {
            $0.paths.contains(home + "/Library/Application Support/Codex/Cache")
        }!
        let codexLogsCategory = liveReport.categories.first { $0.paths.contains(home + "/.codex/log") }!
        let blender = home + "/.cache/codex-blender"
        let runtimes = home + "/.cache/codex-runtimes"
        expect(liveReport.categories.contains {
            $0.name == "agents.label.installerImage" && $0.risk == .safe
            && Set($0.paths) == Set([blender + "/blender-4.5.9-macos-arm64.dmg",
                                     blender + "/blender-4.5.9-macos-arm64.dmg.sha256"])
        }, "codex-blender installer images lost their safe tier")
        expect(liveReport.categories.contains {
            $0.name == "agents.label.bundledApp" && $0.risk != .safe
            && $0.paths == [blender + "/Blender.app"]
        }, "Blender.app must stay a review-tier bundle")
        expect(liveReport.categories.contains {
            $0.name == "agents.label.updateStaging" && $0.risk == .safe
            && $0.paths.contains(runtimes + "/codex-runtime-install-jnYG91")
        }, "leftover codex-runtime-install-* staging lost its safe tier")
        expect(liveReport.categories.contains {
            $0.name == "agents.label.runtime" && $0.risk != .safe
            && $0.paths == [runtimes + "/codex-primary-runtime"]
        }, "codex-primary-runtime must stay a review-tier target")
        expect(!liveReport.categories.contains { category in
            category.paths.contains { $0.contains("codex-unrelated") }
        }, "unmatched codex-runtimes sibling offered")
        let runningClients = RunningApplicationSnapshot(processNames: ["Cursor", "codex"])
        let codexSafeCategories = [codexCacheCategory, codexAppCacheCategory, codexLogsCategory]
        let safePlan = AgentCleanupExecutor.plan([cacheCategory] + codexSafeCategories,
            running: runningClients, home: home, presence: sandboxPresence)
        expect(safePlan.refused == 0 && safePlan.liveTargets == Set([
                   cursorCache, cursorCodeCache, home + "/Library/Caches/com.openai.codex",
                   home + "/Library/Application Support/Codex/Cache", home + "/.codex/log"])
               && AgentCleanupExecutor.blockingOwners([cacheCategory] + codexSafeCategories,
                   running: runningClients, home: home, presence: sandboxPresence).isEmpty,
               "a running Agent still blocks its ordinary rebuildable caches")
        var cacheProgress: [(Int, Int, String)] = []
        let codexCacheCleanup = AgentCleanupExecutor.execute(codexSafeCategories,
            running: runningClients, home: home, presence: sandboxPresence, trashHandler: trashHandler,
            onProgress: { cacheProgress.append(($0, $1, $2)) })
        expect(cacheProgress.first?.0 == 0 && cacheProgress.last?.0 == 3
               && cacheProgress.allSatisfy { $0.1 == 3 }
               && zip(cacheProgress, cacheProgress.dropFirst()).allSatisfy { $0.0.0 <= $0.1.0 },
               "Agent cache progress did not aggregate its submitted roots monotonically")
        expect(codexCacheCleanup.refused == 0 && codexCacheCleanup.summary.skipped == 0
               && codexCacheCleanup.summary.removedPaths == Set([
                   home + "/Library/Caches/com.openai.codex/entry",
                   home + "/Library/Application Support/Codex/Cache/entry", home + "/.codex/log/idle.log"])
               && codexSafeCategories.flatMap(\.paths).allSatisfy(AgentCatalog.exists),
               "freshly verified Codex caches/logs were blocked by a broad persistent-data prefix: \(codexCacheCleanup.summary.messages)")
        // Exercise parallel root completion and leaf updates repeatedly. A slow
        // observer widens the overlap window and must still receive serial events.
        for round in 0..<16 {
            for root in codexSafeCategories.flatMap(\.paths) {
                for leaf in 0..<8 {
                    try Data("fixture".utf8).write(to: URL(fileURLWithPath: root + "/stress-\(leaf)"))
                }
            }
            let observerLock = NSLock()
            var activeCallbacks = 0
            var overlappingCallbacks = false
            var events: [(Int, Int)] = []
            let stressCleanup = AgentCleanupExecutor.execute(codexSafeCategories,
                running: runningClients, home: home, presence: sandboxPresence, trashHandler: trashHandler,
                onProgress: { completed, total, _ in
                    observerLock.lock()
                    activeCallbacks += 1
                    overlappingCallbacks = overlappingCallbacks || activeCallbacks > 1
                    events.append((completed, total))
                    observerLock.unlock()
                    Thread.sleep(forTimeInterval: 0.001)
                    observerLock.lock()
                    activeCallbacks -= 1
                    observerLock.unlock()
                })
            expect(!overlappingCallbacks && events.first?.0 == 0 && events.last?.0 == 3
                   && events.allSatisfy { $0.1 == 3 }
                   && zip(events, events.dropFirst()).allSatisfy { $0.0.0 <= $0.1.0 }
                   && stressCleanup.summary.removedPaths.count == 24,
                   "parallel Agent progress overlapped, regressed or lost a root in round \(round)")
        }
        let unknownRuntime = AgentCleanupExecutor.blockingResources([cacheCategory, selectedState],
            running: .unavailable, home: home, presence: sandboxPresence)
        expect(unknownRuntime.paths.isEmpty && unknownRuntime.owners.isEmpty
               && AgentCleanupExecutor.plan([cacheCategory], running: .unavailable,
                   home: home, presence: sandboxPresence).liveTargets == Set(cacheCategory.paths),
               "unknown runtime blocks unused caches or permits persistent Agent data")
        var forgedSafeState = selectedState
        forgedSafeState.risk = .safe
        let forgedSafePlan = AgentCleanupExecutor.plan([forgedSafeState], running: idle,
            home: home, presence: sandboxPresence)
        expect(forgedSafePlan.liveTargets.isEmpty
               && AgentCleanupExecutor.plan([forgedSafeState], running: runningClients,
                   home: home, presence: sandboxPresence).items.isEmpty,
               "a forged safe risk bypassed fresh persistent-data classification")

        let cacheSkill = cursorCache + "/registered-skill"
        try write("Library/Application Support/Cursor/Cache/registered-skill/SKILL.md")
        try executable("Library/Application Support/Cursor/Cache/fixture-mcp")
        let cacheSkillConfiguration = """
        [[skills.config]]
        path = "\(cacheSkill)"
        enabled = true
        """
        try cacheSkillConfiguration.write(toFile: home + "/.codex/config.toml",
            atomically: true, encoding: .utf8)
        expect(AgentCleanupExecutor.blockingResources([cacheCategory],
                   running: RunningApplicationSnapshot(bundleIdentifiers: ["com.openai.codex"]),
                   home: home, presence: sandboxPresence).paths == [cursorCache]
               && AgentCleanupExecutor.plan([cacheCategory],
                   running: RunningApplicationSnapshot(bundleIdentifiers: ["com.openai.codex"]),
                   home: home, presence: sandboxPresence).liveTargets == [cursorCodeCache],
               "a Skill declaration alone did not protect its body inside an otherwise safe cache")
        try Data("{\"mcpServers\":{\"cache-mcp\":{\"command\":\"\(cursorCache)/fixture-mcp\"}}}".utf8)
            .write(to: URL(fileURLWithPath: home + "/.cursor/mcp.json"))
        let registeredCacheReport = AgentInventory.scan(home: home, presence: sandboxPresence)
        expect(!registeredCacheReport.categories.flatMap(\.paths).contains {
            $0 == cursorCache || $0 == cacheSkill || $0.hasPrefix(cacheSkill + "/")
                || $0 == cursorCache + "/fixture-mcp"
        }, "fresh cache scan included registered Skill/MCP bodies as disposable junk")
        // A previously selected broad root must still retain its stronger
        // consumer guard after fresh discovery splits out registered bodies.
        let registeredCacheCategory = cacheCategory
        let registeredCacheServer = registeredCacheReport.servers.first { $0.name == "cache-mcp" }!
        let registeredCacheInstallation = registeredCacheReport.installations.first {
            $0.path == cursorCache + "/fixture-mcp"
        }!
        let blockedCache = AgentCleanupExecutor.blockingResources([registeredCacheCategory],
            installations: [registeredCacheInstallation], servers: [registeredCacheServer],
            running: runningClients, home: home, presence: sandboxPresence)
        expect(blockedCache.paths == [cursorCache]
               && blockedCache.installationIDs == [registeredCacheInstallation.id]
               && blockedCache.serverIDs == [registeredCacheServer.id]
               && Set(blockedCache.owners).isSuperset(of: ["Cursor", "codex"]),
               "registered Skill/MCP data in a cache bypassed consumer guards or blocked its sibling")
        let unknownResources = AgentCleanupExecutor.blockingResources([registeredCacheCategory, selectedState],
            skills: [writer!], installations: [registeredCacheInstallation], servers: [registeredCacheServer],
            running: .unavailable, home: home, presence: sandboxPresence)
        expect(unknownResources.paths == [cursorCache]
               && unknownResources.skillPaths == [writer!.path]
               && unknownResources.installationIDs == [registeredCacheInstallation.id]
               && unknownResources.serverIDs == [registeredCacheServer.id] && unknownResources.owners.isEmpty,
               "unknown runtime did not preserve sensitive data, Skill bodies, MCP installations and registrations")
        let mixedPlan = AgentCleanupExecutor.plan([registeredCacheCategory], running: runningClients,
            home: home, presence: sandboxPresence)
        expect(mixedPlan.refused == 1 && mixedPlan.liveTargets == [cursorCodeCache]
               && mixedPlan.items.map(\.record) == [cursorCodeCache],
               "a blocked cache path prevented the ready sibling from entering the plan")
        let stoppedRegisteredPlan = AgentCleanupExecutor.plan([registeredCacheCategory], running: idle,
            home: home, presence: sandboxPresence)
        expect(stoppedRegisteredPlan.items.count == 2
               && stoppedRegisteredPlan.liveTargets == [cursorCodeCache],
               "registered resources were assigned partial cache cleanup instead of their guarded operation")
        var mixedProgress: [(Int, Int, String)] = []
        let mixedCleanup = AgentCleanupExecutor.execute([registeredCacheCategory],
            running: runningClients, home: home, presence: sandboxPresence, trashHandler: trashHandler,
            onProgress: { mixedProgress.append(($0, $1, $2)) })
        expect(mixedProgress.first?.0 == 0 && mixedProgress.last?.0 == 2
               && mixedProgress.allSatisfy { $0.1 == 2 }
               && mixedProgress.contains { $0.0 == 1 }
               && zip(mixedProgress, mixedProgress.dropFirst()).allSatisfy { $0.0.0 <= $0.1.0 },
               "Agent progress failed to complete an owner-refused root beside a cleaned cache")
        expect(mixedCleanup.refused == 1 && mixedCleanup.summary.removed > 0
               && AgentCatalog.exists(cursorCache + "/fixture-mcp") && AgentCatalog.exists(cacheSkill)
               && AgentCatalog.exists(cursorCodeCache) && !AgentCatalog.exists(cursorCodeCache + "/entry")
               && (try? String(contentsOfFile: home + "/.codex/config.toml", encoding: .utf8)) == cacheSkillConfiguration
               && AgentInventory.scanMCP(agents: [AgentCatalog.definitions.first { $0.id == "cursor" }!],
                   home: home, presence: sandboxPresence).contains { $0.name == "cache-mcp" },
               "mixed cleanup failed to remove unused cache leaves or mutated active Skill/MCP resources: \(mixedCleanup.summary.messages)")
        try fm.removeItem(atPath: home + "/.codex/config.toml")
        expect(AgentCleanupExecutor.blockingResources([registeredCacheCategory],
                   running: RunningApplicationSnapshot(processNames: ["Cursor"]),
                   home: home, presence: sandboxPresence).paths == [cursorCache]
               && AgentCleanupExecutor.plan([registeredCacheCategory],
                   running: RunningApplicationSnapshot(processNames: ["Cursor"]),
                   home: home, presence: sandboxPresence).liveTargets == [cursorCodeCache],
               "an MCP registration alone did not protect its executable inside an otherwise safe cache")
        try fm.removeItem(atPath: home + "/.cursor/mcp.json")
        try fm.removeItem(atPath: cursorCache)
        try fm.removeItem(atPath: cursorCodeCache)
        try fm.removeItem(atPath: home + "/Library/Caches/com.openai.codex")
        try fm.removeItem(atPath: home + "/Library/Application Support/Codex")
        try fm.removeItem(atPath: home + "/.codex/log")
        try fm.removeItem(atPath: home + "/Applications/Codex.app")

        // --- 漏斗：SQLite 族原子处理；verifiedTargets 只解除名字/扩展名拦截。
        var logCategory = report.categories.first { $0.paths.contains(home + "/.codex/logs_2.sqlite") }!
        logCategory.selected = false
        logCategory.setPathSelected(home + "/.codex/logs_2.sqlite", selected: true)
        let partialPlan = AgentCleanupExecutor.plan([logCategory], running: idle, home: home,
                                                   presence: sandboxPresence)
        expect(partialPlan.families.contains { $0.contains(home + "/.codex/logs_2.sqlite-wal") },
               "unselected live companions were not added to the atomic family")
        let partial = AgentCleanupExecutor.execute([logCategory], running: idle, home: home,
                                                  presence: sandboxPresence, trashHandler: trashHandler)
        expect(partial.summary.removed == 0 && fm.fileExists(atPath: home + "/.codex/logs_2.sqlite"),
               "a SQLite file was removed without its companions")
        logCategory.selected = true
        let whole = AgentCleanupExecutor.execute([logCategory], running: idle, home: home,
                                                presence: sandboxPresence, trashHandler: trashHandler)
        expect(whole.summary.removed == 3
               && !fm.fileExists(atPath: home + "/.codex/logs_2.sqlite")
               && !fm.fileExists(atPath: home + "/.codex/logs_2.sqlite-wal"),
               "complete SQLite family was not removed: \(whole.summary.messages)")
        expect(fm.fileExists(atPath: home + "/.codex/state_5.sqlite"), "unselected state database was touched")
        let partialWarp = AgentCleanupExecutor.execute(
            [warpDatabase.selectingPaths([home + "/" + warpRelatives[1]])],
            running: idle, home: home, presence: sandboxPresence, trashHandler: trashHandler)
        expect(partialWarp.summary.removed == 0 && warpPaths.allSatisfy { fm.fileExists(atPath: $0) },
               "selecting only Warp's WAL must preserve the entire database")
        let completeWarp = AgentCleanupExecutor.execute([selectedWarp],
            running: idle, home: home, presence: sandboxPresence, trashHandler: trashHandler)
        expect(completeWarp.summary.removed == 0 && warpPaths.allSatisfy { fm.fileExists(atPath: $0) },
               "full-family cleanup deleted retained Warp history: \(completeWarp.summary.messages)")
        try fm.removeItem(atPath: home + "/Applications/Warp.app")
        for path in warpRelatives { try write(path) }
        try write(warpRoot + "/keep.json")
        let orphanedWarpReport = AgentInventory.scan(home: home, presence: sandboxPresence, onlyAgentIDs: ["warp"])
        expect(orphanedWarpReport.groups.first?.orphaned == true,
               "Warp data must be recognized as residuals after its application is removed")
        var orphanedWarpDatabase = orphanedWarpReport.categories.first { $0.paths.contains(home + "/" + warpRelatives[0]) }!
        expect(!orphanedWarpDatabase.canSelect && !orphanedWarpDatabase.selected,
               "Uninstalled Warp history must remain protected")
        orphanedWarpDatabase.selected = true
        let orphanedWarpPlan = AgentCleanupExecutor.plan([orphanedWarpDatabase], running: idle,
            home: home, presence: sandboxPresence, removingAgentIDs: ["warp"])
        expect(orphanedWarpPlan.items.isEmpty,
               "Uninstall scope authorized file deletion of retained Warp history")
        let orphanedWarpCleanup = AgentCleanupExecutor.execute([orphanedWarpDatabase], running: idle,
            home: home, presence: sandboxPresence, trashHandler: trashHandler, removingAgentIDs: ["warp"])
        expect(orphanedWarpCleanup.summary.removed == 0 && warpPaths.allSatisfy { fm.fileExists(atPath: $0) }
               && fm.fileExists(atPath: home + "/" + warpRoot + "/keep.json"),
               "Warp residual cleanup touched retained history: \(orphanedWarpCleanup.summary.messages)")

        // --- Skill 链接和共享本体是不同操作：解除单个关联保留本体，删除本体清掉全部关联。
        // Explicit declarations through a link must also be detached. A direct
        // declaration of the shared body belongs to the body and stays intact.
        let linkedSkillConfig = """
        model = "fixture-model"
        [[skills.config]]
        path = "~/.cursor/skills/shared-skill/SKILL.md"
        enabled = true
        [[skills.config]]
        path = "\(home)/.agents/skills/shared-skill"
        enabled = true
        """
        try linkedSkillConfig.write(toFile: home + "/.codex/config.toml", atomically: true, encoding: .utf8)
        let linkedDeclarations = AgentSkillConfigEditor.scan(home: home)
        expect(linkedDeclarations.first?.declares(home + "/.cursor", home: home) == true
               && linkedDeclarations.last?.declares(home + "/.cursor", home: home) == false,
               "a parent cleanup could miss a Skill declaration through a contained link")
        let filesBeforePreflight = AgentCatalog.childNames(of: home + "/.codex")
        expect(AgentCleanupExecutor.blockingOwners([], skills: [linked!],
                   running: RunningApplicationSnapshot(bundleIdentifiers: ["com.openai.codex"]),
                   home: home, presence: sandboxPresence) == ["com.openai.codex"]
               && AgentCatalog.childNames(of: home + "/.codex") == filesBeforePreflight
               && (try? String(contentsOfFile: home + "/.codex/config.toml", encoding: .utf8)) == linkedSkillConfig,
               "Skill link preflight missed a lexical declaration or mutated its configuration")
        let linkHeldByCodex = AgentCleanupExecutor.execute([],
            running: RunningApplicationSnapshot(processNames: ["codex"]), home: home, presence: sandboxPresence, trashHandler: trashHandler, skills: [linked!])
        expect(linkHeldByCodex.refused == 1 && AgentCatalog.exists(linked!.path)
               && (try? String(contentsOfFile: home + "/.codex/config.toml", encoding: .utf8)) == linkedSkillConfig,
               "a registered Skill link was detached while its declaring Agent was running")
        var linkProgress: [(Int, Int)] = []
        let unlinked = AgentCleanupExecutor.execute([], running: idle, home: home, presence: sandboxPresence, trashHandler: trashHandler, skills: [linked!], onProgress: { completed, total, _ in
                linkProgress.append((completed, total))
                if total > 0 && completed == total {
                    expect(!AgentCatalog.exists(linked!.path)
                           && AgentSkillConfigEditor.scan(home: home).map(\.skillPath)
                               == [home + "/.agents/skills/shared-skill"],
                           "Skill progress reached completion before its registration was detached")
                }
            })
        expect(linkProgress.first?.0 == 0 && linkProgress.last?.0 == 1
               && linkProgress.allSatisfy { $0.1 == 1 },
               "explicit linked Skill did not produce complete progress")
        expect(unlinked.summary.removed == 2
               && !AgentCatalog.exists(home + "/.cursor/skills/shared-skill")
               && fm.fileExists(atPath: home + "/.agents/skills/shared-skill/SKILL.md"),
               "unlinking a skill deleted its shared target: \(unlinked.summary.messages)")
        let remainingDeclarations = AgentSkillConfigEditor.scan(home: home)
        expect(remainingDeclarations.map(\.skillPath) == [home + "/.agents/skills/shared-skill"]
               && fm.fileExists(atPath: home + "/.codex/config.toml.nori-backup"),
               "Skill link cleanup left its explicit declaration or removed the body's declaration")
        try link(".cursor/skills/shared-skill", to: home + "/.agents/skills/shared-skill")
        try link(".codex/skills/shared-skill", to: "../../.agents/skills/shared-skill")
        // 卸载 Agent 的注册也必须随共享本体一起清除。
        try link(".kimi/skills/shared-skill", to: home + "/.agents/skills/shared-skill")
        try Data("""
        model = "fixture-model"
        [[skills.config]]
        path = "\(home)/.agents/skills/shared-skill"
        enabled = true
        [[skills.config]]
        path = "\(home)/.claude/skills/writer/SKILL.md"
        enabled = false
        """.utf8).write(to: URL(fileURLWithPath: home + "/.codex/config.toml"))
        let sharedSkill = AgentInventory.scan(home: home, presence: sandboxPresence).skills
            .first { $0.path == home + "/.agents/skills/shared-skill" }!
        expect(Set(AgentCleanupExecutor.blockingOwners([], skills: [sharedSkill],
                   running: RunningApplicationSnapshot(bundleIdentifiers: ["com.openai.codex"],
                       processNames: ["Cursor", "kimi"]), home: home, presence: sandboxPresence))
                   == Set(["com.openai.codex", "Cursor", "kimi"]),
               "shared Skill preflight missed declarations or installed/orphaned link consumers")
        let sharedDeleted = AgentCleanupExecutor.execute([], running: idle, home: home, presence: sandboxPresence, trashHandler: trashHandler, skills: [sharedSkill])
        expect(sharedDeleted.summary.removed >= 1
               && !AgentCatalog.exists(sharedSkill.path)
               && [".cursor", ".codex", ".kimi"].allSatisfy {
                   !AgentCatalog.exists(home + "/" + $0 + "/skills/shared-skill")
               }, "shared skill deletion left agent registrations: \(sharedDeleted.summary.messages)")
        let skillTOML = try String(contentsOfFile: home + "/.codex/config.toml", encoding: .utf8)
        expect(!skillTOML.contains(sharedSkill.path)
               && skillTOML.contains(home + "/.claude/skills/writer/SKILL.md")
               && skillTOML.contains("model = \"fixture-model\"")
               && fm.fileExists(atPath: home + "/.codex/config.toml.nori-backup"),
               "shared skill deletion left Codex path registration or damaged unrelated TOML")
        expect(fm.fileExists(atPath: home + "/.claude/skills/writer/SKILL.md"),
               "shared skill cleanup touched an unrelated skill")
        try link(".cursor/skills/external", to: outside)
        try link(".cursor/skills/broken", to: home + "/.agents/skills/already-gone")
        let links = AgentInventory.scan(home: home, presence: sandboxPresence).skills
            .filter { ["external", "broken"].contains(($0.path as NSString).lastPathComponent) }
        expect(links.count == 2 && links.allSatisfy { $0.linked && !$0.identity.isEmpty },
               "dangling/external skill links cannot be selected for unlink")
        let clearedLinks = AgentCleanupExecutor.execute([], running: idle, home: home, presence: sandboxPresence, trashHandler: trashHandler, skills: links)
        expect(clearedLinks.summary.removed == 2 && fm.fileExists(atPath: outside + "/Cache/entry"),
               "clearing linked skills traversed an external target")

        // --- MCP：JSON（含项目级）、TOML、明文密钥与缺失命令；配置文件保持不变。
        try executable(".local/bin/nori-fixture-mcp")
        let claudeJSON = """
        {"mcpServers": {"fs": {"command": "definitely-missing-binary-xyz", "args": ["--root", "/tmp"],
          "env": {"GITHUB_TOKEN": "ghp_abcdefghijklmnopqrstuvwxyz0123", "SAFE": "${TOKEN}"}},
          "local": {"command": "\(home)/.local/bin/nori-fixture-mcp"}},
         "projects": {"/Users/me/repo": {"mcpServers": {"web": {"url": "https://mcp.example.com/sse?api_key=abcdef123456"}}}}}
        """
        try write(".claude.json")
        try Data(claudeJSON.utf8).write(to: URL(fileURLWithPath: home + "/.claude.json"))
        let toml = """
        model = "gpt"
        [mcp_servers.shell]
        command = "/bin/sh"
        args = ["-c", "true"]
        [mcp_servers.shell.env]
        API_KEY = "sk-live-1234567890abcdef"
        [mcp_servers.plugin]
        command = "./Plugin.app/Contents/MacOS/client"
        [mcp_servers."remote.docs"]
        url = "https://docs.example.com/mcp"
        enabled = false
        [mcp_servers.local]
        command = "\(home)/.local/bin/nori-fixture-mcp"
        """
        try Data(toml.utf8).write(to: URL(fileURLWithPath: home + "/.codex/config.toml"))
        let before = try Data(contentsOf: URL(fileURLWithPath: home + "/.claude.json"))
        let servers = AgentInventory.scan(home: home, presence: sandboxPresence).servers
        let fs = servers.first { $0.name == "fs" }
        expect(fs?.issues.contains(.commandMissing("definitely-missing-binary-xyz")) == true,
               "missing MCP command not reported")
        expect(fs?.issues.contains(.plaintextSecret(key: "GITHUB_TOKEN", masked: "ghp_…(34)")) == true
               && fs?.issues.count == 2, "plaintext secret detection wrong: \(String(describing: fs?.issues))")
        let web = servers.first { $0.name == "web" }
        expect(web?.scope == "/Users/me/repo" && web?.remote == true
               && web?.endpoint.contains("abcdef123456") == false, "project-scoped remote server not masked")
        let shell = servers.first { $0.name == "shell" }
        expect(shell?.issues == [.plaintextSecret(key: "API_KEY", masked: "sk-l…(24)")],
               "TOML env secret not detected: \(String(describing: shell?.issues))")
        expect(servers.first { $0.name == "remote.docs" }?.disabled == true, "quoted TOML server lost")
        expect(servers.first { $0.name == "plugin" }?.issues == [],
               "a host-relative MCP command was reported missing")
        let after = try Data(contentsOf: URL(fileURLWithPath: home + "/.claude.json"))
        expect(after == before,
               "MCP scan modified a configuration file")

        // --- MCP 编辑：勾选的服务器从配置移除；备份落在原文件旁，其余条目保持不变。
        let scanPresence = sandboxPresence
        let scanned = AgentInventory.scan(home: home, presence: scanPresence)
        guard let fsServer = scanned.servers.first(where: { $0.name == "fs" }),
              let webServer = scanned.servers.first(where: { $0.name == "web" }),
              let shellServer = scanned.servers.first(where: { $0.name == "shell" }) else {
            expect(false, "MCP fixture servers missing before edit")
            return
        }
        let removal = AgentMCPConfigEditor.apply([
            .init(configPath: fsServer.configPath, format: fsServer.format,
                  serverName: fsServer.name, scope: fsServer.scope),
            .init(configPath: webServer.configPath, format: webServer.format,
                  serverName: webServer.name, scope: webServer.scope),
            .init(configPath: shellServer.configPath, format: shellServer.format,
                  serverName: shellServer.name, scope: shellServer.scope)])
        expect(removal.removed == 3 && removal.failed == 0,
               "MCP removal outcome wrong: \(removal)")
        let rescanned = AgentInventory.scan(home: home, presence: scanPresence)
        expect(rescanned.servers.filter { ["fs", "web", "shell"].contains($0.name) }.isEmpty,
               "removed MCP servers still reported after edit")
        expect(rescanned.servers.contains { $0.name == "plugin" }
               && rescanned.servers.contains { $0.name == "remote.docs" },
               "untouched TOML servers were lost in the edit")
        expect(fm.fileExists(atPath: home + "/.claude.json.nori-backup")
               && fm.fileExists(atPath: home + "/.codex/config.toml.nori-backup"),
               "MCP edit did not back up the configuration files")
        let tomlAfter = try String(contentsOf: URL(fileURLWithPath: home + "/.codex/config.toml"),
                                    encoding: .utf8)
        expect(tomlAfter.contains("model = \"gpt\"") && !tomlAfter.contains("mcp_servers.shell"),
               "TOML rewrite damaged unrelated lines")

        // --- MCP 本体全局归并；取消某个注册保留本体，卸载本体移除所有 Agent 注册。
        let mcpReport = AgentInventory.scan(home: home, presence: sandboxPresence)
        let mcpInstall = mcpReport.installations.first { $0.path == home + "/.local/bin/nori-fixture-mcp" }
        expect(mcpInstall?.serverIDs.count == 2
               && mcpReport.servers.filter { $0.name == "local" }.allSatisfy {
                   $0.installationID == mcpInstall?.id
               }, "shared MCP executable was not deduplicated across agents")
        expect(mcpReport.installations.allSatisfy { $0.path != "/bin/sh" },
               "a shared runtime was mistaken for an MCP installation")
        expect(AgentCleanupExecutor.blockingOwners([], installations: [mcpInstall!],
                   running: RunningApplicationSnapshot(bundleIdentifiers: ["com.openai.codex"],
                       processNames: ["claude"]), home: home, presence: sandboxPresence)
                   == ["claude", "com.openai.codex"],
               "shared MCP installation preflight missed one of its registration consumers")
        // Agent 自身也可以提供 MCP；只能解除注册，不能在 MCP 区卸掉宿主包。
        try executable(".npm-global/lib/node_modules/@openai/codex/cli.js")
        let hostPackage = home + "/.npm-global/lib/node_modules/@openai/codex"
        try Data("{\"name\":\"@openai/codex\",\"bin\":{\"codex\":\"cli.js\"}}".utf8)
            .write(to: URL(fileURLWithPath: hostPackage + "/package.json"))
        expect(AgentInventory.mcpInstallationPath(command: "codex", arguments: ["mcp-server"],
                   searchPath: sandboxPresence.searchPath, home: home) == nil
               && AgentInventory.mcpInstallationPath(command: "npx", arguments: ["@openai/codex", "mcp-server"],
                   searchPath: sandboxPresence.searchPath, home: home) == nil,
               "an Agent host command/package was recognized as an independent MCP body")
        try Data("{\"name\":\"@openai/codex\",\"bin\":\"cli.js\"}".utf8)
            .write(to: URL(fileURLWithPath: hostPackage + "/package.json"))
        expect(AgentInventory.mcpInstallationPath(command: hostPackage + "/cli.js", arguments: ["mcp-server"],
                   searchPath: sandboxPresence.searchPath, home: home) == nil,
               "a string-bin host package bypassed the MCP host exclusion")
        let claudeLocal = mcpReport.servers.first { $0.name == "local" && $0.agentID == "claude-code" }!
        var changedConfig = try JSONSerialization.jsonObject(with: Data(contentsOf:
            URL(fileURLWithPath: home + "/.claude.json"))) as! [String: Any]
        let configModified = try fm.attributesOfItem(atPath: home + "/.claude.json")[.modificationDate] as! Date
        changedConfig["keep"] = "new setting written after the scan"
        let changedConfigData = try JSONSerialization.data(withJSONObject: changedConfig, options: [.sortedKeys])
        try changedConfigData.write(to: URL(fileURLWithPath: home + "/.claude.json"))
        try fm.setAttributes([.modificationDate: configModified], ofItemAtPath: home + "/.claude.json")
        expect(DeletionPlan.identity(at: home + "/.claude.json") == claudeLocal.configIdentity,
               "config fingerprint fixture unexpectedly changed its inode/mtime")
        let staleRegistration = AgentCleanupExecutor.execute([], running: idle, home: home, presence: sandboxPresence, trashHandler: trashHandler, servers: [claudeLocal])
        expect(staleRegistration.summary.removed == 0
               && (staleRegistration.refused > 0 || staleRegistration.summary.failed > 0)
               && fm.contents(atPath: home + "/.claude.json") == changedConfigData,
               "a changed MCP configuration was overwritten from an old scan")
        let currentClaudeLocal = AgentInventory.scan(home: home, presence: sandboxPresence).servers
            .first { $0.name == "local" && $0.agentID == "claude-code" }!
        let detached = AgentCleanupExecutor.execute([], running: idle, home: home, presence: sandboxPresence, trashHandler: trashHandler, servers: [currentClaudeLocal])
        expect(detached.summary.removed == 1
               && fm.fileExists(atPath: home + "/.local/bin/nori-fixture-mcp")
               && AgentInventory.scan(home: home, presence: sandboxPresence).servers
                   .filter { $0.name == "local" }.count == 1,
               "removing one MCP registration touched its installation")
        // 未安装的 Agent 配置不展示，但仍需在删除共享本体时去注册。
        try write(".gemini/settings.json")
        try Data("{\"mcpServers\":{\"old-host\":{\"command\":\"\(home)/.local/bin/nori-fixture-mcp\"}}}".utf8)
            .write(to: URL(fileURLWithPath: home + "/.gemini/settings.json"))
        // 备份无法落盘时必须保留本体，避免留下已失效且无法恢复的注册。
        let blockedBackup = home + "/.codex/config.toml.nori-backup"
        try fm.removeItem(atPath: blockedBackup)
        try fm.createDirectory(atPath: blockedBackup, withIntermediateDirectories: false)
        var refusedMCPProgress: [(Int, Int)] = []
        let refusedBody = AgentCleanupExecutor.execute([], running: idle, home: home, presence: sandboxPresence, trashHandler: trashHandler, installations: [mcpInstall!],
            onProgress: { completed, total, _ in refusedMCPProgress.append((completed, total)) })
        expect(refusedMCPProgress.first?.0 == 0 && refusedMCPProgress.last?.0 == 1
               && refusedMCPProgress.allSatisfy { $0.1 == 1 },
               "MCP backup failure left aggregate progress incomplete")
        expect(refusedBody.summary.removed == 0 && refusedBody.refused > 0
               && refusedBody.summary.messages.contains { $0.contains("could not be backed up") && $0.contains(mcpInstall!.path) }
               && fm.fileExists(atPath: home + "/.local/bin/nori-fixture-mcp"),
               "MCP body was removed when its registrations could not be backed up")
        try fm.removeItem(atPath: blockedBackup)
        let uninstallMCP = AgentCleanupExecutor.execute([], running: idle, home: home, presence: sandboxPresence, trashHandler: trashHandler, installations: [mcpInstall!])
        expect(uninstallMCP.summary.removed >= 1
               && !AgentCatalog.exists(home + "/.local/bin/nori-fixture-mcp")
               && AgentInventory.scanMCP(agents: AgentCatalog.definitions, home: home)
                   .allSatisfy { !["local", "old-host"].contains($0.name) },
               "MCP uninstall left installed or orphaned agent registrations")
        expect(fm.fileExists(atPath: home + "/.gemini/settings.json.nori-backup"),
               "automatic MCP deregistration was not backed up")

        // 不可解析配置仍保留原字节；不能用整文件重置绕过配置保护。
        try write(".config/opencode/opencode.json")
        let malformed = Data("{bad-json,\"private\":\"fixture-only\"".utf8)
        try malformed.write(to: URL(fileURLWithPath: home + "/.config/opencode/opencode.json"))
        let rawServer = AgentInventory.scan(home: home, presence: sandboxPresence).servers
            .first { $0.configPath == home + "/.config/opencode/opencode.json" }!
        expect(rawServer.issues == [.unreadableConfig], "malformed MCP configuration was not identified")
        let rawReset = AgentCleanupExecutor.execute([], running: idle, home: home, presence: sandboxPresence, trashHandler: trashHandler, servers: [rawServer])
        expect(rawReset.summary.removed == 0 && AgentCatalog.exists(rawServer.configPath)
               && fm.contents(atPath: rawServer.configPath) == malformed
               && fm.contents(atPath: rawServer.configPath + ".nori-backup") == malformed,
               "unreadable MCP configuration was deleted or its backup was lost")

        // npx 全局包需要 package.json 名称和 bin 证明，卸载不触碰 npm/node 运行时。
        let packageRoot = home + "/.npm-global/lib/node_modules/@nori/test-mcp"
        try write(".npm-global/lib/node_modules/@nori/test-mcp/server.js")
        try write(".npm-global/lib/node_modules/@nori/test-mcp/package.json")
        try Data("{\"name\":\"@nori/test-mcp\",\"bin\":{\"nori-test-mcp\":\"server.js\"}}".utf8)
            .write(to: URL(fileURLWithPath: packageRoot + "/package.json"))
        expect(AgentInventory.mcpInstallationPath(command: "npx", arguments: ["-y", "@nori/test-mcp@1.0.0"],
            searchPath: [home + "/.npm-global/bin"], home: home) == packageRoot,
               "a versioned scoped npx global MCP package was missed")
        expect(AgentInventory.mcpInstallationPath(command: "node", arguments: [packageRoot + "/server.js"],
            searchPath: [], home: home) == packageRoot,
               "an absolute node MCP package script was missed")
        expect(AgentInventory.mcpInstallationPath(command: "npx", arguments: ["@nori/not-installed"],
            searchPath: [home + "/.npm-global/bin"], home: home) == nil,
               "a temporary npx download was exposed as a global installation")
        try link(".npm-global/bin/nori-test-mcp", to: packageRoot + "/server.js")
        try Data("{\"mcpServers\":{\"package\":{\"command\":\"npx\",\"args\":[\"-y\",\"@nori/test-mcp@1.0.0\"]},\"runtime\":{\"command\":\"/bin/sh\"}}}".utf8)
            .write(to: URL(fileURLWithPath: home + "/.claude.json"))
        let packageReport = AgentInventory.scan(home: home, presence: sandboxPresence)
        let packageInstallation = packageReport.installations.first { $0.path == packageRoot }!
        let removedPackage = AgentCleanupExecutor.execute([], running: idle, home: home, presence: sandboxPresence, trashHandler: trashHandler, installations: [packageInstallation])
        expect(removedPackage.summary.removed >= 2 && !AgentCatalog.exists(packageRoot)
               && !AgentCatalog.exists(home + "/.npm-global/bin/nori-test-mcp")
               && AgentInventory.scanMCP(agents: AgentCatalog.definitions, home: home)
                   .contains { $0.name == "runtime" && $0.installationID == nil }
               && fm.fileExists(atPath: "/bin/sh"),
               "npm MCP uninstall left a launcher/registration or affected a runtime")

        // 整体 Agent 数据根包含共享本体时，也要保护使用者并清除外部注册。
        try write("Applications/Kiro.app/Contents/Info.plist")
        let kiroRoot = home + "/Library/Application Support/Kiro"
        let containedMCP = kiroRoot + "/tools/nori-contained-mcp"
        let containedSkill = kiroRoot + "/skills/embedded"
        try executable("Library/Application Support/Kiro/tools/nori-contained-mcp")
        try write("Library/Application Support/Kiro/skills/embedded/SKILL.md")
        try Data("{\"mcpServers\":{\"contained\":{\"command\":\"\(containedMCP)\"},\"runtime\":{\"command\":\"/bin/sh\"}}}".utf8)
            .write(to: URL(fileURLWithPath: home + "/.claude.json"))
        let existingTOML = try String(contentsOfFile: home + "/.codex/config.toml", encoding: .utf8)
        try (existingTOML + "\n[[skills.config]]\npath = \"\(containedSkill)\"\nenabled = true\n")
            .write(toFile: home + "/.codex/config.toml", atomically: true, encoding: .utf8)
        var rootCategory = AgentInventory.scan(home: home, presence: sandboxPresence).categories
            .first { $0.paths.contains(kiroRoot) }!
        rootCategory.risk = .warning
        rootCategory.disposal = .permanentDelete
        rootCategory.applyRoute = .aiTrash
        rootCategory.selected = true
        expect(AgentCleanupExecutor.blockingOwners([rootCategory],
                   running: RunningApplicationSnapshot(bundleIdentifiers: ["com.openai.codex"],
                       processNames: ["claude", "Cursor"]), home: home, presence: sandboxPresence)
                   .isEmpty,
               "protected parent root requested an unnecessary application close")
        let containedLink = kiroRoot + "/skills/external-shared"
        try fm.createSymbolicLink(atPath: containedLink,
            withDestinationPath: home + "/.agents/skills/global")
        try (existingTOML + "\n[[skills.config]]\npath = \"\(containedLink)/SKILL.md\"\nenabled = true\n")
            .write(toFile: home + "/.codex/config.toml", atomically: true, encoding: .utf8)
        expect(AgentCleanupExecutor.blockingOwners([rootCategory],
                   running: RunningApplicationSnapshot(bundleIdentifiers: ["com.openai.codex"]),
                   home: home, presence: sandboxPresence).isEmpty,
               "protected parent root requested a close for a contained Skill link")
        try fm.removeItem(atPath: containedLink)
        try (existingTOML + "\n[[skills.config]]\npath = \"\(containedSkill)\"\nenabled = true\n")
            .write(toFile: home + "/.codex/config.toml", atomically: true, encoding: .utf8)
        let consumerBusy = AgentCleanupExecutor.execute([rootCategory],
            running: RunningApplicationSnapshot(processNames: ["claude"]), home: home,
            presence: sandboxPresence, trashHandler: trashHandler)
        expect(consumerBusy.summary.removed == 0 && fm.fileExists(atPath: containedMCP),
               "whole root cleanup ignored a running MCP consumer")
        let blockedExternalBackup = home + "/.claude.json.nori-backup"
        try fm.removeItem(atPath: blockedExternalBackup)
        try fm.createDirectory(atPath: blockedExternalBackup, withIntermediateDirectories: false)
        let blockedRoot = AgentCleanupExecutor.execute([rootCategory], running: idle, home: home,
            presence: sandboxPresence, trashHandler: trashHandler)
        expect(blockedRoot.summary.removed == 0 && blockedRoot.refused > 0
               && fm.fileExists(atPath: containedMCP),
               "whole root cleanup proceeded when an external registration backup failed")
        try fm.removeItem(atPath: blockedExternalBackup)
        let rootRemoval = AgentCleanupExecutor.execute([rootCategory], running: idle, home: home,
            presence: sandboxPresence, trashHandler: trashHandler)
        expect(rootRemoval.summary.removed == 0 && AgentCatalog.exists(kiroRoot)
               && AgentInventory.scanMCP(agents: AgentCatalog.definitions, home: home)
                   .contains { $0.name == "contained" },
               "protected root cleanup deleted data or detached an external MCP registration: \(rootRemoval.summary.messages)")
        let rootSkillConfig = try String(contentsOfFile: home + "/.codex/config.toml", encoding: .utf8)
        expect(rootSkillConfig.contains(containedSkill) && rootSkillConfig.contains("model = \"gpt\""),
               "protected root cleanup detached a Skill or damaged unrelated config")

        // Data-only Agents remain visible as unselected leftovers; retained
        // configuration still cannot count as an installed application.
        for relative in [".local/bin/claude", ".local/bin/codex", ".local/bin/opencode",
                         ".local/bin/grok", "Applications/Cursor.app"] {
            try fm.removeItem(atPath: home + "/" + relative)
        }
        let removedIDs = Set(["claude-code", "codex", "cursor", "opencode", "grok"])
        let orphanedReport = AgentInventory.scan(home: home, presence: sandboxPresence)
        let leftoverGroups = orphanedReport.groups.filter { removedIDs.contains($0.id) }
        expect(leftoverGroups.allSatisfy(\.orphaned),
               "documented agents with only data/config left still appear installed")
        let leftoverCategoryIDs = Set(leftoverGroups.flatMap(\.categoryIDs))
        expect(orphanedReport.categories.filter { leftoverCategoryIDs.contains($0.id) }.allSatisfy { !$0.selected },
               "uninstall leftovers became selected without a user request")
        for agent in AgentCatalog.definitions where removedIDs.contains(agent.id) {
            expect(AgentCatalog.isOrphaned(agent, home: home, presence: sandboxPresence),
                   "\(agent.id) data was not classified as an uninstall leftover")
            expect(AgentCatalog.orphanedDataRoots(agent, home: home, presence: sandboxPresence).allSatisfy {
                !AgentCatalog.isManagedCleanupPath($0, protectedPaths: AgentCatalog.managedCleanupPaths(home: home))
            }, "\(agent.id) orphaned cleanup exposed retained history or state")
        }
        expect(!AgentCatalog.deletablePaths(home: home, presence: sandboxPresence)
            .contains(home + "/.local/share/opencode/openCode.db"),
               "an orphan database stayed in the Agent deletion funnel")
        let cleanupReport = await NativeCore.shared.scanCleanup(homeDirectory: home, mode: .quick,
            control: CleanupScanControl(mode: .quick, totalBudget: 30, directoryBudget: 5),
            agentPresence: sandboxPresence)
        expect(!cleanupReport.categories.contains {
            $0.paths.contains(home + "/.local/share/opencode")
        }, "ordinary cleanup scan offered uninstalled Agent history as junk")
        let leftoverPolicy = CleanupRiskPolicy.uninstalledAgentLeftover(
            path: home + "/.local/share/opencode", homeDirectory: home,
            verifiedPaths: [home + "/.local/share/opencode"])
        var opencodeLeftover = CleanupCategory(name: "OpenCode data",
            paths: [home + "/.local/share/opencode"], bytes: 4096, selected: false,
            source: leftoverPolicy.source, risk: leftoverPolicy.risk,
            disposal: leftoverPolicy.disposal, applyRoute: leftoverPolicy.applyRoute,
            activityGuard: leftoverPolicy.activityGuard, reasonKey: leftoverPolicy.reasonKey)
        opencodeLeftover.activityOwners = ["opencode"]
        var selectedLeftover = opencodeLeftover
        selectedLeftover.selected = true
        expect(AgentCleanupExecutor.blockingOwners([selectedLeftover],
                   running: RunningApplicationSnapshot(processNames: ["opencode"]),
                   home: home, presence: sandboxPresence).isEmpty,
               "protected Agent leftover requested an unnecessary application close")
        expect(selectedLeftover.activityOwners == ["opencode"]
               && CleanupRiskPolicy.isEligible(selectedLeftover, mode: .manual, running: idle, homeDirectory: home)
               && !CleanupRiskPolicy.isEligible(selectedLeftover, mode: .quickClean, running: idle, homeDirectory: home)
               && !CleanupRiskPolicy.isEligible(selectedLeftover, mode: .automatic, running: idle, homeDirectory: home),
               "agent leftovers lost their owner guard or reached quick/automatic cleanup")
        let manualLeftovers = CleanupCategory.manualCleanupCandidates(from: [opencodeLeftover])
        expect(manualLeftovers.count == 1 && !manualLeftovers[0].selected
               && CleanupCategory.safeCleanupCandidates(from: [selectedLeftover]).isEmpty
               && CleanupCategory.manualCleanupCandidates(from: [plainWarning]).isEmpty,
               "explicit Agent leftovers were preselected or widened the safe junk funnel")
        expect(Set(AgentCleanupExecutor.plan([selectedLeftover], running: idle, home: home,
            presence: sandboxPresence).items.map(\.record)).isEmpty,
               "cleanup-tab Agent leftovers exposed retained history to deletion")
        let smallWarnings = (0..<3).map { index -> CleanupCategory in
            var item = CleanupCategory(name: "agent residual \(index)",
                paths: [home + "/.codex/residual-\(index)"], bytes: 4096, selected: false,
                source: .appLeftover, risk: .warning, disposal: .permanentDelete,
                applyRoute: .genericTrash, activityGuard: .aiAgent,
                reasonKey: "cleanup.risk.agentLeftover")
            item.activityOwners = ["codex"]
            return item
        }
        let mergedWarnings = CleanupCategory.mergingLongTail(smallWarnings, homeDirectory: home)
        expect(mergedWarnings.count == 3 && Set(mergedWarnings.map(\.id)) == Set(smallWarnings.map(\.id)),
               "warning Agent leftovers were absorbed into a safe long-tail category")

        // --- CLI 卸载绑定安装身份，运行中或扫描后替换的入口不能卸载。
        // permanent:true 只删除沙盒夹具，不向当前用户的废纸篓写入测试文件。
        try executable(".local/bin/opencode")
        expect(AgentCleanupExecutor.plan([selectedLeftover], running: idle, home: home,
            presence: sandboxPresence).items.isEmpty,
               "an Agent reinstalled after the scan still passed leftover cleanup authorization")
        let cli = AgentCLIService.installations(for: opencode, home: home, presence: sandboxPresence)
            .first { $0.executablePaths.contains(home + "/.local/bin/opencode") }!
        expect(cli.manager == .native && !cli.identities.isEmpty,
               "native CLI installation was not detected/bound to its identity")
        let busyCLI = AgentCLIService.uninstall(cli, home: home,
            running: RunningApplicationSnapshot(processNames: ["opencode"]), permanent: true)
        expect(!busyCLI.succeeded && fm.fileExists(atPath: home + "/.local/bin/opencode"),
               "a running CLI was uninstalled")
        let unknownCLI = AgentCLIService.uninstall(cli, home: home, running: .unavailable, permanent: true)
        expect(!unknownCLI.succeeded && fm.fileExists(atPath: home + "/.local/bin/opencode"),
               "CLI uninstall proceeded without a process snapshot")
        try Data(repeating: 98, count: 8192)
            .write(to: URL(fileURLWithPath: home + "/.local/bin/opencode"), options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home + "/.local/bin/opencode")
        let changedCLI = AgentCLIService.uninstall(cli, home: home, running: idle, permanent: true)
        expect(!changedCLI.succeeded && fm.fileExists(atPath: home + "/.local/bin/opencode"),
               "a replaced CLI passed its scan identity")
        let freshCLI = AgentCLIService.installations(for: opencode, home: home, presence: sandboxPresence)
            .first { $0.executablePaths.contains(home + "/.local/bin/opencode") }!
        let removedCLI = AgentCLIService.uninstall(freshCLI, home: home, running: idle, permanent: true)
        expect(removedCLI.succeeded && !AgentCatalog.exists(home + "/.local/bin/opencode")
               && fm.fileExists(atPath: home + "/.local/share/opencode/openCode.db")
               && AgentCatalog.isOrphaned(opencode, home: home, presence: sandboxPresence),
               "native CLI uninstall did not leave data for the cleanup tab: \(removedCLI.messages)")
        // 安装器版本根和关联入口一起卸载；不会把数据根当成程序安装目录。
        try executable(".opencode/bin/opencode")
        try link(".local/bin/opencode", to: home + "/.opencode/bin/opencode")
        let rootedCLI = AgentCLIService.installations(for: opencode, home: home, presence: sandboxPresence)
            .first { $0.managedPaths.contains(home + "/.opencode/bin") }!
        expect(rootedCLI.identities[home + "/.opencode/bin"] != nil
               && rootedCLI.identities[home + "/.local/bin/opencode"] != nil,
               "native CLI root/launcher identity is missing")
        let rootedRemoval = AgentCLIService.uninstall(rootedCLI, home: home, running: idle, permanent: true)
        expect(rootedRemoval.succeeded && !AgentCatalog.exists(home + "/.opencode/bin")
               && !AgentCatalog.exists(home + "/.local/bin/opencode")
               && fm.fileExists(atPath: home + "/.local/share/opencode/auth.json"),
               "native CLI root uninstall left its link or deleted user data: \(rootedRemoval.messages)")
        let externalCLI = outside + "/standalone-opencode"
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: URL(fileURLWithPath: externalCLI))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: externalCLI)
        try link(".local/bin/opencode", to: externalCLI)
        let unknownLinkCLI = AgentCLIService.installations(for: opencode, home: home, presence: sandboxPresence)
            .first { $0.executablePaths.contains(home + "/.local/bin/opencode") }!
        expect(unknownLinkCLI.onlyUnlinksExecutable,
               "an unknown external CLI target was advertised as a full installation uninstall")
        let unlinkedCLI = AgentCLIService.uninstall(unknownLinkCLI, home: home, running: idle, permanent: true)
        expect(unlinkedCLI.succeeded && !AgentCatalog.exists(home + "/.local/bin/opencode")
               && fm.fileExists(atPath: externalCLI),
               "uninstalling an unknown CLI link traversed its external target")

        // --- 磁盘清理默认流程不再收 Agent 目录。
        // 已审计的可再生缓存（如 Cursor/Cache）仍归通用清理流程，不属于
        // Agent 专有——边界断言要同时覆盖两侧。
        expect(CleanupRiskPolicy.isAgentOwnedPath(home + "/.codex/logs_2.sqlite", homeDirectory: home)
               && CleanupRiskPolicy.isAgentOwnedPath(home + "/Library/Application Support/Qoder",
                                                     homeDirectory: home)
               && !CleanupRiskPolicy.isAgentOwnedPath(
                   home + "/Library/Application Support/Cursor/Cache", homeDirectory: home)
               && !CleanupRiskPolicy.isAgentOwnedPath(home + "/Library/Caches/com.example.app",
                                                      homeDirectory: home),
               "agent ownership boundary is wrong")

        let whitelistHome = fixture.appendingPathComponent("whitelist-home").path
        func whitelistWrite(_ relative: String, contents: Data = Data(repeating: 9, count: 4096)) throws {
            let url = URL(fileURLWithPath: whitelistHome + "/" + relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url)
        }
        try whitelistWrite(".local/bin/codex", contents: Data("#!/bin/sh\nexit 0\n".utf8))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: whitelistHome + "/.local/bin/codex")
        try whitelistWrite(".codex/log/keep.log")
        try whitelistWrite(".codex/tmp/arg0/garbage")
        try whitelistWrite(".codex/tmp/arg0/agent.open")
        try whitelistWrite(".agents/skills/white/SKILL.md", contents: Data("not a readable manifest".utf8))
        try whitelistWrite(".codex/config.toml", contents: Data("invalid MCP config that must not be analyzed".utf8))
        try whitelistWrite(".config/mole/whitelist", contents: Data((
            whitelistHome + "/.codex/log\n" + whitelistHome + "/.codex/config.toml\n"
                + whitelistHome + "/.agents/skills/white\n").utf8))
        let whitelistPresence = AgentPresenceContext(applicationDirs: [whitelistHome + "/Applications"],
            searchPath: [whitelistHome + "/.local/bin"])
        let whiteReport = AgentInventory.scan(home: whitelistHome, presence: whitelistPresence)
        expect(!whiteReport.categories.flatMap(\.paths).contains { $0.hasPrefix(whitelistHome + "/.codex/log") }
               && !whiteReport.skills.contains { $0.path == whitelistHome + "/.agents/skills/white" }
               && !whiteReport.servers.contains { $0.configPath == whitelistHome + "/.codex/config.toml" },
               "Agent whitelist content reached measurement, manifest parsing or MCP analysis")
        let safeTemp = whiteReport.categories.first {
            $0.paths.contains(whitelistHome + "/.codex/tmp/arg0/garbage")
        }
        expect(safeTemp != nil && safeTemp!.paths == [whitelistHome + "/.codex/tmp/arg0/garbage"],
               "Agent safe temp cache was not split around its protocol lock")
        var whiteLeafStat = stat()
        expect(lstat(whitelistHome + "/.codex/tmp/arg0/garbage", &whiteLeafStat) == 0,
               "could not capture Agent allocated-byte fixture")
        let whiteRemoval = AgentCleanupExecutor.execute([safeTemp!], running: idle,
            home: whitelistHome, presence: whitelistPresence, trashHandler: trashHandler)
        expect(whiteRemoval.summary.removed > 0 && whiteRemoval.summary.skipped == 0
               && whiteRemoval.summary.failed == 0
               && whiteRemoval.summary.reclaimedBytes == UInt64(whiteLeafStat.st_blocks) * 512
               && fm.fileExists(atPath: whitelistHome + "/.codex/tmp/arg0/agent.open"),
               "Agent split cache authorization or actual reclaimed-byte accounting diverged")
        let whiteAfter = AgentInventory.scan(home: whitelistHome, presence: whitelistPresence)
        expect(!whiteAfter.categories.flatMap(\.paths).contains { $0.hasPrefix(whitelistHome + "/.codex/tmp") },
               "a lock-only Agent cache reappeared as junk after successful cleanup")
        print("Agent catalog: versions, leftovers, SQLite families, selectable risk tiers, skill unlink/cascade, MCP bodies/registrations and CLI uninstall guards passed")
    }

    /// 只读探针：打印真实 home 下的 Agent 报告，不做任何写入。
    static func probe(home: String) {
        let report = AgentInventory.scan(home: home)
        func size(_ bytes: UInt64) -> String {
            ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        }
        print("complete=\(report.complete)")
        for group in report.groups {
            print("== \(group.name) \(size(group.bytes))\(group.documented ? "" : " [size only]")")
            for id in group.categoryIDs {
                guard let category = report.categories.first(where: { $0.id == id }) else { continue }
                print("  [\(category.risk.rawValue)] \(category.name) \(size(category.bytes)) paths=\(category.paths.count) owners=\(category.activityOwners)")
                for path in category.pathsByDescendingSize.prefix(4) {
                    print("      \(size(category.pathBytes[path] ?? 0))  \(path)")
                }
            }
        }
        print("== skills \(report.skills.count)")
        for skill in report.skills.prefix(12) {
            print("  \(skill.linked ? "link" : size(skill.bytes)) \(skill.name) @ \(skill.directory)")
        }
        print("== mcp \(report.servers.count)")
        for server in report.servers {
            print("  \(server.agentName) / \(server.name) \(server.remote ? "remote" : "stdio") \(server.endpoint.prefix(60)) issues=\(server.issues)")
        }
    }
}
