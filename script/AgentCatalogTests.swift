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
    static func main() throws {
        if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "--probe" {
            probe(home: CommandLine.arguments[2])
            return
        }
        let fm = FileManager.default
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: fixture) }
        let home = fixture.appendingPathComponent("home").path

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

        // --- 版本判定：链接指向的版本 + 最新版本保留，其余为旧版本。
        try write(".local/share/claude/versions/2.1.100", bytes: 8192)
        try write(".local/share/claude/versions/2.1.200", bytes: 8192)
        try write(".local/share/claude/versions/2.1.300", bytes: 8192)
        try touch(".local/share/claude/versions/2.1.100", secondsAgo: 300)
        try touch(".local/share/claude/versions/2.1.200", secondsAgo: 200)
        try touch(".local/share/claude/versions/2.1.300", secondsAgo: 100)
        try link(".local/bin/claude", to: home + "/.local/share/claude/versions/2.1.200")
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
        try write(".codex/sessions/2026/rollout.jsonl")
        let codex = AgentCatalog.definitions.first { $0.id == "codex" }!
        let codexTargets = AgentCatalog.resolve(codex, home: home)
        let logDB = codexTargets.first { $0.labelKey == "agents.label.logDatabase" }!
        expect(logDB.tier == .review && Set(logDB.paths) == Set([
            home + "/.codex/logs_2.sqlite", home + "/.codex/logs_2.sqlite-wal",
            home + "/.codex/logs_2.sqlite-shm"]), "SQLite companions missing: \(logDB.paths)")
        expect(codexTargets.first { $0.labelKey == "agents.label.stateDatabase" }?.tier == .showOnly,
               "Codex state database must be show-only")
        expect(!AgentCatalog.deletablePaths(home: home).contains(where: {
            $0.contains("/.codex/sessions") || $0.contains("state_5")
        }), "show-only Codex data became deletable")

        // opencode 对话库可由用户选择清理，但必须带伴随文件和进程守卫。
        try write(".local/share/opencode/opencode.db")
        try write(".local/share/opencode/opencode.db-wal")
        try write(".local/share/opencode/auth.json")
        let opencode = AgentCatalog.definitions.first { $0.id == "opencode" }!
        let conversation = AgentCatalog.resolve(opencode, home: home)
            .first { $0.labelKey == "agents.label.conversationDatabase" }
        expect(conversation?.tier == .review && conversation?.owners == ["opencode"]
               && conversation?.paths.count == 2, "opencode database is not a guarded review family")
        expect(!AgentCatalog.deletablePaths(home: home).contains(home + "/.local/share/opencode/auth.json"),
               "opencode credentials became deletable")

        // --- 目录不变量。
        for agent in AgentCatalog.definitions {
            for target in agent.targets where agent.documented && target.tier == .review {
                expect(!(target.owners ?? agent.owners).isEmpty,
                       "\(agent.id) review target \(target.labelKey) has no owner process guard")
            }
            if !agent.documented {
                expect(agent.targets.allSatisfy { $0.tier == .showOnly },
                       "undocumented agent \(agent.id) offers deletion")
            }
        }
        // --- 残留判定：已卸载工具整体退出 Agent 漏斗，交由清理扫描按磁盘垃圾收录。
        try write("Library/Application Support/Kiro/Cache/entry")
        let kiro = AgentCatalog.definitions.first { $0.id == "kiro" }!
        let sandboxPresence = AgentPresenceContext(
            applicationDirs: [home + "/Applications"], searchPath: [])
        expect(AgentCatalog.resolve(kiro, home: home, presence: sandboxPresence)
            .allSatisfy { $0.tier == .review },
               "orphaned undocumented tool stayed show-only")
        expect(!AgentCatalog.deletablePaths(home: home, presence: sandboxPresence)
            .contains(home + "/Library/Application Support/Kiro"),
               "orphaned leftovers must move to the cleanup funnel, not the agent funnel")
        let sandboxReport = AgentInventory.scan(home: home, presence: sandboxPresence)
        expect(sandboxReport.groups.allSatisfy { $0.id != "kiro" }
               && sandboxReport.categories.allSatisfy { !$0.paths.contains(home + "/Library/Application Support/Kiro") },
               "an uninstalled tool still appears on the agents page")
        try write("Applications/Kiro.app/Contents/Info.plist")
        expect(AgentCatalog.resolve(kiro, home: home, presence: sandboxPresence)
            .allSatisfy { $0.tier == .showOnly },
               "undocumented tool with its app present became deletable")
        try? fm.removeItem(atPath: home + "/Applications/Kiro.app")

        // --- 扫描报告：Safe 默认勾选，Review 不勾选，showOnly 不可选。
        try write(".claude/projects/-Users-me-repo/session.jsonl")
        try write(".claude/statsig/cache")
        try write(".claude/skills/writer/SKILL.md")
        try Data("---\nname: writer\ndescription: \"Writes docs\"\n---\nbody\n".utf8)
            .write(to: URL(fileURLWithPath: home + "/.claude/skills/writer/SKILL.md"))
        try fm.createDirectory(atPath: home + "/.agents/skills/shared-skill", withIntermediateDirectories: true)
        try write(".agents/skills/shared-skill/SKILL.md")
        try link(".cursor/skills/shared-skill", to: home + "/.agents/skills/shared-skill")
        let report = AgentInventory.scan(home: home)
        let statsig = report.categories.first { $0.paths.contains(home + "/.claude/statsig") }
        expect(statsig?.risk == .safe && statsig?.allSelected == true, "safe agent cache not preselected")
        let projects = report.categories.first { $0.paths.contains(home + "/.claude/projects/-Users-me-repo") }
        expect(projects?.risk == .warning && projects?.selected == false
               && projects?.activityOwners == ["claude"], "review item preselected or unguarded")
        let state = report.categories.first { $0.paths.contains(home + "/.codex/state_5.sqlite") }
        expect(state?.risk == .protected && state?.canSelect == false, "show-only item is selectable")
        expect(report.categories.allSatisfy { $0.activityGuard == .aiAgent }, "agent category lost its guard")
        let writer = report.skills.first { $0.path == home + "/.claude/skills/writer" }
        expect(writer?.name == "writer" && writer?.summary == "Writes docs" && writer?.linked == false,
               "SKILL.md front matter not parsed")
        let linked = report.skills.first { $0.path == home + "/.cursor/skills/shared-skill" }
        expect(linked?.linked == true && linked?.identity.isEmpty == true, "linked skill became deletable")

        // --- 策略：Warning + aiAgent 仅在手动模式、归属者未运行、进程表完整时可执行。
        let review = projects!
        let idle = RunningApplicationSnapshot(processNames: ["Finder"])
        let busy = RunningApplicationSnapshot(processNames: ["claude"])
        var selectedReview = review
        selectedReview.selected = true
        expect(CleanupRiskPolicy.isEligible(selectedReview, mode: .manual, running: idle),
               "idle agent review item is not executable")
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

        // --- 执行计划：目录不再认领的路径与伪造的 Skill 被拒绝。
        var forged = review
        forged.appendPath(home + "/.claude/skills/writer", bytes: 1)
        forged.selected = true
        let plan = AgentCleanupExecutor.plan([forged], running: idle, home: home)
        expect(plan.items.map(\.record) == [home + "/.claude/projects/-Users-me-repo"] && plan.refused == 1,
               "catalog revalidation admitted a path outside the review target")
        let bogusSkill = CleanupCategory(
            name: "Skills", paths: [home + "/.claude/projects/-Users-me-repo"], bytes: 1,
            selected: true, source: .aiSession, risk: .warning, disposal: .permanentDelete,
            applyRoute: .aiTrash, activityGuard: .aiAgent, reasonKey: "agents.reason.skill")
        expect(AgentCleanupExecutor.plan([bogusSkill], running: idle, home: home).items.isEmpty,
               "a non-skill path passed the skill revalidation")

        // --- 漏斗：SQLite 族原子处理；verifiedTargets 只解除名字/扩展名拦截。
        var logCategory = report.categories.first { $0.paths.contains(home + "/.codex/logs_2.sqlite") }!
        logCategory.setPathSelected(home + "/.codex/logs_2.sqlite", selected: true)
        let partialPlan = AgentCleanupExecutor.plan([logCategory], running: idle, home: home)
        expect(partialPlan.families.contains { $0.contains(home + "/.codex/logs_2.sqlite-wal") },
               "unselected live companions were not added to the atomic family")
        let partial = AgentCleanupExecutor.execute([logCategory], running: idle, home: home, permanent: true)
        expect(partial.summary.removed == 0 && fm.fileExists(atPath: home + "/.codex/logs_2.sqlite"),
               "a SQLite file was removed without its companions")
        logCategory.selected = true
        let whole = AgentCleanupExecutor.execute([logCategory], running: idle, home: home, permanent: true)
        expect(whole.summary.removed == 3
               && !fm.fileExists(atPath: home + "/.codex/logs_2.sqlite")
               && !fm.fileExists(atPath: home + "/.codex/logs_2.sqlite-wal"),
               "complete SQLite family was not removed: \(whole.summary.messages)")
        expect(fm.fileExists(atPath: home + "/.codex/state_5.sqlite"), "show-only database was touched")

        // --- MCP：JSON（含项目级）、TOML、明文密钥与缺失命令；配置文件保持不变。
        let claudeJSON = """
        {"mcpServers": {"fs": {"command": "definitely-missing-binary-xyz", "args": ["--root", "/tmp"],
          "env": {"GITHUB_TOKEN": "ghp_abcdefghijklmnopqrstuvwxyz0123", "SAFE": "${TOKEN}"}}},
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
        """
        try Data(toml.utf8).write(to: URL(fileURLWithPath: home + "/.codex/config.toml"))
        let before = try Data(contentsOf: URL(fileURLWithPath: home + "/.claude.json"))
        let servers = AgentInventory.scan(home: home).servers
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
        let scanPresence = AgentPresenceContext(
            applicationDirs: [home + "/Applications"], searchPath: [])
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

        // --- 磁盘清理默认流程不再收 Agent 目录。
        expect(CleanupRiskPolicy.isAgentOwnedPath(home + "/.codex/logs_2.sqlite", homeDirectory: home)
               && CleanupRiskPolicy.isAgentOwnedPath(home + "/Library/Application Support/Cursor/Cache",
                                                     homeDirectory: home)
               && !CleanupRiskPolicy.isAgentOwnedPath(home + "/Library/Caches/com.example.app",
                                                      homeDirectory: home),
               "agent ownership boundary is wrong")
        print("Agent catalog: versions, symlink roots, SQLite families, tiers, skills, MCP and sink guards passed")
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
