import Foundation

/// Agent 专清：扫描、选择与执行。执行统一走 NativeCore 的删除漏斗并移入废纸篓；
/// 执行前用新进程快照复核归属者、用目录重新解析复核候选（旧版本判定随之刷新）。
@MainActor
extension AppState {
    var agentSelectedCount: Int {
        agentCategories.reduce(0) { $0 + $1.selectedPathCount }
            + agentSelectedSkills.count + agentSelectedServers.count
    }

    var agentSelectedBytes: UInt64 {
        let skills = agentSkills.filter { agentSelectedSkills.contains($0.path) }
            .reduce(UInt64(0)) { $0 &+ $1.bytes }
        return agentCategories.reduce(skills) { $0 &+ $1.selectedPathBytes }
    }

    func scanAgents(completionStatus: String? = nil) {
        guard !isBusy else { return }
        agentScanning = true
        agentScanComplete = false
        agentOutcomeMood = nil
        agentStatus = L10n.shared.t("agents.status.scanning")
        Task {
            let home = NSHomeDirectory()
            let report = await Task.detached(priority: .utility) {
                AgentInventory.scan(home: home, localize: { L10n.shared.t($0) })
            }.value
            agentCategories = report.categories
            agentGroups = report.groups
            agentSkills = report.skills
            agentServers = report.servers
            agentSelectedSkills = []
            agentSelectedServers = []
            agentScanning = false
            agentHasScanned = true
            agentScanComplete = report.complete
            if completionStatus == nil {
                noteHeaderReaction(report.complete ? .success : .attention)
            }
            if !report.complete {
                // 计量被预算截断时不预选任何项，避免按不完整的占用做决定。
                for index in agentCategories.indices { agentCategories[index].selected = false }
            }
            let total = report.categories.reduce(UInt64(0)) { $0 &+ $1.bytes }
            agentStatus = completionStatus ?? (report.groups.isEmpty
                ? L10n.shared.t("agents.status.empty")
                : L10n.shared.tf("agents.status.done", report.groups.count, ByteFormat.format(total)))
        }
    }

    func selectSafeAgentItems() {
        guard !isBusy else { return }
        for index in agentCategories.indices {
            agentCategories[index].selected = agentCategories[index].risk == .safe
        }
        agentSelectedSkills = []
        agentSelectedServers = []
    }

    func clearAgentSelection() {
        for index in agentCategories.indices { agentCategories[index].selected = false }
        agentSelectedSkills = []
        agentSelectedServers = []
    }

    func toggleAgentSkill(_ skill: AgentSkill) {
        guard !isBusy, !skill.linked, !skill.identity.isEmpty else { return }
        if agentSelectedSkills.contains(skill.path) {
            agentSelectedSkills.remove(skill.path)
        } else {
            agentSelectedSkills.insert(skill.path)
        }
    }

    /// 配置不可读的服务器无法安全改写，保持不可勾选。
    func toggleAgentServer(_ server: AgentMCPServer) {
        guard !isBusy, !server.issues.contains(.unreadableConfig) else { return }
        if agentSelectedServers.contains(server.id) {
            agentSelectedServers.remove(server.id)
        } else {
            agentSelectedServers.insert(server.id)
        }
    }

    func applyAgentCleanup() {
        guard !isBusy, agentHasScanned else { return }
        var selected = agentCategories.compactMap(\.selectedSubset)
        let skills = agentSkills.filter { agentSelectedSkills.contains($0.path) && !$0.linked }
        if !skills.isEmpty {
            var category = CleanupCategory(
                name: "Skills", paths: skills.map(\.path),
                bytes: skills.reduce(0) { $0 &+ $1.bytes },
                pathBytes: Dictionary(uniqueKeysWithValues: skills.map { ($0.path, $0.bytes) }),
                pathIdentities: Dictionary(uniqueKeysWithValues: skills.map { ($0.path, $0.identity) }),
                selected: true, source: .aiSession, risk: .warning, disposal: .permanentDelete,
                applyRoute: .aiTrash, activityGuard: .aiAgent, reasonKey: "agents.reason.skill")
            category.activityOwners = []
            selected.append(category)
        }
        let serverRequests = agentServers
            .filter { agentSelectedServers.contains($0.id) }
            .map { AgentMCPConfigEditor.Request(configPath: $0.configPath, format: $0.format,
                                                serverName: $0.name, scope: $0.scope) }
        let count = selected.reduce(0) { $0 + $1.paths.count } + serverRequests.count
        guard count > 0 else {
            agentStatus = L10n.shared.t("cleanup.selectNone")
            return
        }
        performAgentApply(selected, mcpRequests: serverRequests)
    }

    private func performAgentApply(_ requested: [CleanupCategory],
                                   mcpRequests: [AgentMCPConfigEditor.Request]) {
        guard !isBusy else { return }
        agentApplying = true
        agentStatus = L10n.shared.tf("status.processing",
                                     requested.reduce(0) { $0 + $1.paths.count } + mcpRequests.count)
        Task {
            let snapshot = await captureRunningApplicationSnapshot()
            let home = NSHomeDirectory()
            let outcome = await Task.detached(priority: .utility) {
                AgentCleanupExecutor.execute(requested, running: snapshot, home: home, permanent: true)
            }.value
            // 文件删除完成后才改写 MCP 配置；编辑器自带备份与执行时复核。
            let mcp = mcpRequests.isEmpty
                ? AgentMCPConfigEditor.Outcome()
                : await Task.detached(priority: .utility) { AgentMCPConfigEditor.apply(mcpRequests) }.value
            var messages = outcome.summary.messages
            messages.append(contentsOf: mcp.messages)
            if !messages.isEmpty {
                log(messages.joined(separator: "\n"))
            }
            agentApplying = false
            let removed = outcome.summary.removed + mcp.removed
            let skipped = outcome.summary.skipped + outcome.refused + mcp.missing
            let failed = outcome.summary.failed + mcp.failed
            agentOutcomeMood = NoriCleanupFeedback.mood(removed: removed, skipped: skipped, failed: failed)
            noteHeaderReaction(NoriHeaderReaction.mood(removed: removed, skipped: skipped, failed: failed))
            let summary = L10n.shared.tf("cleanup.execution.summary", removed, skipped, failed)
            log(summary)
            scanAgents(completionStatus: summary)
        }
    }
}
