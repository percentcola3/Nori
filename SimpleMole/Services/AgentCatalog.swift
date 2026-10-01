import Foundation

/// Agent 专清的三档目录：
/// - `safe`：官方文档或安装器行为可证明可再生（缓存叶子、未被启动链接引用的旧版本），默认勾选；
/// - `review`：会话、检查点、日志库等用户数据，删除后丢历史但不影响工具运行，交给用户选择；
/// - `showOnly`：凭据、活跃状态库、对话库，以及无官方文档的工具，只显示占用。
enum AgentTier: String, Sendable {
    case safe, review, showOnly
}

struct AgentTarget: Sendable {
    enum Kind: Sendable {
        /// 固定路径（相对 home）。
        case path(String)
        /// root 下存在的指定叶子（Chromium/Electron 缓存目录等）。
        case leaves(root: String, names: [String])
        /// root 的直接子项逐项列出（会话、项目转录等），供用户按项勾选。
        case children(String)
        /// 版本目录：保留被启动链接解析到的版本和最新版本，其余为旧版本。
        /// 没有任何链接能解析进 root 时无法证明谁在用，整个目标不产出。
        case versions(root: String, links: [String])
        /// `dir/<prefix>*<ext>` SQLite 文件及其 -wal/-shm/-journal 伴随文件。
        case sqlite(dir: String, prefix: String, ext: String)
    }

    let tier: AgentTier
    let kind: Kind
    let labelKey: String
    /// nil 表示沿用 Agent 的归属进程；空数组表示不按进程判定，
    /// 只依赖执行边界的打开文件快照（旧版本目录、只读展示项）。
    let owners: [String]?

    init(_ tier: AgentTier, _ kind: Kind, _ labelKey: String, owners: [String]? = nil) {
        self.tier = tier
        self.kind = kind
        self.labelKey = labelKey
        self.owners = owners
    }
}

enum AgentMCPFormat: Equatable, Sendable {
    /// JSON 对象内的 key 路径（点分隔），值为 name → server 映射。
    case json(keyPath: String)
    /// TOML `[<table>.<name>]` 段。
    case toml(table: String)
}

struct AgentMCPSource: Sendable {
    let path: String
    let format: AgentMCPFormat
}

/// 无官方文档工具的存在性线索：App bundle 名与 PATH 上的命令。
/// 两者都找不到时，其数据目录视为已卸载应用的残留，升级为可清理。
struct AgentPresence: Sendable {
    let bundleNames: [String]
    let commands: [String]
}

/// presence 检测的搜索范围：生产用默认值，测试注入沙盒目录保证确定性。
struct AgentPresenceContext: Sendable {
    let applicationDirs: [String]
    let searchPath: [String]
}

struct AgentDefinition: Sendable {
    let id: String
    let name: String
    /// 进程名或 Bundle ID；任一运行即视为占用。
    let owners: [String]
    /// 任一存在即视为已安装。
    let detect: [String]
    /// false 表示没有找到官方目录说明：所有目标只显示占用。
    let documented: Bool
    let targets: [AgentTarget]
    let skillDirectories: [String]
    let mcpSources: [AgentMCPSource]
    /// 仅 undocumented 工具需要：用于区分「装着但没说明」与「已卸载的残留」。
    var presence: AgentPresence? = nil
}

enum AgentCatalog {
    static let appSupport = "Library/Application Support/"

    /// Chromium/Electron 可再生缓存叶子，与 Mole 浏览器目录审计一致。
    static let electronCacheLeaves = [
        "Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache",
        "GraphiteDawnCache", "GrShaderCache", "ShaderCache", "GPUPersistentCache",
        "component_crx_cache", "extensions_crx_cache", "CachedData", "CachedExtensionVSIXs",
        "logs", "Crashpad/completed"
    ]

