import Foundation

/// Agent 专清的三档目录：
/// - `safe`：可再生缓存/旧安装包或可丢弃诊断日志，默认勾选；日志删除会失去排障资料；
/// - `review`：会话、检查点、日志库等用户数据，删除后丢历史但不影响工具运行，交给用户选择；
/// - `showOnly`：敏感数据与未公开结构的数据，手动清理前明确提醒影响。
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
        /// 每个项目目录中的数据分别列出；用于把转录与持久 memory 拆开。
        case projectContents(root: String, excluding: [String])
        case projectLeaves(root: String, names: [String])
        /// 版本目录：保留被启动链接解析到的版本和最新版本，其余为旧版本。
        /// 没有任何链接能解析进 root 时无法证明谁在用，整个目标不产出。
        case versions(root: String, links: [String])
        /// `dir/<prefix>*<ext>` SQLite 文件及其 -wal/-shm/-journal 伴随文件。
        case sqlite(dir: String, prefix: String, ext: String)
        /// 只在已知 Agent 数据树中按限定深度查找数据库族，不进入项目源码树。
        case sqliteTree(root: String, prefix: String, ext: String, maxDepth: Int)
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

/// 安装本体的存在性线索：App bundle 名与 PATH 上的命令。
/// 两者都找不到时，其数据目录视为已卸载应用的残留，升级为可清理。
struct AgentPresence: Sendable {
    let bundleNames: [String]
    let commands: [String]
    var extensionIDs: [String] = []
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
    /// 数据存在性线索；这些目录留在磁盘上不代表 Agent 仍然安装着。
    let detect: [String]
    /// false 表示没有找到完整的官方目录说明：清理时提示结构与恢复影响尚未确认。
    let documented: Bool
    let targets: [AgentTarget]
    let skillDirectories: [String]
    let mcpSources: [AgentMCPSource]
    /// 自定义安装线索；默认由目录中的 Agent ID 对应到已知 bundle / CLI 命令。
    var presence: AgentPresence? = nil
    /// 兼容读取的外部 Skill 目录，仅表示消费者，不能作为本 Agent 的卸载残留。
    var implicitSkillDirectories: [String] = []
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

