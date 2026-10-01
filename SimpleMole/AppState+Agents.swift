import Foundation

/// 确认时冻结父节点的安装和数据范围，执行时仍重新核对身份与运行状态。
struct AgentRemovalPlan {
    let agentID: String
    let name: String
    let installations: [AgentCLIInstallation]
    let categories: [CleanupCategory]
    let skills: [AgentSkill]
    let servers: [AgentMCPServer]

    var details: [String] {
        installations.map {
            L10n.shared.tf($0.onlyUnlinksExecutable ? "agents.cli.confirmLink" : "agents.cli.confirm", name)
                + "\n" + $0.detail + "\n" + $0.executablePaths.joined(separator: "\n")
        } + categories.map {
            $0.name + " · " + ByteFormat.format($0.bytes) + "\n"
                + L10n.shared.t($0.reasonKey) + "\n" + $0.paths.joined(separator: "\n")
        } + skills.map {
            L10n.shared.tf($0.linked ? "agents.confirm.unlinkSkill" : "agents.confirm.deleteSkill", $0.name)
                + "\n" + $0.path
        } + servers.map {
            L10n.shared.tf($0.issues.contains(.unreadableConfig)
                ? "agents.confirm.deleteConfig" : "agents.confirm.unlinkMCP", $0.name, $0.agentName)
                + "\n" + $0.configPath
        }
    }
}

/// Agent 专清独立于快速清理；用户数据、全局资源和卸载动作均由用户明确选择。
@MainActor
extension AppState {
    var agentSelectedCount: Int {
        agentCategories.reduce(0) { $0 + $1.selectedPathCount }
            + agentSelectedSkills.count + agentSelectedServers.count
            + agentSelectedMCPInstallations.count
    }

    var agentSelectedBytes: UInt64 {
        let paths = agentCategories.flatMap { category in
            category.paths.filter(category.isPathSelected).map { ($0, category.pathBytes[$0] ?? 0) }
        } + agentSkills.filter { agentSelectedSkills.contains($0.path) }.map { ($0.path, $0.bytes) }
            + agentMCPInstallations.filter { agentSelectedMCPInstallations.contains($0.id) }.map { ($0.path, $0.bytes) }
        return Self.uniqueAgentBytes(paths)
    }

    nonisolated static func uniqueAgentBytes(_ entries: [(String, UInt64)]) -> UInt64 {
        let sizes = Dictionary(entries, uniquingKeysWith: max)
        return DeletionPlan.nonOverlappingPaths(Array(sizes.keys)).reduce(UInt64(0)) { $0 &+ (sizes[$1] ?? 0) }
    }

    func agentGroupBytes(_ group: AgentGroupSummary) -> UInt64 {
        let paths = agentCategories.filter { group.categoryIDs.contains($0.id) }.flatMap { category in
            category.paths.map { ($0, category.pathBytes[$0] ?? 0) }
        } + agentSkills.filter { $0.agentID == group.id }.map { ($0.path, $0.bytes) }
        return Self.uniqueAgentBytes(paths)
    }

    /// 确认弹窗列出具体动作和影响，避免把解除关联与删除本体混为一谈。
    var agentCleanupDetails: [String] {
        var details = agentCategories.compactMap(\.selectedSubset).map {
            "\($0.name) · \($0.paths.count) · \(ByteFormat.format($0.bytes))\n\(L10n.shared.t($0.reasonKey))"
        }
        details += agentSkills.filter { agentSelectedSkills.contains($0.path) }.map {
            L10n.shared.tf($0.linked ? "agents.confirm.unlinkSkill" : "agents.confirm.deleteSkill", $0.name)
        }
        details += agentServers.filter { agentSelectedServers.contains($0.id) }.map {
            L10n.shared.tf($0.issues.contains(.unreadableConfig)
                           ? "agents.confirm.deleteConfig" : "agents.confirm.unlinkMCP", $0.name, $0.agentName)
        }
        details += agentMCPInstallations.filter { agentSelectedMCPInstallations.contains($0.id) }.map {
            L10n.shared.tf("agents.confirm.deleteMCP", $0.name)
        }
        return details
    }