    static let definitions: [AgentDefinition] = [
        AgentDefinition(
            id: "claude-code", name: "Claude Code", owners: ["claude"],
            detect: [".claude", ".local/share/claude"], documented: true,
            targets: [
                .init(.safe, .versions(root: ".local/share/claude/versions",
                                       links: [".local/bin/claude"]),
                      "agents.label.oldVersions", owners: []),
                .init(.safe, .path(".claude/statsig"), "agents.label.cache"),
                .init(.review, .children(".claude/projects"), "agents.label.transcripts"),
                .init(.review, .children(".claude/file-history"), "agents.label.fileHistory"),
                .init(.review, .children(".claude/shell-snapshots"), "agents.label.shellSnapshots"),
                .init(.review, .children(".claude/todos"), "agents.label.todos"),
                .init(.review, .path(".claude/paste-cache"), "agents.label.pasteCache"),
                .init(.review, .path(".claude/debug"), "agents.label.logs"),
                .init(.showOnly, .path(".claude/history.jsonl"), "agents.label.history", owners: [])
            ],
            skillDirectories: [".claude/skills"],
            mcpSources: [.init(path: ".claude.json", format: .json(keyPath: "mcpServers"))]),
        AgentDefinition(
            id: "claude-desktop", name: "Claude",
            owners: ["Claude", "com.anthropic.claudefordesktop"],
            detect: [appSupport + "Claude"], documented: true,
            targets: [
                .init(.safe, .leaves(root: appSupport + "Claude",
                                     names: electronCacheLeaves + ["sentry"]),
                      "agents.label.appCache"),
                .init(.safe, .path(appSupport + "Claude/vm_bundles"), "agents.label.vmBundles"),
                .init(.safe, .path("Library/Caches/com.anthropic.claudefordesktop"),
                      "agents.label.cache"),
                .init(.safe, .path("Library/Caches/com.anthropic.claudefordesktop.ShipIt"),
                      "agents.label.updateStaging")
            ],
            skillDirectories: [],
            mcpSources: [.init(path: appSupport + "Claude/claude_desktop_config.json",
                               format: .json(keyPath: "mcpServers"))]),
        AgentDefinition(
            id: "codex", name: "Codex CLI", owners: ["codex"],
            detect: [".codex"], documented: true,
            targets: [
                .init(.review, .sqlite(dir: ".codex", prefix: "logs_", ext: ".sqlite"),
                      "agents.label.logDatabase"),
                .init(.review, .path(".codex/.tmp"), "agents.label.tempFiles"),
                .init(.review, .path(".codex/cache"), "agents.label.cache"),
                .init(.review, .path(".codex/generated_images"), "agents.label.generatedImages"),
                .init(.review, .children(".codex/archived_sessions"), "agents.label.archivedSessions"),
                .init(.showOnly, .path(".codex/sessions"), "agents.label.sessions", owners: []),
                .init(.showOnly, .sqlite(dir: ".codex", prefix: "state_", ext: ".sqlite"),
                      "agents.label.stateDatabase", owners: []),
                .init(.showOnly, .sqlite(dir: ".codex", prefix: "thread_history_", ext: ".sqlite"),
                      "agents.label.historyDatabase", owners: []),
                .init(.showOnly, .path(".codex/history.jsonl"), "agents.label.history", owners: [])
            ],
            skillDirectories: [".codex/skills"],
            mcpSources: [.init(path: ".codex/config.toml", format: .toml(table: "mcp_servers"))]),
        AgentDefinition(
            id: "codex-app", name: "Codex App",
            owners: ["Codex", "com.openai.codex", "codex"],
            detect: [appSupport + "Codex", "Library/Caches/com.openai.codex"], documented: true,
            targets: [
                .init(.safe, .leaves(root: appSupport + "Codex", names: electronCacheLeaves),
                      "agents.label.appCache"),
                .init(.safe, .leaves(root: "Library/Caches/Codex/Default",
                                     names: ["Cache", "Code Cache"]), "agents.label.appCache"),
                .init(.safe, .leaves(root: "Library/Caches/Codex/Default/Partitions/codex-browser-app",
                                     names: ["Cache", "Code Cache"]), "agents.label.appCache"),
                .init(.safe, .leaves(root: "Library/Caches/Codex/codex-browser-app",
                                     names: ["Cache", "Code Cache"]), "agents.label.appCache"),
                .init(.safe, .path("Library/Caches/com.openai.codex"), "agents.label.cache"),
                .init(.safe, .path("Library/Logs/com.openai.codex"), "agents.label.logs")
            ],
            skillDirectories: [],
            mcpSources: []),
        AgentDefinition(
            id: "cursor", name: "Cursor",
            owners: ["Cursor", "com.todesktop.230313mzl4w4u92"],
            detect: [appSupport + "Cursor", ".cursor"], documented: true,
            targets: [
                .init(.safe, .leaves(root: appSupport + "Cursor", names: electronCacheLeaves),
                      "agents.label.appCache"),
                .init(.safe, .versions(
                    root: appSupport + "Cursor/User/globalStorage/anysphere.cursor-agent-worker/agent-cli/.local/share/cursor-agent/versions",
                    links: [appSupport + "Cursor/User/globalStorage/anysphere.cursor-agent-worker/agent-cli/.local/bin/cursor-agent"]),
                      "agents.label.embeddedAgentVersions", owners: []),
                .init(.safe, .path("Library/Caches/com.todesktop.230313mzl4w4u92.ShipIt"),
                      "agents.label.updateStaging"),
                .init(.safe, .path("Library/Caches/com.todesktop.230313mzl4w4u92"),
                      "agents.label.cache"),
                .init(.safe, .path("Library/Caches/cursor-compile-cache"), "agents.label.compileCache"),
                .init(.review, .path(appSupport + "Cursor/snapshots"), "agents.label.checkpoints"),
                .init(.showOnly, .path(".cursor/projects"), "agents.label.transcripts", owners: []),
                .init(.showOnly, .path(appSupport + "Cursor/User/workspaceStorage"),
                      "agents.label.workspaceState", owners: []),
                .init(.showOnly, .path(appSupport + "Cursor/User/globalStorage/state.vscdb"),
                      "agents.label.stateDatabase", owners: [])
            ],
            skillDirectories: [".cursor/skills"],
            mcpSources: [.init(path: ".cursor/mcp.json", format: .json(keyPath: "mcpServers"))]),
        AgentDefinition(
            id: "cursor-cli", name: "Cursor CLI", owners: ["cursor-agent"],
            detect: [".local/share/cursor-agent"], documented: true,
            targets: [
                .init(.safe, .versions(root: ".local/share/cursor-agent/versions",
                                       links: [".local/bin/cursor-agent", ".local/bin/agent"]),
                      "agents.label.oldVersions", owners: [])
            ],
            skillDirectories: [], mcpSources: []),
        AgentDefinition(
            id: "copilot", name: "GitHub Copilot CLI", owners: ["copilot"],
            detect: [".copilot"], documented: true,
            targets: [
                .init(.safe, .versions(root: ".copilot/pkg/universal", links: [".local/bin/copilot"]),
                      "agents.label.oldVersions", owners: []),
                .init(.safe, .path(".copilot/logs"), "agents.label.logs"),
                .init(.safe, .path("Library/Caches/copilot"), "agents.label.cache"),
                .init(.review, .children(".copilot/session-state"), "agents.label.sessions")
            ],
            skillDirectories: [".copilot/skills"],
            mcpSources: [.init(path: ".copilot/mcp-config.json", format: .json(keyPath: "mcpServers"))]),
        AgentDefinition(
            id: "gemini", name: "Gemini CLI", owners: ["gemini"],
            detect: [".gemini/settings.json", ".gemini/tmp"], documented: true,
            targets: [
                .init(.review, .children(".gemini/tmp"), "agents.label.sessions")
            ],
            skillDirectories: [".gemini/skills"],
            mcpSources: [.init(path: ".gemini/settings.json", format: .json(keyPath: "mcpServers"))]),
        AgentDefinition(
            id: "antigravity", name: "Antigravity",
            owners: ["Antigravity", "com.google.antigravity"],
            detect: [appSupport + "Antigravity", ".gemini/antigravity"], documented: true,
            targets: [
                .init(.safe, .leaves(root: appSupport + "Antigravity", names: electronCacheLeaves),
                      "agents.label.appCache"),
                .init(.safe, .path(".gemini/antigravity/browser_recordings"),
                      "agents.label.browserRecordings"),
                .init(.showOnly, .path(".gemini/antigravity/conversations"),
                      "agents.label.conversations", owners: []),
                .init(.showOnly, .path(".gemini/antigravity/brain"), "agents.label.knowledge", owners: [])
            ],
            skillDirectories: [],
            mcpSources: [
                .init(path: ".gemini/config/mcp_config.json", format: .json(keyPath: "mcpServers")),
                .init(path: ".gemini/antigravity/mcp_config.json", format: .json(keyPath: "mcpServers"))
            ]),
        AgentDefinition(
            id: "opencode", name: "opencode", owners: ["opencode"],
            detect: [".local/share/opencode", ".config/opencode"], documented: true,
            targets: [
                .init(.safe, .path(".cache/opencode"), "agents.label.cache"),
                .init(.safe, .path(".local/share/opencode/log"), "agents.label.logs"),
                .init(.review, .path(".local/share/opencode/snapshot"), "agents.label.checkpoints"),
                .init(.review, .path(".local/share/opencode/tool-output"), "agents.label.tempFiles"),
                // 对话库与旧版 JSON 存储即全部会话历史；凭据在 auth.json，不在此列。
                .init(.review, .sqlite(dir: ".local/share/opencode", prefix: "opencode", ext: ".db"),
                      "agents.label.conversationDatabase"),
                .init(.review, .path(".local/share/opencode/storage"), "agents.label.sessions")
            ],
            skillDirectories: [".config/opencode/skills"],
            mcpSources: [.init(path: ".config/opencode/opencode.json", format: .json(keyPath: "mcp"))]),
        AgentDefinition(
            id: "grok", name: "Grok CLI", owners: ["grok"],
            detect: [".grok"], documented: true,
            targets: [
                .init(.safe, .versions(root: ".grok/downloads",
                                       links: [".grok/bin/agent", ".local/bin/agent",
                                               ".grok/bin/grok", ".local/bin/grok"]),
                      "agents.label.oldVersions", owners: []),
                .init(.safe, .versions(root: ".grok/bin",
                                       links: [".grok/bin/grok", ".local/bin/grok"]),
                      "agents.label.oldVersions", owners: []),
                .init(.safe, .path(".grok/marketplace-cache"), "agents.label.cache"),
                .init(.safe, .path(".grok/logs"), "agents.label.logs"),
                .init(.review, .children(".grok/sessions"), "agents.label.sessions"),
                .init(.showOnly, .path(".grok/worktrees"), "agents.label.worktrees", owners: [])
            ],
            skillDirectories: [".grok/skills"],
            mcpSources: [.init(path: ".grok/config.toml", format: .toml(table: "mcp_servers"))]),
        AgentDefinition(
            id: "pi", name: "pi", owners: ["pi"],
            detect: [".pi"], documented: true,
            targets: [
                .init(.review, .children(".pi/agent/sessions"), "agents.label.sessions")
            ],
            skillDirectories: [".pi/agent/skills"], mcpSources: []),
        AgentDefinition(
            id: "kimi", name: "Kimi CLI", owners: ["kimi", "kimi-cli"],
            detect: [".kimi"], documented: true,
            targets: [
                .init(.review, .children(".kimi/sessions"), "agents.label.sessions"),
                .init(.review, .path(".kimi/user-history"), "agents.label.history"),
                .init(.review, .path(".kimi/plans"), "agents.label.plans"),
                .init(.review, .path(".kimi/logs"), "agents.label.logs")
            ],
            skillDirectories: [".kimi/skills"],
            mcpSources: [.init(path: ".kimi/mcp.json", format: .json(keyPath: "mcpServers"))]),
        AgentDefinition(
            id: "factory", name: "Factory Droid", owners: ["droid"],
            detect: [".factory"], documented: true,
            targets: [
                .init(.review, .children(".factory/sessions"), "agents.label.sessions"),
                .init(.review, .path(".factory/logs"), "agents.label.logs"),
                .init(.review, .path(".factory/cache"), "agents.label.cache"),
                .init(.review, .path(".factory/temp"), "agents.label.tempFiles")
            ],
            skillDirectories: [".factory/skills"],
            mcpSources: [.init(path: ".factory/mcp.json", format: .json(keyPath: "mcpServers"))]),
        AgentDefinition(
            id: "devin", name: "Devin", owners: ["Devin"],
            detect: [appSupport + "Devin", ".devin"], documented: true,
            targets: [
                .init(.safe, .leaves(root: appSupport + "Devin", names: electronCacheLeaves),
                      "agents.label.appCache"),
                .init(.showOnly, .path(appSupport + "Devin/WebStorage"), "agents.label.appData", owners: [])
            ],
            skillDirectories: [],
            mcpSources: [.init(path: ".config/devin/mcp_config.json", format: .json(keyPath: "mcpServers"))]),
        AgentDefinition(
            id: "windsurf", name: "Windsurf", owners: ["Windsurf", "com.exafunction.windsurf"],
            detect: [appSupport + "Windsurf", ".codeium/windsurf"], documented: true,
            targets: [
                .init(.safe, .leaves(root: appSupport + "Windsurf", names: electronCacheLeaves),
                      "agents.label.appCache"),
                .init(.showOnly, .path(".codeium/windsurf/cascade"), "agents.label.conversations", owners: [])
            ],
            skillDirectories: [".codeium/windsurf/skills"],
            mcpSources: [
                .init(path: ".codeium/windsurf/mcp_config.json", format: .json(keyPath: "mcpServers")),
                .init(path: ".codeium/mcp_config.json", format: .json(keyPath: "mcpServers"))
            ]),
        AgentDefinition(
            id: "chrome-devtools-mcp", name: "Chrome DevTools MCP", owners: [],
            detect: [".cache/chrome-devtools-mcp"], documented: true,
            targets: [
                .init(.safe, .leaves(root: ".cache/chrome-devtools-mcp/chrome-profile/Default",
                                     names: electronCacheLeaves + ["Service Worker/CacheStorage"]),
                      "agents.label.appCache", owners: []),
                .init(.safe, .leaves(root: ".cache/chrome-devtools-mcp/chrome-profile",
                                     names: ["GraphiteDawnCache", "component_crx_cache",
                                             "extensions_crx_cache"]),
                      "agents.label.appCache", owners: [])
            ],
            skillDirectories: [], mcpSources: []),
        // 以下工具没有公开的目录说明：应用本体还在时只显示占用；
        // presence（bundle/命令）都找不到时按已卸载残留放开清理。
        undocumented(id: "qoder", name: "Qoder", roots: [appSupport + "Qoder", ".qoder"],
                     skills: [".qoder/skills"], mcp: [], bundles: ["Qoder"]),
        undocumented(id: "kiro", name: "Kiro", roots: [appSupport + "Kiro", ".kiro"],
                     skills: [".kiro/skills"],
                     mcp: [.init(path: ".kiro/settings/mcp.json", format: .json(keyPath: "mcpServers"))],
                     bundles: ["Kiro"]),
        undocumented(id: "trae", name: "Trae", roots: [appSupport + "Trae", ".trae"],
                     skills: [".trae/skills"],
                     mcp: [.init(path: appSupport + "Trae/User/mcp.json", format: .json(keyPath: "mcpServers"))],
                     bundles: ["Trae"]),
        undocumented(id: "zed", name: "Zed", roots: [appSupport + "Zed", "Library/Caches/dev.zed.Zed"],
                     skills: [],
                     mcp: [.init(path: ".config/zed/settings.json", format: .json(keyPath: "context_servers"))],
                     bundles: ["Zed"]),
        undocumented(id: "warp", name: "Warp", roots: [appSupport + "dev.warp.Warp-Stable", ".warp"],
                     skills: [".warp/skills"],
                     mcp: [.init(path: ".warp/.mcp.json", format: .json(keyPath: "mcpServers"))],
                     bundles: ["Warp"]),
        undocumented(id: "amp", name: "Amp", roots: [".config/amp", ".cache/amp"],
                     skills: [".config/amp/skills"],
                     mcp: [.init(path: ".config/amp/settings.json", format: .json(keyPath: "amp.mcpServers"))],
                     commands: ["amp"]),
        undocumented(id: "crush", name: "Crush", roots: [".config/crush", ".local/share/crush"],
                     skills: [".config/crush/skills"],
                     mcp: [.init(path: ".config/crush/crush.json", format: .json(keyPath: "mcp"))],
                     commands: ["crush"]),
        AgentDefinition(
            id: "shared", name: "Shared", owners: [],
            detect: [".agents/skills", ".config/agents/skills"], documented: true,
            targets: [], skillDirectories: [".agents/skills", ".config/agents/skills"],
            mcpSources: [])
    ]

