import Foundation

/// Agent 专清页文案。英文与中文完整覆盖；其余语言提供导航与主要动作，
/// 细项回退英文。
enum L10nAgentsTables {
    static let en: [String: String] = [
        "tab.agents": "Agents",
        "agents.title": "AI Agent Cleanup",
        "agents.subtitle": "Caches, old versions and history left by coding agents. Selected items are deleted permanently.",
        "agents.scan": "Scan agents",
        "agents.rescan": "Rescan",
        "agents.empty.hint": "Finds space used by Claude Code, Codex, Cursor, Copilot, Gemini, Grok, opencode and other agents, and checks their skills and MCP servers. Nothing is removed until you confirm.",
        "agents.status.scanning": "Scanning agent directories…",
        "agents.status.empty": "No agent data found.",
        "agents.status.done": "%ld agents · %@ in total",
        "agents.status.partial": "Some folders were too large to measure fully",
        "agents.badge.showOnly": "Size only",
        "agents.badge.leftover": "Uninstalled · leftover",
        "agents.group.reclaimable": "Reclaimable %@",
        "agents.group.shared": "Shared skills",
        "agents.subsection.skills": "Skills",
        "agents.subsection.mcp": "MCP servers",
        "agents.skills.linked": "Link",
        "agents.mcp.editable": "Selected skills are deleted permanently; selected MCP servers are removed from their config files (a backup is written next to the original).",
        "agents.mcp.disabled": "Disabled",
        "agents.mcp.issue.command": "Command not found: %@",
        "agents.mcp.issue.secret": "Plaintext secret in %@ (%@). Prefer an environment variable.",
        "agents.mcp.issue.unreadable": "Configuration file could not be parsed.",
        "agents.selectSafe": "Select safe",
        "agents.apply": "Delete",
        "agents.apply.withCount": "Delete %ld items · %@",
        "agents.reason.rebuildable": "Rebuildable cache. Skipped while the app is running.",
        "agents.reason.oldVersion": "Old version not used by any launcher link; the active and newest versions are kept.",
        "agents.reason.review": "History or session data. The tool keeps working without it; your choice.",
        "agents.reason.showOnly": "Active state, conversations or credentials. Shown for size only.",
        "agents.reason.undocumented": "No official documentation for this folder. Shown for size only.",
        "agents.reason.skill": "Installed skill",
        "agents.label.oldVersions": "Old versions",
        "agents.label.embeddedAgentVersions": "Old built-in agent versions",
        "agents.label.cache": "Cache",
        "agents.label.appCache": "App cache",
        "agents.label.logs": "Logs",
        "agents.label.transcripts": "Conversation transcripts",
        "agents.label.fileHistory": "File edit history",
        "agents.label.shellSnapshots": "Shell snapshots",
        "agents.label.todos": "Task lists",
        "agents.label.pasteCache": "Paste cache",
        "agents.label.history": "Prompt history",
        "agents.label.vmBundles": "VM bundles",
        "agents.label.updateStaging": "Update downloads",
        "agents.label.logDatabase": "Log database",
        "agents.label.tempFiles": "Temporary files",
        "agents.label.generatedImages": "Generated images",
        "agents.label.archivedSessions": "Archived sessions",
        "agents.label.sessions": "Sessions",
        "agents.label.stateDatabase": "State database",
        "agents.label.historyDatabase": "History database",
        "agents.label.compileCache": "Compile cache",
        "agents.label.checkpoints": "Checkpoints",
        "agents.label.workspaceState": "Workspace state",
        "agents.label.browserRecordings": "Browser recordings",
        "agents.label.conversations": "Conversations",
        "agents.label.knowledge": "Knowledge and artifacts",
        "agents.label.conversationDatabase": "Conversation database",
        "agents.label.worktrees": "Worktrees",
        "agents.label.plans": "Plans",
        "agents.label.appData": "App data"
    ]