    func scanAgents(completionStatus: String? = nil) {
        guard !isBusy else { return }
        agentScanning = true
        agentScanComplete = false
        agentOutcomeMood = nil
        agentStatus = L10n.shared.t("agents.status.scanning")
        Task {
            let home = NSHomeDirectory()
            let (report, cli) = await Task.detached(priority: .utility) {
                var report = AgentInventory.scan(home: home, localize: { L10n.shared.t($0) })
                let cli = AgentCatalog.definitions.flatMap {
                    AgentCLIService.installations(for: $0, home: home)
                }
                for agent in AgentCatalog.definitions where cli.contains(where: { $0.agentID == agent.id }) {
                    if !report.groups.contains(where: { $0.id == agent.id }) {
                        report.groups.append(AgentGroupSummary(
                            id: agent.id, name: agent.name, documented: agent.documented,
                            orphaned: false, categoryIDs: [], skillIDs: [], serverIDs: [], bytes: 0))
                    }
                }
                return (report, cli)
            }.value
            agentCategories = report.categories
            agentGroups = report.groups
            agentSkills = report.skills
            agentServers = report.servers
            agentMCPInstallations = report.installations
            agentCLIInstallations = cli
            agentSelectedSkills = []
            agentSelectedServers = []
            agentSelectedMCPInstallations = []
            agentScanning = false
            agentHasScanned = true
            agentScanComplete = report.complete
            selectSafeAgentItems()
            if completionStatus == nil {
                noteHeaderReaction(report.complete ? .success : .attention)
            }
            if !report.complete {
                for index in agentCategories.indices { agentCategories[index].selected = false }
            }
            let total = Self.uniqueAgentBytes(report.categories.flatMap { category in
                category.paths.map { ($0, category.pathBytes[$0] ?? 0) }
            } + report.skills.map { ($0.path, $0.bytes) } + report.installations.map { ($0.path, $0.bytes) })
            let agentCount = report.groups.filter {
                $0.id != "shared" && $0.id != "shared-mcp" && $0.id != "chrome-devtools-mcp"
            }.count
            agentStatus = completionStatus ?? (report.groups.isEmpty
                ? L10n.shared.t("agents.status.empty")
                : L10n.shared.tf("agents.status.done", agentCount, ByteFormat.format(total)))
        }
    }

    func selectSafeAgentItems() {
        guard !isBusy else { return }
        for index in agentCategories.indices {
            agentCategories[index].selected = agentCategories[index].risk == .safe
        }
        agentSelectedSkills = []
        agentSelectedServers = []
        agentSelectedMCPInstallations = []
    }

    func clearAgentSelection() {
        for index in agentCategories.indices { agentCategories[index].selected = false }
        agentSelectedSkills = []
        agentSelectedServers = []
        agentSelectedMCPInstallations = []
    }

    func toggleAgentSkill(_ skill: AgentSkill) {
        guard !isBusy, !skill.identity.isEmpty else { return }
        if agentSelectedSkills.contains(skill.path) {
            agentSelectedSkills.remove(skill.path)
        } else {
            agentSelectedSkills.insert(skill.path)
        }
    }

    func toggleAgentServer(_ server: AgentMCPServer) {
        guard !isBusy else { return }
        if agentSelectedServers.contains(server.id) {
            agentSelectedServers.remove(server.id)
        } else {
            agentSelectedServers.insert(server.id)
        }
    }

    func toggleAgentMCPInstallation(_ installation: AgentMCPInstallation) {
        guard !isBusy, !installation.identity.isEmpty else { return }
        if agentSelectedMCPInstallations.contains(installation.id) {
            agentSelectedMCPInstallations.remove(installation.id)
        } else {
            agentSelectedMCPInstallations.insert(installation.id)
        }
    }