    private static func undocumented(id: String, name: String, roots: [String],
                                     skills: [String], mcp: [AgentMCPSource],
                                     bundles: [String] = [], commands: [String] = []) -> AgentDefinition {
        let presence = bundles.isEmpty && commands.isEmpty
            ? nil : AgentPresence(bundleNames: bundles, commands: commands)
        return AgentDefinition(id: id, name: name, owners: [], detect: roots, documented: false,
                        targets: roots.map { .init(.showOnly, .path($0), "agents.label.appData", owners: []) },
                        skillDirectories: skills, mcpSources: mcp, presence: presence)
    }

    // MARK: - 解析

    struct ResolvedTarget: Sendable {
        let agentID: String
        let tier: AgentTier
        let labelKey: String
        let owners: [String]
        let paths: [String]
    }

    static func isInstalled(_ agent: AgentDefinition, home: String) -> Bool {
        agent.detect.contains { exists(absolute($0, home: home)) }
    }

    /// undocumented 工具的应用本体探测：bundle 与命令都找不到 → 数据是已卸载残留。
    static func isOrphaned(_ agent: AgentDefinition, home: String,
                           presence context: AgentPresenceContext? = nil) -> Bool {
        guard !agent.documented, let presence = agent.presence else { return false }
        let context = context ?? defaultPresenceContext(home: home)
        let bundlePresent = presence.bundleNames.contains { name in
            context.applicationDirs.contains { exists($0 + "/" + name + ".app") }
        }
        if bundlePresent { return false }
        return !presence.commands.contains {
            resolveExecutable($0, searchPath: context.searchPath, home: home) != nil
        }
    }

