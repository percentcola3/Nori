import Foundation

/// Agent 专清页文案。英文与中文完整覆盖；其余语言提供导航与主要动作，
/// 细项回退英文。
enum L10nAgentsTables {
    static let en: [String: String] = [
        "agents.cli.uninstallClean": "Uninstall & clean",
        "agents.cli.cleanNotice": "Uninstall every detected CLI installation for this agent, then permanently delete its listed data, including history, state and credentials. Shared skill sources and shared MCP installations are kept. If uninstalling fails, data cleanup stops. Running or changed data is skipped.",
        "agents.expanded": "Expanded",
        "agents.collapsed": "Collapsed",
        "agents.cli.notice": "Managed packages are uninstalled by their package manager. Native files move to Trash; launcher links are removed. Agent data remains for a separate cleanup.",
        "agents.cli.confirmLink": "Unlink the command for %@. Its source installation remains; only this launcher link is removed.",
        "agents.cli.unlink": "Unlink command",
        "agents.sharedSkills": "Global skills",
        "agents.sharedMCP": "MCP installations",
        "agents.section.installed": "Installed agents",
        "agents.section.skills": "Global skills",
        "agents.section.mcp": "MCP installations",
        "agents.notice.installed": "Uninstalled agent data appears in Cleanup. History and credentials require explicit selection; running agents must be closed before cleaning.",
        "agents.notice.skills": "Links only disconnect a skill. Deleting a global skill also removes its agent links.",
        "agents.notice.mcp": "Local MCP installations are separate from registrations. Deleting an installation also removes its known registrations. Remote and on-demand services have registrations only.",
        "agents.status.emptySection": "No items in this section.",
        "agents.status.uninstalling": "Uninstalling %@…",
        "agents.badge.review": "Needs review",
        "agents.risk.high": "High risk",
        "agents.skills.unlink": "Unlink",
        "agents.skills.deleteBody": "Delete skill",
        "agents.resource.usedBy": "Used by: %@",
        "agents.mcp.unlink": "Unregister",
        "agents.mcp.deleteConfig": "Delete config",
        "agents.mcp.deleteBody": "Delete installation",
        "agents.mcp.bodyImpact": "All known agent registrations will also be removed. Config files are backed up before editing.",
        "agents.mcp.registrationOnly": "Remote and on-demand registrations",
        "agents.cli.installation": "CLI installation",
        "agents.cli.uninstall": "Uninstall CLI",
        "agents.cli.confirm": "Uninstall %@ using its detected installation method, then clean the data listed below.",
        "agents.confirm.title": "Review cleanup actions",
        "agents.confirm.message": "File cleanup permanently deletes the selected content and may lose history, state or credentials. Skill links only disconnect their sources; MCP unregistering edits a backed-up config. Running or changed items will be skipped.",
        "agents.confirm.proceed": "Confirm and proceed",
        "agents.confirm.unlinkSkill": "Unlink skill: %@ (keep its source)",
        "agents.confirm.deleteSkill": "Delete skill: %@ (remove its known links too)",
        "agents.confirm.unlinkMCP": "Unregister MCP: %@ from %@",
        "agents.confirm.deleteConfig": "Delete unreadable config: %@ for %@ (backup first; resets the whole file)",
        "agents.confirm.deleteMCP": "Delete MCP installation: %@ (remove all known registrations too)",
        "agents.label.credentials": "Credentials",
        "agents.label.configuration": "Configuration",
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
        "agents.mcp.issue.unreadable": "Configuration could not be parsed. Selecting this item deletes the whole file after backing it up.",
        "agents.selectSafe": "Select safe",
        "agents.apply": "Delete",
        "agents.apply.withCount": "Delete %ld items · %@",
        "agents.reason.rebuildable": "Rebuildable cache. Skipped while the app is running.",
        "agents.reason.oldVersion": "Old version not used by any launcher link; the active and newest versions are kept.",
        "agents.reason.review": "History or session data. The tool keeps working without it; your choice.",
        "agents.reason.showOnly": "High risk: deleting state, conversations or credentials may reset the agent or lose login and history. Select manually.",
        "agents.reason.undocumented": "High risk: this folder has no confirmed purpose. Review its contents before deleting.",
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
        "agents.cli.uninstallClean": "卸载并清理",
        "agents.cli.cleanNotice": "卸载该 Agent 检测到的全部 CLI 安装，再永久删除下列数据，包含历史、状态和凭据。共享 Skill 本体和共享 MCP 安装保留。卸载失败则停止数据清理；运行中或身份已变化的数据会跳过。",
        "agents.expanded": "已展开",
        "agents.collapsed": "已收起",
        "agents.cli.notice": "包管理器安装的版本通过对应管理器卸载；原生本体移入废纸篓，启动链接会解除。Agent 数据会保留，另行清理。",
        "agents.cli.confirmLink": "解除 %@ 的命令链接。仅删除启动入口链接，保留链接指向的安装本体。",
        "agents.cli.unlink": "解除命令链接",
        "agents.sharedSkills": "全局 Skills",
        "agents.sharedMCP": "MCP 本体",
        "agents.section.installed": "已安装 Agent",
        "agents.section.skills": "全局 Skills",
        "agents.section.mcp": "MCP 本体",
        "agents.notice.installed": "已卸载 Agent 的残留在「清理」页处理。历史和凭据需手动选择；清理前请退出相关 Agent。",
        "agents.notice.skills": "勾选链接只解除关联；删除全局 Skill 本体会自动清理各 Agent 对它的链接。",
        "agents.notice.mcp": "本地 MCP 本体与 Agent 注册分开管理。删除本体会自动清理已发现的注册；远程和按需启动的服务管理配置关联。",
        "agents.status.emptySection": "这一分区没有发现项目。",
        "agents.status.uninstalling": "正在卸载 %@…",
        "agents.badge.review": "需核对用途",
        "agents.risk.high": "高风险",
        "agents.skills.unlink": "解除关联",
        "agents.skills.deleteBody": "删除本体",
        "agents.resource.usedBy": "关联 Agent：%@",
        "agents.mcp.unlink": "解除注册",
        "agents.mcp.deleteConfig": "删除整份配置",
        "agents.mcp.deleteBody": "删除本体",
        "agents.mcp.bodyImpact": "同时移除所有已发现的 Agent 注册；修改配置前自动生成备份。",
        "agents.mcp.registrationOnly": "远程与按需启动的 MCP 关联",
        "agents.cli.installation": "CLI 安装",
        "agents.cli.uninstall": "卸载 CLI",
        "agents.cli.confirm": "按照检测到的安装方式卸载 %@，随后清理下列数据。",
        "agents.confirm.title": "确认清理动作与影响",
        "agents.confirm.message": "文件清理会永久删除所选内容，可能丢失历史、状态或登录凭据。Skill 链接仅解除关联；MCP 解除注册会先备份再修改配置。正在使用或扫描后变化的项目会跳过。",
        "agents.confirm.proceed": "确认执行",
        "agents.confirm.unlinkSkill": "解除 Skill 关联：%@（保留本体）",
        "agents.confirm.deleteSkill": "删除 Skill 本体：%@（同步清理已发现的关联链接）",
        "agents.confirm.unlinkMCP": "解除 MCP 注册：%@ · %@",
        "agents.confirm.deleteConfig": "删除无法解析的配置：%@ · %@（先备份；会重置整份配置）",
        "agents.confirm.deleteMCP": "删除 MCP 本体：%@（同步移除所有已发现的注册）",
        "agents.label.credentials": "登录凭据",
        "agents.label.configuration": "配置文件",
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
        "agents.mcp.issue.unreadable": "配置文件无法解析；勾选后会先备份，再删除整份配置。",
        "agents.selectSafe": "勾选安全项",
        "agents.apply": "删除",
        "agents.apply.withCount": "删除 %ld 项 · %@",
        "agents.reason.rebuildable": "可再生缓存；应用运行时跳过。",
        "agents.reason.oldVersion": "没有被任何启动链接使用的旧版本；当前版本和最新版本会保留。",
        "agents.reason.review": "历史或会话数据：删除后工具照常可用，由你决定。",
        "agents.reason.showOnly": "高风险：删除状态、对话或凭据可能重置 Agent、丢失历史或需要重新登录。请手动选择。",
        "agents.reason.undocumented": "高风险：该目录的用途未确认，删除前请检查内容。",
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
        "agents.reason.showOnly": "高風險：刪除狀態、對話或憑證可能重置 Agent、丟失歷史或需要重新登入。請手動選擇。",
        "agents.reason.undocumented": "高風險：該目錄的用途未確認，刪除前請檢查內容。",
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