    func applyAgentCleanup() {
        guard !isBusy, agentHasScanned else { return }
        let selected = agentCategories.compactMap(\.selectedSubset)
        let skills = agentSkills.filter { agentSelectedSkills.contains($0.path) }
        let servers = agentServers.filter { agentSelectedServers.contains($0.id) }
        let installations = agentMCPInstallations.filter { agentSelectedMCPInstallations.contains($0.id) }
        guard agentSelectedCount > 0 else {
            agentStatus = L10n.shared.t("cleanup.selectNone")
            return
        }
        agentApplying = true
        agentStatus = L10n.shared.tf("status.processing", agentSelectedCount)
        Task {
            let snapshot = await captureRunningApplicationSnapshot()
            let home = NSHomeDirectory()
            let outcome = await Task.detached(priority: .utility) {
                AgentCleanupExecutor.execute(selected, running: snapshot, home: home, permanent: true,
                                             skills: skills, installations: installations, servers: servers)
            }.value
            finishAgentMutation(removed: outcome.summary.removed,
                                skipped: outcome.summary.skipped + outcome.refused,
                                failed: outcome.summary.failed, messages: outcome.summary.messages)
        }
    }

    func agentRemovalPlan(for group: AgentGroupSummary) -> AgentRemovalPlan {
        let categories = agentCategories.filter { group.categoryIDs.contains($0.id) }.map { category in
            var selected = category
            selected.selected = true
            return selected
        }
        return AgentRemovalPlan(agentID: group.id, name: group.name,
            installations: agentCLIInstallations.filter { $0.agentID == group.id },
            categories: categories,
            skills: agentSkills.filter { $0.agentID == group.id },
            servers: agentServers.filter { $0.agentID == group.id })
    }

    func uninstallAgentAndClean(_ plan: AgentRemovalPlan) {
        guard !isBusy, agentHasScanned, !plan.installations.isEmpty else { return }
        agentApplying = true
        agentStatus = L10n.shared.tf("agents.status.uninstalling", plan.name)
        Task {
            let snapshot = await captureRunningApplicationSnapshot()
            let home = NSHomeDirectory()
            let uninstall = await Task.detached(priority: .utility) {
                var removed = 0
                var failed = 0
                var messages: [String] = []
                for installation in plan.installations {
                    let outcome = AgentCLIService.uninstall(installation, home: home, running: snapshot)
                    removed += outcome.removed
                    failed += outcome.failed
                    messages += outcome.messages
                    if !outcome.succeeded { break }
                }
                return AgentCLIService.Outcome(removed: removed, failed: failed, messages: messages)
            }.value
            if uninstall.failed == 0 {
                // 包管理器可能耗时；开始数据清理前重新读取进程状态。
                let freshSnapshot = await captureRunningApplicationSnapshot()
                let cleanup = await Task.detached(priority: .utility) {
                    AgentCleanupExecutor.execute(plan.categories, running: freshSnapshot,
                        home: home, permanent: true, skills: plan.skills, servers: plan.servers,
                        removingAgentID: plan.agentID)
                }.value
                finishAgentMutation(removed: uninstall.removed + cleanup.summary.removed,
                    skipped: cleanup.summary.skipped + cleanup.refused,
                    failed: cleanup.summary.failed, messages: uninstall.messages + cleanup.summary.messages)
            } else {
                finishAgentMutation(removed: uninstall.removed, skipped: 0,
                    failed: uninstall.failed, messages: uninstall.messages)
            }
            CleanupCache.invalidate()
            cleanupScanComplete = false
        }
    }

    private func finishAgentMutation(removed: Int, skipped: Int, failed: Int, messages: [String]) {
        if !messages.isEmpty { log(messages.joined(separator: "\n")) }
        agentApplying = false
        agentOutcomeMood = NoriCleanupFeedback.mood(removed: removed, skipped: skipped, failed: failed)
        noteHeaderReaction(NoriHeaderReaction.mood(removed: removed, skipped: skipped, failed: failed))
        resampleAfterMutation()
        let summary = L10n.shared.tf("cleanup.execution.summary", removed, skipped, failed)
        log(summary)
        // 清理或卸载后丢弃过期清单，回到等待用户扫描的闲置状态。
        clearAgentSelection()
        agentCategories = []
        agentGroups = []
        agentSkills = []
        agentServers = []
        agentMCPInstallations = []
        agentCLIInstallations = []
        agentHasScanned = false
        agentScanComplete = false
        agentStatus = summary
    }
}