    static func defaultPresenceContext(home: String) -> AgentPresenceContext {
        AgentPresenceContext(
            applicationDirs: ["/Applications", "/Applications/Setapp", home + "/Applications"],
            searchPath: executableSearchPath(home: home))
    }

    /// 目录解析的唯一入口：扫描与执行边界都调用它，保证两边的候选集合相同。
    static func resolve(_ agent: AgentDefinition, home: String,
                        presence context: AgentPresenceContext? = nil) -> [ResolvedTarget] {
        let orphaned = isOrphaned(agent, home: home, presence: context)
        return agent.targets.compactMap { target in
            let paths = resolve(target.kind, home: home)
            guard !paths.isEmpty else { return nil }
            let tier: AgentTier
            if agent.documented {
                tier = target.tier
            } else {
                tier = orphaned ? .review : .showOnly
            }
            return ResolvedTarget(agentID: agent.id,
                                  tier: tier,
                                  labelKey: target.labelKey,
                                  owners: target.owners ?? agent.owners,
                                  paths: paths)
        }
    }

    static func resolve(_ kind: AgentTarget.Kind, home: String) -> [String] {
        switch kind {
        case .path(let relative):
            let path = absolute(relative, home: home)
            return isPhysical(path, home: home) ? [path] : []
        case .leaves(let root, let names):
            let base = absolute(root, home: home)
            guard isPhysical(base, home: home) else { return [] }
            return names.map { base + "/" + $0 }.filter { isPhysical($0, home: home) }
        case .children(let relative):
            let base = absolute(relative, home: home)
            guard isPhysical(base, home: home) else { return [] }
            return childNames(of: base).map { base + "/" + $0 }.filter { isPhysical($0, home: home) }
        case .versions(let root, let links):
            return staleVersions(root: absolute(root, home: home),
                                 links: links.map { absolute($0, home: home) }, home: home)
        case .sqlite(let dir, let prefix, let ext):
            let base = absolute(dir, home: home)
            guard isPhysical(base, home: home) else { return [] }
            let names = childNames(of: base)
            let mains = names.filter { $0.hasPrefix(prefix) && $0.hasSuffix(ext) }
            return mains.flatMap { main in
                ([main] + sqliteCompanionSuffixes.map { main + $0 })
                    .filter(names.contains)
                    .map { base + "/" + $0 }
                    .filter { isPhysical($0, home: home) }
            }
        }
    }