    static let zhHans: [String: String] = [
        "tab.agents": "Agent",
        "agents.title": "AI Agent 专清",
        "agents.subtitle": "编程 Agent 留下的缓存、旧版本和历史记录，勾选后直接永久删除。",
        "agents.scan": "扫描 Agent",
        "agents.rescan": "重新扫描",
        "agents.empty.hint": "找出 Claude Code、Codex、Cursor、Copilot、Gemini、Grok、opencode 等 Agent 占用的空间，并检查它们的 Skills 和 MCP 服务。确认之前不会删除任何内容。",
        "agents.status.scanning": "正在扫描 Agent 目录…",
        "agents.status.empty": "没有发现 Agent 数据。",
        "agents.status.done": "%ld 个 Agent · 共 %@",
        "agents.status.partial": "部分目录过大，未能完整计量",
        "agents.badge.showOnly": "仅显示",
        "agents.badge.leftover": "已卸载 · 残留",
        "agents.group.reclaimable": "可清理 %@",
        "agents.group.shared": "共享 Skills",
        "agents.subsection.skills": "Skills",
        "agents.subsection.mcp": "MCP 服务",
        "agents.skills.linked": "链接",
        "agents.mcp.editable": "勾选的 Skill 将被直接永久删除；勾选的 MCP 服务会从配置文件中移除，修改前会在原文件旁生成备份。",
        "agents.mcp.disabled": "已停用",
        "agents.mcp.issue.command": "找不到命令：%@",
        "agents.mcp.issue.secret": "%@ 中有明文密钥（%@），建议改用环境变量。",
        "agents.mcp.issue.unreadable": "配置文件无法解析。",
        "agents.selectSafe": "勾选安全项",
        "agents.apply": "删除",
        "agents.apply.withCount": "删除 %ld 项 · %@",
        "agents.reason.rebuildable": "可再生缓存；应用运行时跳过。",
        "agents.reason.oldVersion": "没有被任何启动链接使用的旧版本；当前版本和最新版本会保留。",
        "agents.reason.review": "历史或会话数据：删除后工具照常可用，由你决定。",
        "agents.reason.showOnly": "活跃状态、对话记录或凭据，只显示占用。",
        "agents.reason.undocumented": "该目录没有官方说明，只显示占用。",
        "agents.reason.skill": "已安装的 Skill",
        "agents.label.oldVersions": "旧版本",
        "agents.label.embeddedAgentVersions": "内置 Agent 旧版本",
        "agents.label.cache": "缓存",
        "agents.label.appCache": "应用缓存",
        "agents.label.logs": "日志",
        "agents.label.transcripts": "对话记录",
        "agents.label.fileHistory": "文件修改历史",
        "agents.label.shellSnapshots": "Shell 快照",
        "agents.label.todos": "任务清单",
        "agents.label.pasteCache": "粘贴缓存",
        "agents.label.history": "输入历史",
        "agents.label.vmBundles": "虚拟机镜像",
        "agents.label.updateStaging": "更新下载",
        "agents.label.logDatabase": "日志数据库",
        "agents.label.tempFiles": "临时文件",
        "agents.label.generatedImages": "生成的图片",
        "agents.label.archivedSessions": "已归档会话",
        "agents.label.sessions": "会话",
        "agents.label.stateDatabase": "状态数据库",
        "agents.label.historyDatabase": "历史数据库",
        "agents.label.compileCache": "编译缓存",
        "agents.label.checkpoints": "检查点",
        "agents.label.workspaceState": "工作区状态",
        "agents.label.browserRecordings": "浏览器录屏",
        "agents.label.conversations": "对话",
        "agents.label.knowledge": "知识与产物",
        "agents.label.conversationDatabase": "对话数据库",
        "agents.label.worktrees": "工作树",
        "agents.label.plans": "计划",
        "agents.label.appData": "应用数据"
    ]

    static let zhHant: [String: String] = [
        "tab.agents": "Agent",
        "agents.title": "AI Agent 專清",
        "agents.subtitle": "程式 Agent 留下的快取、舊版本和歷史紀錄，勾選後直接永久刪除。",
        "agents.scan": "掃描 Agent",
        "agents.rescan": "重新掃描",
        "agents.empty.hint": "找出 Claude Code、Codex、Cursor、Copilot、Gemini、Grok、opencode 等 Agent 佔用的空間，並檢查它們的 Skills 和 MCP 服務。確認之前不會刪除任何內容。",
        "agents.status.scanning": "正在掃描 Agent 目錄…",
        "agents.status.empty": "沒有發現 Agent 資料。",
        "agents.status.done": "%ld 個 Agent · 共 %@",
        "agents.status.partial": "部分目錄過大，未能完整計量",
        "agents.badge.showOnly": "僅顯示",
        "agents.badge.leftover": "已解除安裝 · 殘留",
        "agents.group.reclaimable": "可清理 %@",
        "agents.group.shared": "共享 Skills",
        "agents.subsection.skills": "Skills",
        "agents.subsection.mcp": "MCP 服務",
        "agents.skills.linked": "連結",
        "agents.mcp.editable": "勾選的 Skill 將被直接永久刪除；勾選的 MCP 服務會從設定檔中移除，修改前會在原檔旁產生備份。",
        "agents.mcp.disabled": "已停用",
        "agents.mcp.issue.command": "找不到指令：%@",
        "agents.mcp.issue.secret": "%@ 中有明文金鑰（%@），建議改用環境變數。",
        "agents.mcp.issue.unreadable": "設定檔無法解析。",
        "agents.selectSafe": "勾選安全項",
        "agents.apply": "刪除",
        "agents.apply.withCount": "刪除 %ld 項 · %@",
        "agents.reason.rebuildable": "可再生快取；應用程式執行時略過。",
        "agents.reason.oldVersion": "沒有被任何啟動連結使用的舊版本；目前版本和最新版本會保留。",
        "agents.reason.review": "歷史或工作階段資料：刪除後工具照常可用，由你決定。",
        "agents.reason.showOnly": "活躍狀態、對話紀錄或憑證，只顯示佔用。",
        "agents.reason.undocumented": "該目錄沒有官方說明，只顯示佔用。",
        "agents.label.oldVersions": "舊版本",
        "agents.label.cache": "快取",
        "agents.label.appCache": "應用程式快取",
        "agents.label.logs": "日誌",
        "agents.label.sessions": "工作階段",
        "agents.label.transcripts": "對話紀錄",
        "agents.label.appData": "應用程式資料"
    ]