    /// 路径与风险证据见 docs/agent-cleanup-research/；Safe 必须是可再生数据。
    static let definitions: [AgentDefinition] = [
        AgentDefinition(
            id: "claude-code", name: "Claude Code", owners: ["claude"],
            detect: [".claude", ".local/share/claude"], documented: true,
            targets: [
                .init(.safe, .versions(root: ".local/share/claude/versions",
                                       links: [".local/bin/claude"]),
                      "agents.label.oldVersions", owners: []),
                .init(.safe, .path(".claude/statsig"), "agents.label.cache"),
                .init(.review, .projectContents(root: ".claude/projects", excluding: ["memory"]),
                      "agents.label.transcripts"),
                .init(.showOnly, .projectLeaves(root: ".claude/projects", names: ["memory"]),
                      "agents.label.knowledge"),
                .init(.review, .children(".claude/file-history"), "agents.label.fileHistory"),
                .init(.review, .children(".claude/shell-snapshots"), "agents.label.shellSnapshots"),
                .init(.review, .children(".claude/todos"), "agents.label.todos"),
                .init(.review, .path(".claude/paste-cache"), "agents.label.pasteCache"),
                .init(.review, .path(".claude/debug"), "agents.label.logs"),
                .init(.review, .children(".claude/plans"), "agents.label.plans"),
                .init(.review, .children(".claude/tasks"), "agents.label.todos"),
                .init(.review, .path(".claude/feedback/drafts"), "agents.label.appData"),
                .init(.review, .path(".claude/usage-data"), "agents.label.appData"),
                .init(.review, .children(".claude/uploads"), "agents.label.generatedImages"),
                .init(.review, .children(".claude/image-cache"), "agents.label.generatedImages"),
                .init(.review, .children(".claude/backups"), "agents.label.fileHistory"),
                .init(.review, .path(".claude/feedback-bundles"), "agents.label.appData"),
                .init(.safe, .path(".claude/stats-cache.json"), "agents.label.cache"),
                .init(.safe, .path(".claude/cache/changelog.md"), "agents.label.cache"),
                .init(.showOnly, .path(".claude/session-env"), "agents.label.shellSnapshots"),
                .init(.showOnly, .path(".claude/sessions"), "agents.label.workspaceState"),
                .init(.showOnly, .path(".claude/agent-memory"), "agents.label.knowledge"),
                .init(.showOnly, .path(".claude/jobs"), "agents.label.todos"),
                .init(.showOnly, .path(".claude/daemon"), "agents.label.workspaceState"),
                .init(.showOnly, .path(".claude/history.jsonl"), "agents.label.history", owners: []),
                .init(.showOnly, .path(".claude/.credentials.json"), "agents.label.credentials"),
                .init(.showOnly, .path(".claude/settings.json"), "agents.label.configuration")
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
                // Cowork VM 包含活动磁盘与会话状态，并非只有可重新下载的镜像。
                .init(.review, .path(appSupport + "Claude/vm_bundles"), "agents.label.vmBundles"),
                .init(.safe, .path("Library/Caches/com.anthropic.claudefordesktop"),
                      "agents.label.cache"),
                .init(.safe, .path("Library/Caches/com.anthropic.claudefordesktop.ShipIt"),
                      "agents.label.updateStaging"),
                .init(.safe, .path("Library/Logs/Claude"), "agents.label.logs")
            ],
            skillDirectories: [],
            mcpSources: [.init(path: appSupport + "Claude/claude_desktop_config.json",
                               format: .json(keyPath: "mcpServers"))]),
        AgentDefinition(
            id: "codex", name: "Codex CLI", owners: ["codex", "Codex", "com.openai.codex"],
            detect: [".codex"], documented: true,
            targets: [
                .init(.review, .sqlite(dir: ".codex", prefix: "logs_", ext: ".sqlite"),
                      "agents.label.logDatabase"),
                .init(.review, .path(".codex/.tmp"), "agents.label.tempFiles"),
                .init(.safe, .path(".codex/tmp"), "agents.label.tempFiles"),
                .init(.safe, .path(".codex/log"), "agents.label.logs"),
                .init(.safe, .path(".codex/models_cache.json"), "agents.label.cache"),
                .init(.review, .path(".codex/cache"), "agents.label.cache"),
                .init(.review, .children(".codex/db-backups"), "agents.label.fileHistory"),
                .init(.showOnly, .children(".codex/shell_snapshots"), "agents.label.shellSnapshots"),
                .init(.review, .path(".codex/generated_images"), "agents.label.generatedImages"),
                .init(.review, .children(".codex/archived_sessions"), "agents.label.archivedSessions"),
                .init(.showOnly, .path(".codex/sessions"), "agents.label.sessions", owners: []),
                .init(.showOnly, .sqlite(dir: ".codex", prefix: "state_", ext: ".sqlite"),
                      "agents.label.stateDatabase", owners: []),
                .init(.showOnly, .sqlite(dir: ".codex", prefix: "thread_history_", ext: ".sqlite"),
                      "agents.label.historyDatabase", owners: []),
                .init(.showOnly, .sqlite(dir: ".codex", prefix: "goals_", ext: ".sqlite"),
                      "agents.label.stateDatabase"),
                .init(.showOnly, .sqlite(dir: ".codex", prefix: "memories_", ext: ".sqlite"),
                      "agents.label.stateDatabase"),
                .init(.showOnly, .sqlite(dir: ".codex", prefix: "queue_", ext: ".sqlite"),
                      "agents.label.stateDatabase"),
                .init(.showOnly, .path(".codex/history.jsonl"), "agents.label.history", owners: []),
                .init(.showOnly, .path(".codex/auth.json"), "agents.label.credentials"),
                .init(.showOnly, .path(".codex/.credentials.json"), "agents.label.credentials")
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
                .init(.showOnly, .sqlite(dir: appSupport + "Cursor/User/globalStorage", prefix: "state", ext: ".vscdb"),
                      "agents.label.stateDatabase", owners: [])
            ],
            skillDirectories: [".cursor/skills"],
            mcpSources: [.init(path: ".cursor/mcp.json", format: .json(keyPath: "mcpServers"))],
            implicitSkillDirectories: [".claude/skills", ".codex/skills", ".agents/skills"]),
        AgentDefinition(
            id: "cursor-cli", name: "Cursor CLI", owners: ["cursor-agent", "Cursor", "com.todesktop.230313mzl4w4u92"],
            detect: [".local/share/cursor-agent", ".cursor/cli-config.json", ".cursor/chats"], documented: true,
            targets: [
                .init(.safe, .versions(root: ".local/share/cursor-agent/versions",
                                       links: [".local/bin/cursor-agent", ".local/bin/agent"]),
                      "agents.label.oldVersions", owners: []),
                .init(.showOnly, .sqliteTree(root: ".cursor/chats", prefix: "store", ext: ".db", maxDepth: 3),
                      "agents.label.conversationDatabase"),
                .init(.showOnly, .children(".cursor/worktrees"), "agents.label.worktrees"),
                .init(.showOnly, .path(".cursor/cli-config.json"), "agents.label.configuration")
            ],
            skillDirectories: [".cursor/skills"],
            mcpSources: [.init(path: ".cursor/mcp.json", format: .json(keyPath: "mcpServers"))],
            implicitSkillDirectories: [".claude/skills", ".codex/skills", ".agents/skills"]),
        AgentDefinition(
            id: "copilot", name: "GitHub Copilot CLI", owners: ["copilot"],
            detect: [".copilot"], documented: true,
            targets: [
                .init(.safe, .versions(root: ".copilot/pkg/universal", links: [".local/bin/copilot"]),
                      "agents.label.oldVersions", owners: []),
                .init(.safe, .path(".copilot/logs"), "agents.label.logs"),
                .init(.safe, .path("Library/Caches/copilot"), "agents.label.cache"),
                .init(.review, .children(".copilot/session-state"), "agents.label.sessions"),
                .init(.showOnly, .sqlite(dir: ".copilot", prefix: "session-store", ext: ".db"),
                      "agents.label.conversationDatabase"),
                .init(.showOnly, .path(".copilot/config.json"), "agents.label.credentials"),
                .init(.showOnly, .path(".copilot/settings.json"), "agents.label.configuration"),
                .init(.showOnly, .path(".copilot/mcp-secrets"), "agents.label.credentials"),
                .init(.showOnly, .path(".copilot/mcp-oauth-config"), "agents.label.credentials"),
                .init(.review, .path(".copilot/command-history-state"), "agents.label.history"),
                .init(.showOnly, .path(".copilot/permissions-config.json"), "agents.label.configuration"),
                .init(.showOnly, .path(".copilot/permissions-config"), "agents.label.configuration"),
                .init(.showOnly, .path(".copilot/providers.json"), "agents.label.configuration"),
                .init(.showOnly, .path(".copilot/plugin-data"), "agents.label.appData")
            ],
            skillDirectories: [".copilot/skills"],
            mcpSources: [.init(path: ".copilot/mcp-config.json", format: .json(keyPath: "mcpServers"))]),
        AgentDefinition(
            id: "gemini", name: "Gemini CLI", owners: ["gemini"],
            detect: [".gemini/settings.json", ".gemini/tmp"], documented: true,
            targets: [
                .init(.review, .children(".gemini/tmp"), "agents.label.sessions"),
                .init(.review, .children(".gemini/history"), "agents.label.history"),
                .init(.review, .path(".gemini/projects.json"), "agents.label.workspaceState"),
                .init(.review, .path(".cache/.gemini"), "agents.label.tempFiles"),
                .init(.showOnly, .path(".gemini/oauth_creds.json"), "agents.label.credentials"),
                .init(.showOnly, .path(".gemini/google_accounts.json"), "agents.label.credentials"),
                .init(.showOnly, .path(".gemini/mcp-oauth-tokens.json"), "agents.label.credentials"),
                .init(.showOnly, .path(".gemini/a2a-oauth-tokens.json"), "agents.label.credentials"),
                .init(.showOnly, .path(".gemini/gemini-credentials.json"), "agents.label.credentials"),
                .init(.showOnly, .path(".gemini/settings.json"), "agents.label.configuration")
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
                .init(.review, .path(".gemini/antigravity/browser_recordings"),
                      "agents.label.browserRecordings"),
                .init(.showOnly, .path(".gemini/antigravity/conversations"),
                      "agents.label.conversations", owners: []),
                .init(.showOnly, .path(".gemini/antigravity/brain"), "agents.label.knowledge", owners: []),
                .init(.showOnly, .path(".gemini/antigravity/mcp_oauth_tokens.json"), "agents.label.credentials")
            ],
            skillDirectories: [".gemini/config/skills", ".gemini/antigravity/skills"],
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
                .init(.review, .path(".local/share/opencode/plans"), "agents.label.plans"),
                .init(.showOnly, .path(".local/share/opencode/repos"), "agents.label.worktrees"),
                .init(.review, .path(".local/state/opencode"), "agents.label.workspaceState"),
                // 新版数据库还包含 credential 表，删除会同时丢失 OAuth/API 凭据。
                .init(.showOnly, .sqlite(dir: ".local/share/opencode", prefix: "opencode", ext: ".db"),
                      "agents.label.conversationDatabase"),
                .init(.review, .path(".local/share/opencode/storage"), "agents.label.sessions"),
                .init(.showOnly, .path(".local/share/opencode/auth.json"), "agents.label.credentials"),
                .init(.showOnly, .path(".local/share/opencode/mcp-auth.json"), "agents.label.credentials")
            ],
            skillDirectories: [".config/opencode/skills"],
            mcpSources: [
                .init(path: ".config/opencode/opencode.json", format: .json(keyPath: "mcp")),
                .init(path: ".config/opencode/opencode.jsonc", format: .json(keyPath: "mcp"))
            ]),
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
                .init(.showOnly, .sqlite(dir: ".grok", prefix: "worktrees", ext: ".db"),
                      "agents.label.workspaceState"),
                .init(.showOnly, .path(".grok/worktrees"), "agents.label.worktrees", owners: []),
                .init(.showOnly, .path(".grok/memory"), "agents.label.knowledge"),
                .init(.showOnly, .path(".grok/memory-v2"), "agents.label.knowledge"),
                .init(.showOnly, .path(".grok/auth.json"), "agents.label.credentials"),
                .init(.showOnly, .path(".grok/mcp_credentials.json"), "agents.label.credentials")
            ],
            skillDirectories: [".grok/skills"],
            mcpSources: [.init(path: ".grok/config.toml", format: .toml(table: "mcp_servers"))]),
        AgentDefinition(
            id: "pi", name: "pi", owners: ["pi"],
            detect: [".pi"], documented: true,
            targets: [
                .init(.review, .children(".pi/agent/sessions"), "agents.label.sessions"),
                .init(.safe, .path(".pi/agent/pi-debug.log"), "agents.label.logs"),
                .init(.safe, .path(".pi/agent/tmp/extensions"), "agents.label.tempFiles"),
                .init(.showOnly, .path(".pi/agent/auth.json"), "agents.label.credentials"),
                .init(.showOnly, .path(".pi/agent/mcp-auth.json"), "agents.label.credentials"),
                .init(.showOnly, .path(".pi/agent/settings.json"), "agents.label.configuration"),
                .init(.showOnly, .path(".pi/agent/models.json"), "agents.label.configuration")
            ],
            skillDirectories: [".pi/agent/skills"],
            mcpSources: [.init(path: ".pi/agent/mcp.json", format: .json(keyPath: "mcpServers"))]),
        AgentDefinition(
            id: "kimi", name: "Kimi", owners: ["kimi", "kimi-cli"],
            detect: [".kimi", ".kimi-code"], documented: true,
            targets: [
                .init(.review, .children(".kimi/sessions"), "agents.label.sessions"),
                .init(.review, .path(".kimi/user-history"), "agents.label.history"),
                .init(.review, .path(".kimi/plans"), "agents.label.plans"),
                .init(.safe, .path(".kimi/logs"), "agents.label.logs"),
                .init(.review, .path(".kimi/prompt-cache"), "agents.label.pasteCache"),
                .init(.review, .path(".kimi/kimi.json"), "agents.label.workspaceState"),
                .init(.showOnly, .path(".kimi/credentials"), "agents.label.credentials"),
                .init(.showOnly, .path(".kimi/mcp-oauth"), "agents.label.credentials"),
                .init(.showOnly, .path(".kimi/config.toml"), "agents.label.configuration"),
                .init(.showOnly, .path(".kimi/config.json"), "agents.label.configuration"),
                .init(.safe, .path(".kimi-code/cache"), "agents.label.cache"),
                .init(.safe, .path(".kimi-code/logs"), "agents.label.logs"),
                .init(.review, .children(".kimi-code/sessions"), "agents.label.sessions"),
                .init(.review, .path(".kimi-code/blobs"), "agents.label.generatedImages"),
                .init(.showOnly, .path(".kimi-code/store"), "agents.label.stateDatabase"),
                .init(.review, .path(".kimi-code/user-history"), "agents.label.history"),
                .init(.showOnly, .path(".kimi-code/session_index.jsonl"), "agents.label.workspaceState"),
                .init(.showOnly, .path(".kimi-code/credentials"), "agents.label.credentials"),
                .init(.showOnly, .path(".kimi-code/server.token"), "agents.label.credentials"),
                .init(.showOnly, .path(".kimi-code/config.toml"), "agents.label.configuration"),
                .init(.showOnly, .path(".kimi-code/tui.toml"), "agents.label.configuration")
            ],
            skillDirectories: [".kimi/skills", ".kimi-code/skills"],
            mcpSources: [.init(path: ".kimi/mcp.json", format: .json(keyPath: "mcpServers")),
                        .init(path: ".kimi-code/mcp.json", format: .json(keyPath: "mcpServers"))]),
        AgentDefinition(
            id: "factory", name: "Factory Droid", owners: ["droid", "Factory"],
            detect: [".factory"], documented: true,
            targets: [
                .init(.review, .children(".factory/sessions"), "agents.label.sessions"),
                .init(.review, .path(".factory/logs"), "agents.label.logs"),
                .init(.review, .path(".factory/cache"), "agents.label.cache"),
                .init(.review, .path(".factory/temp"), "agents.label.tempFiles"),
                .init(.showOnly, .children(".factory/worktrees"), "agents.label.worktrees"),
                .init(.review, .children(".factory/specs"), "agents.label.plans"),
                .init(.showOnly, .path(".factory/settings.json"), "agents.label.configuration"),
                .init(.showOnly, .path(".factory/settings.local.json"), "agents.label.configuration")
            ],
            skillDirectories: [".factory/skills"],
            mcpSources: [.init(path: ".factory/mcp.json", format: .json(keyPath: "mcpServers"))]),
        AgentDefinition(
            id: "devin", name: "Devin", owners: ["Devin", "Windsurf", "com.exafunction.windsurf"],
            detect: [appSupport + "Devin", ".devin", ".codeium/windsurf"], documented: true,
            targets: [
                .init(.safe, .leaves(root: appSupport + "Devin", names: electronCacheLeaves),
                      "agents.label.appCache"),
                .init(.showOnly, .path(appSupport + "Devin/WebStorage"), "agents.label.appData", owners: []),
                .init(.showOnly, .path(".codeium/windsurf/cascade"), "agents.label.conversations"),
                .init(.showOnly, .path(".codeium/windsurf/memories"), "agents.label.knowledge")
            ],
            skillDirectories: [".codeium/windsurf/skills", ".config/devin/skills"],
            mcpSources: [.init(path: ".config/devin/mcp_config.json", format: .json(keyPath: "mcpServers"))]),
        AgentDefinition(
            id: "windsurf", name: "Windsurf", owners: ["Windsurf", "com.exafunction.windsurf", "Devin"],
            detect: [appSupport + "Windsurf", ".codeium/windsurf"], documented: true,
            targets: [
                .init(.safe, .leaves(root: appSupport + "Windsurf", names: electronCacheLeaves),
                      "agents.label.appCache"),
                .init(.showOnly, .path(".codeium/windsurf/cascade"), "agents.label.conversations", owners: []),
                .init(.showOnly, .path(".codeium/windsurf/memories"), "agents.label.knowledge")
            ],
            skillDirectories: [".codeium/windsurf/skills"],
            mcpSources: [
                .init(path: ".codeium/windsurf/mcp_config.json", format: .json(keyPath: "mcpServers")),
                .init(path: ".codeium/mcp_config.json", format: .json(keyPath: "mcpServers"))
            ]),
        AgentDefinition(
            id: "chrome-devtools-mcp", name: "Chrome DevTools MCP",
            owners: ["Google Chrome", "Google Chrome for Testing", "chrome-devtools-mcp"],
            detect: [".cache/chrome-devtools-mcp"], documented: true,
            targets: [
                .init(.safe, .leaves(root: ".cache/chrome-devtools-mcp/chrome-profile/Default",
                                     names: electronCacheLeaves),
                      "agents.label.appCache"),
                .init(.review, .path(".cache/chrome-devtools-mcp/chrome-profile/Default/Service Worker/CacheStorage"),
                      "agents.label.appData"),
                .init(.safe, .leaves(root: ".cache/chrome-devtools-mcp/chrome-profile",
                                     names: ["GraphiteDawnCache", "component_crx_cache",
                                             "extensions_crx_cache"]),
                      "agents.label.appCache")
            ],
            skillDirectories: [], mcpSources: []),
        // 尚未确认内部生命周期的目录允许用户手动清理，明确提示风险；
        // presence（bundle/命令）都找不到时按已卸载残留进入清理页。
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
        AgentDefinition(
            id: "zed", name: "Zed", owners: ["Zed", "dev.zed.Zed"],
            detect: [appSupport + "Zed", "Library/Caches/Zed", ".config/zed"], documented: true,
            targets: [
                .init(.safe, .path("Library/Caches/Zed"), "agents.label.cache"),
                .init(.safe, .path("Library/Logs/Zed"), "agents.label.logs"),
                .init(.safe, .path(appSupport + "Zed/hang_traces"), "agents.label.logs"),
                .init(.showOnly, .sqlite(dir: appSupport + "Zed/threads", prefix: "threads", ext: ".db"),
                      "agents.label.conversationDatabase"),
                .init(.showOnly, .sqliteTree(root: appSupport + "Zed/db", prefix: "db", ext: ".sqlite", maxDepth: 2),
                      "agents.label.workspaceState"),
                .init(.showOnly, .path(".local/state/Zed"), "agents.label.workspaceState"),
                .init(.showOnly, .path(".config/zed/settings.json"), "agents.label.configuration"),
                .init(.showOnly, .path(".config/zed/prompts"), "agents.label.knowledge"),
                .init(.showOnly, .path(".config/zed/prompt_overrides"), "agents.label.knowledge"),
                .init(.showOnly, .path(".config/zed/themes"), "agents.label.configuration"),
                .init(.showOnly, .path(".config/zed/snippets"), "agents.label.configuration")
            ], skillDirectories: [],
            mcpSources: [.init(path: ".config/zed/settings.json", format: .json(keyPath: "context_servers"))],
            presence: .init(bundleNames: ["Zed", "Zed Preview", "Zed Nightly"], commands: ["zed"])),
        AgentDefinition(
            id: "warp", name: "Warp", owners: ["Warp", "WarpPreview", "dev.warp.Warp-Stable", "dev.warp.Warp-Preview"],
            detect: warpDataRoots + [".warp"], documented: true,
            targets: warpDataRoots.flatMap { root in [
                .init(.showOnly, .sqlite(dir: root, prefix: "warp", ext: ".sqlite"),
                      "agents.label.conversationDatabase"),
                .init(.showOnly, .sqlite(dir: root + "/tui", prefix: "warp", ext: ".sqlite"),
                      "agents.label.conversationDatabase")
            ] } + [
                .init(.safe, .path("Library/Logs/warp.log"), "agents.label.logs"),
                .init(.safe, .path("Library/Logs/warp_preview.log"), "agents.label.logs")
            ],
            skillDirectories: [".warp/skills"],
            mcpSources: [.init(path: ".warp/.mcp.json", format: .json(keyPath: "mcpServers"))],
            presence: .init(bundleNames: ["Warp", "WarpPreview", "Warp Preview"], commands: [])),
        undocumented(id: "amp", name: "Amp", roots: [".config/amp", ".cache/amp"],
                     skills: [".config/amp/skills"],
                     mcp: [.init(path: ".config/amp/settings.json", format: .json(keyPath: "amp.mcpServers"))],
                     commands: ["amp"]),
        AgentDefinition(
            id: "crush", name: "Crush", owners: ["crush"],
            detect: [".config/crush", ".local/share/crush", ".cache/crush"], documented: true,
            targets: [
                .init(.showOnly, .path(".config/crush/crush.json"), "agents.label.configuration"),
                .init(.showOnly, .path(".config/crush/crushrc"), "agents.label.configuration"),
                .init(.showOnly, .path(".local/share/crush/crush.json"), "agents.label.credentials"),
                .init(.review, .path(".local/share/crush/projects.json"), "agents.label.workspaceState"),
                .init(.safe, .path(".local/share/crush/providers.json"), "agents.label.cache"),
                .init(.review, .path(".cache/crush"), "agents.label.cache")
            ],
            skillDirectories: [".config/crush/skills"],
            mcpSources: [.init(path: ".config/crush/crush.json", format: .json(keyPath: "mcp")),
                        .init(path: ".local/share/crush/crush.json", format: .json(keyPath: "mcp"))],
            presence: .init(bundleNames: [], commands: ["crush"])),
        AgentDefinition(
            id: "shared", name: "Shared", owners: [],
            detect: [".agents/skills", ".config/agents/skills"], documented: true,
            targets: [], skillDirectories: [".agents/skills", ".config/agents/skills"],
            mcpSources: [])
    ]

    static let warpDataRoots = [
        "Library/Group Containers/2BBY89MBSN.dev.warp/Library/Application Support/dev.warp.Warp-Stable",
        "Library/Group Containers/2BBY89MBSN.dev.warp/Library/Application Support/dev.warp.Warp-Preview",
        appSupport + "dev.warp.Warp-Stable", appSupport + "dev.warp.Warp-Preview"
    ]

    private static func undocumented(id: String, name: String, roots: [String],
                                     skills: [String], mcp: [AgentMCPSource],
                                     bundles: [String] = [], commands: [String] = []) -> AgentDefinition {
        let presence = bundles.isEmpty && commands.isEmpty
            ? nil : AgentPresence(bundleNames: bundles, commands: commands)
        return AgentDefinition(id: id, name: name, owners: bundles + commands, detect: roots, documented: false,
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

    static func hasData(_ agent: AgentDefinition, home: String) -> Bool {
        dataRoots(for: agent, home: home).contains { exists($0) }
    }

    static func installationPresence(for agent: AgentDefinition) -> AgentPresence? {
        if let presence = agent.presence { return presence }
        let known: [String: AgentPresence] = [
            "claude-code": .init(bundleNames: ["Claude"], commands: ["claude"], extensionIDs: ["anthropic.claude-code"]),
            "claude-desktop": .init(bundleNames: ["Claude"], commands: []),
            // 桌面版使用同一个 .codex 数据根和内置 CLI。
            "codex": .init(bundleNames: ["Codex"], commands: ["codex"]),
            "codex-app": .init(bundleNames: ["Codex"], commands: []),
            "cursor": .init(bundleNames: ["Cursor"], commands: ["cursor"]),
            "cursor-cli": .init(bundleNames: [], commands: ["cursor-agent"]),
            "copilot": .init(bundleNames: [], commands: ["copilot"], extensionIDs: ["github.copilot", "github.copilot-chat"]),
            "gemini": .init(bundleNames: [], commands: ["gemini"]),
            "antigravity": .init(bundleNames: ["Antigravity"], commands: ["antigravity"]),
            "opencode": .init(bundleNames: ["OpenCode", "opencode"], commands: ["opencode"]),
            "grok": .init(bundleNames: [], commands: ["grok"]),
            "pi": .init(bundleNames: [], commands: ["pi"]),
            "kimi": .init(bundleNames: [], commands: ["kimi", "kimi-cli"]),
            "factory": .init(bundleNames: ["Factory"], commands: ["droid"]),
            "devin": .init(bundleNames: ["Devin"], commands: ["devin"]),
            "windsurf": .init(bundleNames: ["Windsurf"], commands: ["windsurf"])
        ]
        return known[agent.id]
    }

    static func isInstalled(_ agent: AgentDefinition, home: String,
                            presence context: AgentPresenceContext? = nil) -> Bool {
        // 共享 Skill 和独立 MCP 缓存是资源集合，不能用某个 Agent 本体判残留。
        guard let presence = installationPresence(for: agent) else { return hasData(agent, home: home) }
        let context = context ?? defaultPresenceContext(home: home)
        if presence.bundleNames.contains(where: { name in
            context.applicationDirs.contains { isDirectory($0 + "/" + name + ".app") }
        }) { return true }
        if presence.commands.contains(where: {
            resolveExecutable($0, searchPath: context.searchPath, home: home) != nil
        }) { return true }
        if AgentHostPresence.hasExtension(ids: presence.extensionIDs, home: home, context: context) { return true }
        // 某些安装器只放在私有 bin，不写到当前进程的 PATH。
        // 注入搜索范围的测试严格使用给定范围。
        guard context.searchPath == executableSearchPath(home: home) else { return false }
        return nativeLaunchers(for: agent).contains { relative in
            let path = absolute(relative, home: home)
            guard isExecutableCommandFile(path) else { return false }
            // `agent` 同时被 Cursor/Grok 等安装器使用，不能只按入口名判归属。
            if relative == ".local/bin/agent", agent.id == "cursor-cli" {
                let target = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                return target.hasPrefix(absolute(".local/share/cursor-agent", home: home) + "/")
            }
            return true
        }
    }

    /// 所有 Agent 都按安装本体判定残留，不能把旧配置目录当成安装证据。
    static func isOrphaned(_ agent: AgentDefinition, home: String,
                           presence context: AgentPresenceContext? = nil) -> Bool {
        installationPresence(for: agent) != nil && hasData(agent, home: home)
            && !isInstalled(agent, home: home, presence: context)
    }

    static func runtimeOwners(for agent: AgentDefinition, home: String,
                              presence context: AgentPresenceContext? = nil) -> [String] {
        let extensions = installationPresence(for: agent)?.extensionIDs ?? []
        return Array(Set(agent.owners + AgentHostPresence.owners(ids: extensions, home: home,
            context: context ?? defaultPresenceContext(home: home)))).sorted()
    }

    static func nativeLaunchers(for agent: AgentDefinition) -> [String] {
        switch agent.id {
        case "claude-code": return [".local/bin/claude", ".claude/local/claude"]
        case "cursor-cli": return [".local/bin/cursor-agent", ".local/bin/agent"]
        case "copilot": return [".local/bin/copilot"]
        case "opencode": return [".opencode/bin/opencode", ".local/bin/opencode"]
        case "grok": return [".grok/bin/grok", ".grok/bin/agent", ".local/bin/grok"]
        case "factory": return [".local/bin/droid"]
        case "kimi": return [".kimi-code/bin/kimi", ".local/bin/kimi"]
        case "amp": return [".amp/bin/amp", ".local/bin/amp"]
        default: return []
        }
    }

    /// 数据根覆盖缓存、会话、配置与安装下载，合并父子路径避免重复计量。
    /// Gemini 与 Antigravity 共享 .gemini，因此 Gemini 只认自己的叶子。
    static func dataRoots(for agent: AgentDefinition, home: String) -> [String] {
        // 自定义 home 不能证明整根独占（可能就是 Documents）；只取已知叶子。
        var roots = agent.detect.filter {
            absolute($0, home: home) == URL(fileURLWithPath: home).appendingPathComponent($0).standardizedFileURL.path
        } + agent.skillDirectories + agent.mcpSources.map(\.path)
        for target in agent.targets {
            roots += targetPaths(target, home: home)
        }
        if agent.id == "opencode" { roots += [".local/state/opencode", ".opencode"] }
        let unique = Array(Set(roots.map { absolute($0, home: home) }
            + AgentProjectStorage.residualPaths(for: agent.id, home: home))).sorted()
        return unique.filter { path in
            !unique.contains { $0 != path && path.hasPrefix($0 + "/") }
        }
    }

    static func orphanedDataRoots(_ agent: AgentDefinition, home: String,
                                  presence context: AgentPresenceContext? = nil) -> [String] {
        guard isOrphaned(agent, home: home, presence: context) else { return [] }
        let liveRoots = definitions.filter {
            $0.id != agent.id && installationPresence(for: $0) != nil
                && isInstalled($0, home: home, presence: context)
        }.flatMap { dataRoots(for: $0, home: home)
            + $0.implicitSkillDirectories.map { absolute($0, home: home) } }
        var sharedSkillTargets = Set(definitions.filter {
            $0.id != agent.id && isInstalled($0, home: home, presence: context)
        }.flatMap { definition in
            (definition.skillDirectories + definition.implicitSkillDirectories).flatMap { relative in
                let directory = absolute(relative, home: home)
                guard isPhysical(directory, home: home) else { return [String]() }
                return childNames(of: directory).compactMap { name -> String? in
                    let link = directory + "/" + name
                    guard isSymlink(link) else { return nil }
                    return URL(fileURLWithPath: link).resolvingSymlinksInPath().standardizedFileURL.path
                }
            }
        })
        if let codex = definitions.first(where: { $0.id == "codex" }),
           isInstalled(codex, home: home, presence: context) {
            sharedSkillTargets.formUnion(configuredSkillTargets(home: home))
        }
        let roots = dataRoots(for: agent, home: home).filter { isPhysical($0, home: home) }
        func unsharedParts(_ path: String) -> [String] {
            if liveRoots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return [] }
            if sharedSkillTargets.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return [] }
            guard (Array(sharedSkillTargets) + liveRoots).contains(where: { $0.hasPrefix(path + "/") }) else { return [path] }
            // 只在含共享实体的祖先上拆分，保留本体和祖先目录，其他数据仍进入清理。
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).sorted()
            return names.flatMap { name -> [String] in
                let child = path + "/" + name
                return isPhysical(child, home: home) ? unsharedParts(child) : []
            }
        }
        return roots.flatMap(unsharedParts).sorted()
    }

    /// Codex 的 [[skills.config]] 支持直接指定 Skill 路径，未必创建符号链接。
    /// 这里只读 path，避免目录服务依赖配置编辑器与其执行相关类型。
    private static func configuredSkillTargets(home: String) -> [String] {
        guard let handle = FileHandle(forReadingAtPath: absolute(".codex/config.toml", home: home)) else { return [] }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 1_048_576),
              let text = String(data: data, encoding: .utf8) else { return [] }
        var inSkill = false
        var paths: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            var quoted: Character?
            var escaped = false
            var line = ""
            for character in raw {
                if escaped { escaped = false; line.append(character); continue }
                if quoted == "\"", character == "\\" { escaped = true; line.append(character); continue }
                if character == quoted { quoted = nil }
                else if quoted == nil, character == "\"" || character == "'" { quoted = character }
                else if quoted == nil, character == "#" { break }
                line.append(character)
            }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inSkill = line == "[[skills.config]]"; continue }
            guard inSkill, let equals = line.firstIndex(of: "="),
                  line[..<equals].trimmingCharacters(in: .whitespaces) == "path" else { continue }
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            let decoded: String?
            if value.hasPrefix("\""), let data = ("[" + value + "]").data(using: .utf8) {
                decoded = ((try? JSONSerialization.jsonObject(with: data)) as? [String])?.first
            } else if value.count >= 2, value.first == "'", value.last == "'" {
                decoded = String(value.dropFirst().dropLast())
            } else { decoded = nil }
            guard let decoded else { continue }
            let absolute = decoded.hasPrefix("~/") ? home + decoded.dropFirst() : decoded
            guard (absolute as NSString).isAbsolutePath else { continue }
            var target = URL(fileURLWithPath: absolute).resolvingSymlinksInPath().standardizedFileURL.path
            if (target as NSString).lastPathComponent == "SKILL.md" {
                target = (target as NSString).deletingLastPathComponent
            }
            paths.append(target)
        }
        return paths
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
        return (agent.targets + AgentProjectStorage.targets(for: agent.id, home: home)).compactMap { target in
            let paths = targetPaths(target, home: home)
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
                                  owners: target.tier == .showOnly || target.owners == nil
                                    ? runtimeOwners(for: agent, home: home, presence: context) : target.owners!,
                                  paths: paths)
        }
    }

    static func targetPaths(_ target: AgentTarget, home: String,
                            environment: [String: String]? = nil) -> [String] {
        let environment = environment ?? storageEnvironment(home: home)
        if case .path(".cache/crush") = target.kind,
           environment["CRUSH_CACHE_DIR"] != nil,
           absolute(".cache/crush", home: home, environment: environment) != home + "/.cache/crush" {
            // 直接覆盖可能指向共用目录；缺乏精确叶子证据时不认领整个根。
            return []
        }
        if case .path(".codex/log") = target.kind,
           let root = codexConfiguredDirectory("log_dir", home: home, environment: environment) {
            // log_dir 可能是共用目录，不能将整个目录当作 Codex 专属缓存。
            let path = root + "/codex-tui.log"
            return isPhysical(path, home: home) && !isDirectory(path) ? [path] : []
        }
        return resolve(target.kind, home: home)
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
        case .projectContents(let root, let excluded):
            let projects = resolve(.children(root), home: home).filter(isDirectory)
            return projects.flatMap { project in
                childNames(of: project).filter { !excluded.contains($0) }
                    .map { project + "/" + $0 }.filter { isPhysical($0, home: home) }
            }
        case .projectLeaves(let root, let names):
            let projects = resolve(.children(root), home: home).filter(isDirectory)
            return projects.flatMap { project in
                names.map { project + "/" + $0 }.filter { isPhysical($0, home: home) }
            }
        case .versions(let root, let links):
            return staleVersions(root: absolute(root, home: home),
                                 links: links.map { absolute($0, home: home) }, home: home)
        case .sqlite(let dir, let prefix, let ext):
            let base = dir == ".codex" ? codexSQLiteDirectory(home: home) : absolute(dir, home: home)
            guard isPhysical(base, home: home) else { return [] }
            let names = childNames(of: base)
            // 历史版本写过 openCode.db；按大小写不敏感匹配，并纳入主库已消失的伴随文件。
            let mains = Set(names.compactMap { name -> String? in
                let main = sqliteCompanionSuffixes.reduce(name) { current, suffix in
                    current.hasSuffix(suffix) ? String(current.dropLast(suffix.count)) : current
                }
                return main.lowercased().hasPrefix(prefix.lowercased())
                    && main.lowercased().hasSuffix(ext.lowercased()) ? main : nil
            })
            return mains.sorted().flatMap { main in
                ([main] + sqliteCompanionSuffixes.map { main + $0 })
                    .filter(names.contains)
                    .map { base + "/" + $0 }
                    .filter { isPhysical($0, home: home) }
            }
        case .sqliteTree(let root, let prefix, let ext, let maxDepth):
            let base = absolute(root, home: home)
            guard isPhysical(base, home: home) else { return [] }
            var pending = [(base, 0)]
            var paths: [String] = []
            var visited = 0
            while let (directory, depth) = pending.popLast(), visited < 4096 {
                visited += 1
                paths += resolve(.sqlite(dir: directory, prefix: prefix, ext: ext), home: home)
                guard depth < max(0, min(maxDepth, 4)) else { continue }
                pending += childNames(of: directory).map { directory + "/" + $0 }
                    .filter { isDirectory($0) && isPhysical($0, home: home) }.map { ($0, depth + 1) }
            }
            return paths.sorted()
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
    /// 已卸载工具的残留走清理页；敏感数据与未公开结构的数据允许手动清理。
    static func deletablePaths(home: String, presence context: AgentPresenceContext? = nil) -> Set<String> {
        var result = Set<String>()
        for agent in definitions where isInstalled(agent, home: home, presence: context) {
            for target in resolve(agent, home: home, presence: context) {
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
                      home + "/.npm-global/bin", home + "/Library/pnpm",
                      home + "/.local/share/pnpm", home + "/.opencode/bin", home + "/.grok/bin",
                      home + "/.asdf/shims", home + "/.local/share/mise/shims"]
        let runtimeRoots = [
            home + "/.nvm/versions/node", home + "/.asdf/installs/nodejs",
            home + "/.local/share/mise/installs/node"
        ]
        let runtimeBins = runtimeRoots.flatMap { root in childNames(of: root).map { root + "/" + $0 + "/bin" } }
        let fnmRoots = [home + "/.local/share/fnm/node-versions", home + "/Library/Application Support/fnm/node-versions"]
        let fnmBins = fnmRoots.flatMap { root in childNames(of: root).map { root + "/" + $0 + "/installation/bin" } }
        var seen = Set<String>()
        return (environment + common + runtimeBins + fnmBins).filter { seen.insert($0).inserted }
    }

    static func resolveExecutable(_ command: String, searchPath: [String], home: String) -> String? {
        var candidate = command
        if candidate.hasPrefix("~/") { candidate = home + candidate.dropFirst(1) }
        if candidate.contains("/") {
            // 相对路径由宿主按插件或工作目录解析，这里无法判定缺失与否。
            guard candidate.hasPrefix("/") else { return candidate }
            return isExecutableCommandFile(candidate) ? candidate : nil
        }
        return searchPath.map { $0 + "/" + command }
            .first(where: isExecutableCommandFile)
    }

    /// 目录的 x 权限表示可遍历，不能当成已安装命令；启动链接须指向普通可执行文件。
    static func isExecutableCommandFile(_ path: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: path) else { return false }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        var metadata = stat()
        return lstat(resolved, &metadata) == 0 && (metadata.st_mode & S_IFMT) == S_IFREG
    }

    // MARK: - Skills

    struct SkillDirectory: Sendable {
        let path: String
        let agentNames: [String]
        let ownerNames: [String]
        let globallyManaged: Bool
    }

    /// 同一目录可能被多个 Agent 共享（~/.agents/skills 等），合并展示使用者。
    static func skillDirectories(home: String) -> [SkillDirectory] {
        var order: [String] = []
        var users: [String: [String]] = [:]
        var owners: [String: [String]] = [:]
        var global = Set<String>()
        for agent in definitions {
            for relative in agent.skillDirectories + agent.implicitSkillDirectories {
                let path = absolute(relative, home: home)
                guard isPhysical(path, home: home) else { continue }
                if users[path] == nil {
                    order.append(path)
                    users[path] = []
                }
                if agent.id != "shared" { users[path]?.append(agent.name) }
                if agent.skillDirectories.contains(relative) {
                    if agent.id == "shared" { global.insert(path) }
                    else { owners[path, default: []].append(agent.name) }
                }
            }
        }
        return order.map { SkillDirectory(path: $0, agentNames: users[$0] ?? [],
            ownerNames: owners[$0] ?? [], globallyManaged: global.contains($0)) }
    }

    /// Skill 本体只接受已知 skills 目录的直接子目录；符号链接由解除关联流程处理。
    static func isDeletableSkill(_ path: String, home: String) -> Bool {
        let parent = (path as NSString).deletingLastPathComponent
        return skillDirectories(home: home).contains { $0.path == parent }
            && isPhysical(path, home: home) && isDirectory(path)
    }

    // MARK: - 文件系统

    /// 扫描、注册读取和执行复核共用同一个路径解析器。GUI 只能读取自身可见的环境。
    /// 注入 home 的测试不继承本机 Agent 环境；环境重定向的测试可显式传入字典。
    static func absolute(_ relative: String, home: String,
                         environment: [String: String]? = nil) -> String {
        if (relative as NSString).isAbsolutePath {
            return URL(fileURLWithPath: relative).standardizedFileURL.path
        }
        let environment = environment ?? storageEnvironment(home: home)
        // 旧 Kimi 的 plans 源码使用真实 home，不随 KIMI_SHARE_DIR 迁移。
        if relative == ".kimi/plans" || relative.hasPrefix(".kimi/plans/") {
            return URL(fileURLWithPath: home).appendingPathComponent(relative).standardizedFileURL.path
        }
        if relative == ".codex/db-backups" || relative.hasPrefix(".codex/db-backups/") {
            return URL(fileURLWithPath: codexSQLiteDirectory(home: home, environment: environment))
                .appendingPathComponent(String(relative.dropFirst(".codex/".count))).standardizedFileURL.path
        }
        if relative == ".codex/log" || relative.hasPrefix(".codex/log/"),
           let root = codexConfiguredDirectory("log_dir", home: home, environment: environment) {
            return URL(fileURLWithPath: root)
                .appendingPathComponent(String(relative.dropFirst(".codex/log".count)))
                .standardizedFileURL.path
        }
        let overrides: [(prefix: String, key: String, suffix: String)] = [
            (".codex", "CODEX_HOME", ""),
            (".claude", "CLAUDE_CONFIG_DIR", ""),
            (".gemini", "GEMINI_CLI_HOME", ".gemini"),
            (".cache/.gemini", "GEMINI_CLI_HOME", ".cache/.gemini"),
            (".pi/agent", "PI_CODING_AGENT_DIR", ""),
            (".kimi", "KIMI_SHARE_DIR", ""),
            (".kimi-code", "KIMI_CODE_HOME", ""),
            (".copilot", "COPILOT_HOME", ""),
            (".grok", "GROK_HOME", ""),
            (".amp", "AMP_HOME", ""),
            (".config/crush", "CRUSH_GLOBAL_CONFIG", ""),
            (".local/share/crush", "CRUSH_GLOBAL_DATA", ""),
            (".cache/crush", "CRUSH_CACHE_DIR", ""),
            (".config/crush", "XDG_CONFIG_HOME", "crush"),
            (".local/share/crush", "XDG_DATA_HOME", "crush"),
            (".cache/crush", "XDG_CACHE_HOME", "crush"),
            (".config/devin", "XDG_CONFIG_HOME", "devin"),
            (".local/share/opencode", "XDG_DATA_HOME", "opencode"),
            (".local/state/opencode", "XDG_STATE_HOME", "opencode"),
            (".cache/opencode", "XDG_CACHE_HOME", "opencode"),
            (".config/opencode", "XDG_CONFIG_HOME", "opencode")
        ]
        for entry in overrides where relative == entry.prefix || relative.hasPrefix(entry.prefix + "/") {
            guard let raw = environment[entry.key], let root = explicitDirectory(raw, home: home) else { continue }
            return URL(fileURLWithPath: root).appendingPathComponent(entry.suffix)
                .appendingPathComponent(String(relative.dropFirst(entry.prefix.count)))
                .standardizedFileURL.path
        }
        return URL(fileURLWithPath: home).appendingPathComponent(relative).standardizedFileURL.path
    }

    static func storageEnvironment(home: String) -> [String: String] {
        home == NSHomeDirectory() ? ProcessInfo.processInfo.environment : [:]
    }

    static func codexSQLiteDirectory(home: String, environment: [String: String]? = nil) -> String {
        let environment = environment ?? storageEnvironment(home: home)
        if let configured = codexConfiguredDirectory("sqlite_home", home: home, environment: environment) {
            return configured
        }
        if let raw = environment["CODEX_SQLITE_HOME"], let path = explicitDirectory(raw, home: home) {
            return path
        }
        return absolute(".codex", home: home, environment: environment)
    }

    private static func explicitDirectory(_ raw: String, home: String) -> String? {
        let raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = raw.hasPrefix("~/") ? home + raw.dropFirst() : raw
        guard (path as NSString).isAbsolutePath, !path.contains("\0") else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// 只读顶层 TOML 字符串，不解释 shell、profiles、项目配置或运行时覆盖。
    private static func codexConfiguredDirectory(_ key: String, home: String,
                                                 environment: [String: String]) -> String? {
        let config = absolute(".codex/config.toml", home: home, environment: environment)
        guard isPhysical(config, home: home), let handle = FileHandle(forReadingAtPath: config) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 1_048_576),
              let text = String(data: data, encoding: .utf8) else { return nil }
        // 此轻量只读解析器不处理 TOML 多行字符串，遇到它们不推断自定义目录。
        guard !text.contains("\"\"\""), !text.contains("'''") else { return nil }
        var result: String?
        for raw in text.components(separatedBy: .newlines) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { break }
            guard let equals = trimmed.firstIndex(of: "="),
                  trimmed[..<equals].trimmingCharacters(in: .whitespaces) == key else { continue }
            var value = ""
            var quote: Character?
            var escaped = false
            for character in trimmed[trimmed.index(after: equals)...] {
                if escaped { value.append(character); escaped = false; continue }
                if quote == "\"", character == "\\" { value.append(character); escaped = true; continue }
                if character == quote { quote = nil }
                else if quote == nil, character == "\"" || character == "'" { quote = character }
                else if quote == nil, character == "#" { break }
                value.append(character)
            }
            value = value.trimmingCharacters(in: .whitespaces)
            let decoded: String?
            if value.hasPrefix("\""), let data = ("[" + value + "]").data(using: .utf8) {
                decoded = ((try? JSONSerialization.jsonObject(with: data)) as? [String])?.first
            } else if value.count >= 2, value.first == "'", value.last == "'" {
                decoded = String(value.dropFirst().dropLast())
            } else { decoded = nil }
            if let decoded { result = explicitDirectory(decoded, home: home) }
        }
        return result
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