    static let sqliteCompanionSuffixes = ["-wal", "-shm", "-journal"]

    /// 旧版本判定：被任一启动链接（完整解析符号链接链）指向的版本保留；
    /// 修改时间最新的版本也保留（可能是尚未切换的新下载）。
    static func staleVersions(root: String, links: [String], home: String) -> [String] {
        guard isPhysical(root, home: home) else { return [] }
        let candidates = childNames(of: root).map { root + "/" + $0 }
            .filter { isPhysical($0, home: home) }
        guard candidates.count > 1 else { return [] }
        var active = Set<String>()
        for link in links {
            guard isSymlink(link) else { continue }
            let target = URL(fileURLWithPath: link).resolvingSymlinksInPath().standardizedFileURL.path
            if let owner = candidates.first(where: { target == $0 || target.hasPrefix($0 + "/") }) {
                active.insert(owner)
            }
        }
        guard !active.isEmpty else { return [] }
        if let newest = candidates.max(by: { modified($0) < modified($1) }) {
            active.insert(newest)
        }
        return candidates.filter { !active.contains($0) }.sorted()
    }

    /// 执行边界复核：只返回当前目录仍解析为 safe/review 的路径。
    /// 已卸载工具的残留不再走 Agent 漏斗（清理扫描会作为应用残留收录），
    /// 因此这里只认仍装在机器上的 documented 工具。
    static func deletablePaths(home: String, presence context: AgentPresenceContext? = nil) -> Set<String> {
        var result = Set<String>()
        for agent in definitions where agent.documented {
            for target in resolve(agent, home: home, presence: context) where target.tier != .showOnly {
                result.formUnion(target.paths)
            }
        }
        return result
    }