    static let ja: [String: String] = [
        "tab.agents": "Agent",
        "agents.title": "AI エージェントのクリーンアップ",
        "agents.scan": "エージェントをスキャン",
        "agents.rescan": "再スキャン",
        "agents.selectSafe": "安全な項目を選択",
        "agents.apply": "削除"
    ]

    static let ko: [String: String] = [
        "tab.agents": "Agent",
        "agents.title": "AI 에이전트 정리",
        "agents.scan": "에이전트 스캔",
        "agents.rescan": "다시 스캔",
        "agents.selectSafe": "안전 항목 선택",
        "agents.apply": "삭제"
    ]

    static let de: [String: String] = [
        "tab.agents": "Agenten",
        "agents.title": "KI-Agenten bereinigen",
        "agents.scan": "Agenten scannen",
        "agents.rescan": "Erneut scannen",
        "agents.selectSafe": "Sichere auswählen",
        "agents.apply": "Löschen"
    ]

    static let fr: [String: String] = [
        "tab.agents": "Agents",
        "agents.title": "Nettoyage des agents IA",
        "agents.scan": "Analyser les agents",
        "agents.rescan": "Relancer",
        "agents.selectSafe": "Sélection sûre",
        "agents.apply": "Supprimer"
    ]

    static let es: [String: String] = [
        "tab.agents": "Agentes",
        "agents.title": "Limpieza de agentes IA",
        "agents.scan": "Analizar agentes",
        "agents.rescan": "Volver a analizar",
        "agents.selectSafe": "Seleccionar seguros",
        "agents.apply": "Eliminar"
    ]

    static let pt: [String: String] = [
        "tab.agents": "Agentes",
        "agents.title": "Limpeza de agentes de IA",
        "agents.scan": "Analisar agentes",
        "agents.rescan": "Analisar de novo",
        "agents.selectSafe": "Selecionar seguros",
        "agents.apply": "Apagar"
    ]

    static let it: [String: String] = [
        "tab.agents": "Agenti",
        "agents.title": "Pulizia agenti IA",
        "agents.scan": "Analizza agenti",
        "agents.rescan": "Rianalizza",
        "agents.selectSafe": "Seleziona sicuri",
        "agents.apply": "Elimina"
    ]

    static let ru: [String: String] = [
        "tab.agents": "Агенты",
        "agents.title": "Очистка ИИ-агентов",
        "agents.scan": "Сканировать агентов",
        "agents.rescan": "Пересканировать",
        "agents.selectSafe": "Выбрать безопасные",
        "agents.apply": "Удалить"
    ]

    static let tr: [String: String] = [
        "tab.agents": "Ajanlar",
        "agents.title": "Yapay zekâ ajanı temizliği",
        "agents.scan": "Ajanları tara",
        "agents.rescan": "Yeniden tara",
        "agents.selectSafe": "Güvenlileri seç",
        "agents.apply": "Sil"
    ]

    static func table(for language: AppLanguage) -> [String: String] {
        switch language {
        case .zhHans: return zhHans
        case .zhHant: return zhHant
        case .en: return en
        case .ja: return ja
        case .ko: return ko
        case .de: return de
        case .fr: return fr
        case .es: return es
        case .pt: return pt
        case .it: return it
        case .ru: return ru
        case .tr: return tr
        case .auto: return [:]
        }
    }
}