    // MARK: - 可执行文件解析（presence 与 MCP 体检共用）

    static func executableSearchPath(home: String) -> [String] {
        let environment = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        let common = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
                      home + "/.local/bin", home + "/.bun/bin", home + "/.cargo/bin",
                      home + "/.volta/bin", home + "/.deno/bin", home + "/go/bin",
                      home + "/.npm-global/bin", home + "/Library/pnpm"]
        var seen = Set<String>()
        return (environment + common).filter { seen.insert($0).inserted }
    }

    static func resolveExecutable(_ command: String, searchPath: [String], home: String) -> String? {
        var candidate = command
        if candidate.hasPrefix("~/") { candidate = home + candidate.dropFirst(1) }
        if candidate.contains("/") {
            // 相对路径由宿主按插件或工作目录解析，这里无法判定缺失与否。
            guard candidate.hasPrefix("/") else { return candidate }
            return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
        }
        return searchPath.map { $0 + "/" + command }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: - Skills

    struct SkillDirectory: Sendable {
        let path: String
        let agentNames: [String]
    }

    /// 同一目录可能被多个 Agent 共享（~/.agents/skills 等），合并展示使用者。
    static func skillDirectories(home: String) -> [SkillDirectory] {
        var order: [String] = []
        var users: [String: [String]] = [:]
        for agent in definitions {
            for relative in agent.skillDirectories {
                let path = absolute(relative, home: home)
                guard isPhysical(path, home: home) else { continue }
                if users[path] == nil {
                    order.append(path)
                    users[path] = []
                }
                if agent.id != "shared" { users[path]?.append(agent.name) }
            }
        }
        return order.map { SkillDirectory(path: $0, agentNames: users[$0] ?? []) }
    }

    /// Skill 条目只接受已知 skills 目录的直接子目录；符号链接只展示不删除。
    static func isDeletableSkill(_ path: String, home: String) -> Bool {
        let parent = (path as NSString).deletingLastPathComponent
        return skillDirectories(home: home).contains { $0.path == parent }
            && isPhysical(path, home: home) && isDirectory(path)
    }

    // MARK: - 文件系统

    static func absolute(_ relative: String, home: String) -> String {
        URL(fileURLWithPath: home).appendingPathComponent(relative).standardizedFileURL.path
    }

    static func exists(_ path: String) -> Bool {
        var metadata = stat()
        return lstat(path, &metadata) == 0
    }

    static func isSymlink(_ path: String) -> Bool {
        var metadata = stat()
        return lstat(path, &metadata) == 0 && (metadata.st_mode & S_IFMT) == S_IFLNK
    }

    static func isDirectory(_ path: String) -> Bool {
        var metadata = stat()
        return lstat(path, &metadata) == 0 && (metadata.st_mode & S_IFMT) == S_IFDIR
    }

    /// 存在、位于 home 内，且从 home 到自身的每一级都不是符号链接。
    static func isPhysical(_ path: String, home: String) -> Bool {
        let base = URL(fileURLWithPath: home).standardizedFileURL.path
        guard path.hasPrefix(base + "/"), exists(path) else { return false }
        var current = path
        while current.count > base.count {
            if isSymlink(current) { return false }
            current = (current as NSString).deletingLastPathComponent
        }
        return true
    }

    static func childNames(of directory: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted()
    }

    private static func modified(_ path: String) -> Date {
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else { return .distantPast }
        return Date(timeIntervalSince1970: TimeInterval(metadata.st_mtimespec.tv_sec))
    }
}
