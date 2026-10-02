import Foundation
import AppKit

/// Frozen user selection, including data implicitly selected by a CLI row.
/// Successful CLI removals retain their catalog scope for a data-only retry.
private struct AgentCleanupSelection {
    let categories: [CleanupCategory]
    let skills: [AgentSkill]
    let servers: [AgentMCPServer]
    let installations: [AgentMCPInstallation]
    var cliInstallations: [AgentCLIInstallation] = []
    var removedAgentIDs: Set<String> = []

    var count: Int {
        DeletionPlan.nonOverlappingPaths(categories.flatMap(\.paths)
            + skills.map(\.path) + installations.map(\.path)).count
            + Set(servers.map(\.id)).count + Set(cliInstallations.map(\.id)).count
    }

    var catalogAgentIDs: Set<String> {
        removedAgentIDs.union(cliInstallations.map(\.agentID))
    }

    func excludingCoveredPaths(_ removedPaths: Set<String>) -> Self {
        func covered(_ path: String) -> Bool {
            removedPaths.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
        return .init(categories: categories.compactMap {
            $0.selectingPaths($0.paths.filter { !covered($0) }).selectedSubset
        }, skills: skills.filter { !covered($0.path) },
        servers: servers.filter { !covered($0.configPath) },
        installations: installations.filter { !covered($0.path) },
        cliInstallations: cliInstallations, removedAgentIDs: removedAgentIDs)
    }

    func partitioned(by blocked: AgentCleanupExecutor.BlockingResources, waiting: Bool) -> Self {
        .init(categories: categories.compactMap { category in
            category.selectingPaths(category.paths.filter {
                category.isPathSelected($0) && blocked.paths.contains($0) == waiting
            }).selectedSubset
        }, skills: skills.filter { blocked.skillPaths.contains($0.path) == waiting },
        servers: servers.filter { blocked.serverIDs.contains($0.id) == waiting },
        installations: installations.filter { blocked.installationIDs.contains($0.id) == waiting },
        cliInstallations: cliInstallations, removedAgentIDs: removedAgentIDs)
    }

    /// A refreshed inventory proves presence only. It never grants a new
    /// identity to an accepted sensitive-file or CLI deletion plan.
    func retainingPresentResources(_ report: AgentScanReport) -> Self {
        let paths = Set(report.categories.flatMap(\.paths))
        let skillPaths = Set(report.skills.map(\.path))
        let serverIDs = Set(report.servers.map(\.id))
        let installationIDs = Set(report.installations.map(\.id))
        return .init(categories: categories.compactMap {
            $0.selectingPaths($0.paths.filter(paths.contains)).selectedSubset
        }, skills: skills.filter { skillPaths.contains($0.path) },
        servers: servers.filter { serverIDs.contains($0.id) },
        installations: installations.filter { installationIDs.contains($0.id) },
        // A failed package manager can remove its executable before its body.
        // Keep that accepted CLI operation for retry; successful ones were
        // already removed from this selection before the data stage.
        cliInstallations: cliInstallations, removedAgentIDs: removedAgentIDs)
    }
}

private struct AgentCleanupProgress {
    var removed = 0
    var reclaimedBytes: UInt64 = 0
    var skipped = 0
    var failed = 0
    var messages: [String] = []
    var completedCLIUnits = 0
    var totalUnits = 0

    mutating func merge(_ uninstall: AgentCLIService.Outcome) {
        removed += uninstall.removed
        reclaimedBytes &+= uninstall.reclaimedBytes
        failed += uninstall.succeeded ? uninstall.failed : max(1, uninstall.failed)
        messages += uninstall.messages
    }

    mutating func merge(_ outcome: AgentCleanupExecutor.Outcome) {
        removed += outcome.summary.removed
        reclaimedBytes &+= outcome.summary.reclaimedBytes
        skipped += outcome.summary.skipped + outcome.refused
        failed += outcome.summary.failed
        messages += outcome.summary.messages
    }
}

private struct AgentTaskAction {
    let selection: AgentCleanupSelection
    var progress = AgentCleanupProgress()

    func continuing(with selection: AgentCleanupSelection,
                    completed: AgentCleanupExecutor.Outcome? = nil) -> Self {
        var progress = progress
        if let completed { progress.merge(completed) }
        return .init(selection: selection, progress: progress)
    }
}

/// Leaf updates stay off the UI actor until they are coalesced. Unit changes
/// and the first child of a selected root are always delivered.
private final class AgentProgressDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var lastSentAt = Date.distantPast
    private var lastCompleted = -1
    private var lastPath = ""
    private var reportedFirstChild = false

    func shouldDeliver(completed: Int, path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        let firstChild = !reportedFirstChild && !lastPath.isEmpty && path.hasPrefix(lastPath + "/")
        let changedUnit = completed != lastCompleted
        guard changedUnit || firstChild || now.timeIntervalSince(lastSentAt) >= 0.1 else { return false }
        if changedUnit { reportedFirstChild = false }
        if firstChild { reportedFirstChild = true }
        lastCompleted = completed
        lastPath = path
        lastSentAt = now
        return true
    }
}

/// Agent 专清独立于快速清理；用户数据、全局资源和卸载动作均由用户明确选择。
@MainActor
extension AppState {
    var agentSelectedCount: Int {
        effectiveAgentCleanupSelection.count
    }

    var agentCLISelectedAgentIDs: Set<String> {
        Set(agentCLIInstallations.filter { agentSelectedCLIInstallations.contains($0.id) }.map(\.agentID))
    }

    func isAgentCategorySelected(_ category: CleanupCategory, path: String? = nil) -> Bool {
        let includedByCLI = category.canSelect && agentGroups.contains {
            agentCLISelectedAgentIDs.contains($0.id) && $0.categoryIDs.contains(category.id)
        }
        if let path { return category.paths.contains(path) && (includedByCLI || category.isPathSelected(path)) }
        return includedByCLI || category.selected
    }

    func isAgentSkillSelected(_ skill: AgentSkill) -> Bool {
        agentSelectedSkills.contains(skill.path) || agentCLISelectedAgentIDs.contains(skill.agentID)
    }

    func isAgentServerSelected(_ server: AgentMCPServer) -> Bool {
        agentSelectedServers.contains(server.id) || agentCLISelectedAgentIDs.contains(server.agentID)
    }

    private var effectiveAgentCleanupSelection: AgentCleanupSelection {
        .init(categories: agentCategories.compactMap { category in
            category.selectingPaths(category.paths.filter { isAgentCategorySelected(category, path: $0) }).selectedSubset
        }, skills: agentSkills.filter(isAgentSkillSelected),
        servers: agentServers.filter(isAgentServerSelected),
        installations: agentMCPInstallations.filter { agentSelectedMCPInstallations.contains($0.id) },
        cliInstallations: agentCLIInstallations.filter { agentSelectedCLIInstallations.contains($0.id) })
    }

    var agentSelectedBytes: UInt64 {
        let paths = effectiveAgentCleanupSelection.categories.flatMap { category in
            category.paths.map { ($0, category.pathBytes[$0] ?? 0) }
        } + agentSkills.filter(isAgentSkillSelected).map { ($0.path, $0.bytes) }
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
        var details = effectiveAgentCleanupSelection.categories.map {
            "\($0.name) · \($0.paths.count) · \(ByteFormat.format($0.bytes))\n\(L10n.shared.t($0.reasonKey))"
        }
        details += agentSkills.filter(isAgentSkillSelected).map {
            L10n.shared.tf($0.linked ? "agents.confirm.unlinkSkill" : "agents.confirm.deleteSkill", $0.name)
        }
        details += agentServers.filter(isAgentServerSelected).map {
            L10n.shared.tf($0.issues.contains(.unreadableConfig)
                           ? "agents.confirm.deleteConfig" : "agents.confirm.unlinkMCP", $0.name, $0.agentName)
        }
        details += agentMCPInstallations.filter { agentSelectedMCPInstallations.contains($0.id) }.map {
            L10n.shared.tf("agents.confirm.deleteMCP", $0.name)
        }
        details += effectiveAgentCleanupSelection.cliInstallations.map {
            L10n.shared.tf($0.onlyUnlinksExecutable ? "agents.cli.confirmLink" : "agents.cli.confirm", $0.name)
        }
        return details
    }

    func scanAgents(completionStatus: String? = nil) {
        guard !isBusy else { return }
        agentScanning = true
        agentScanComplete = false
        agentOutcomeMood = nil
        agentOutcomeDetails = []
        agentCleanupHasFeedback = false
        agentReclaimedBytes = 0
        agentCelebrating = false
        agentCleanupProgress = nil
        agentFailureApplications = []
        agentRetryAvailable = false
        agentRetryAction = nil
        agentTaskGeneration = UUID()
        agentStatus = L10n.shared.t("agents.status.scanning")
        agentScanCurrentPath = NSHomeDirectory()
        let generation = agentTaskGeneration
        let control = CleanupScanControl(mode: .deep, totalBudget: 180, directoryBudget: 30,
            onDirectory: { [weak self] path in
                Task { @MainActor [weak self] in
                    guard let self, self.agentScanning, self.agentTaskGeneration == generation else { return }
                    self.agentScanCurrentPath = path
                }
            })
        Task {
            let home = NSHomeDirectory()
            let (report, cli) = await Task.detached(priority: .utility) {
                Self.loadAgentInventory(home: home, control: control)
            }.value
            updateAgentInventory(report, cli: cli)
            agentSelectedSkills = []
            agentSelectedServers = []
            agentSelectedMCPInstallations = []
            agentSelectedCLIInstallations = []
            agentScanning = false
            agentScanCurrentPath = ""
            // The inventory carries the default cleanup recommendation. A
            // safe-only reset here discarded reviewed caches and checkpoints.
            if completionStatus == nil {
                noteHeaderReaction(report.complete ? .success : .attention)
            }
            if !report.complete {
                for index in agentCategories.indices { agentCategories[index].selected = false }
                agentOutcomeMood = .attention
                agentOutcomeDetails = [L10n.shared.t("log.scanPartial")]
                agentCleanupHasFeedback = true
                recordAgentAttention()
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

    nonisolated private static func loadAgentInventory(home: String, includingAgentIDs: Set<String> = [],
        control: CleanupScanControl = CleanupScanControl(mode: .deep, totalBudget: 180, directoryBudget: 30))
        -> (AgentScanReport, [AgentCLIInstallation]) {
        var report = AgentInventory.scan(home: home, control: control, localize: { L10n.shared.t($0) },
                                         includingAgentIDs: includingAgentIDs)
        let cli = AgentCatalog.definitions.flatMap { AgentCLIService.installations(for: $0, home: home) }
        for agent in AgentCatalog.definitions where cli.contains(where: { $0.agentID == agent.id }) {
            if !report.groups.contains(where: { $0.id == agent.id }) {
                report.groups.append(AgentGroupSummary(
                    id: agent.id, name: agent.name, documented: agent.documented,
                    orphaned: false, categoryIDs: [], skillIDs: [], serverIDs: [], bytes: 0))
            }
        }
        return (report, cli)
    }

    private func updateAgentInventory(_ report: AgentScanReport, cli: [AgentCLIInstallation]) {
        agentCategories = report.categories
        agentGroups = report.groups
        agentSkills = report.skills
        agentServers = report.servers
        agentMCPInstallations = report.installations
        agentCLIInstallations = cli
        agentHasScanned = true
        agentScanComplete = report.complete
    }

    func selectSafeAgentItems() {
        guard !isBusy else { return }
        for index in agentCategories.indices {
            agentCategories[index].selected = agentCategories[index].risk == .safe
        }
        agentSelectedSkills = []
        agentSelectedServers = []
        agentSelectedMCPInstallations = []
        agentSelectedCLIInstallations = []
    }

    func clearAgentSelection() {
        for index in agentCategories.indices { agentCategories[index].selected = false }
        agentSelectedSkills = []
        agentSelectedServers = []
        agentSelectedMCPInstallations = []
        agentSelectedCLIInstallations = []
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

    func toggleAgentCLIInstallation(_ installation: AgentCLIInstallation) {
        guard !isBusy, agentCLIInstallations.contains(where: { $0.id == installation.id }) else { return }
        if agentSelectedCLIInstallations.contains(installation.id) {
            agentSelectedCLIInstallations.remove(installation.id)
        } else {
            agentSelectedCLIInstallations.insert(installation.id)
        }
    }

    func applyAgentCleanup() {
        guard !isBusy, agentHasScanned else { return }
        let selection = effectiveAgentCleanupSelection
        guard selection.count > 0 else {
            agentStatus = L10n.shared.t("cleanup.selectNone")
            return
        }
        startAgentAction(.init(selection: selection))
    }

    private func startAgentAction(_ requestedAction: AgentTaskAction, rechecking: Bool = false) {
        guard !isBusyExcludingUninstall, uninstallQueue.activeJob == nil,
              !cleanupQueued, agentHasScanned else { return }
        agentApplying = true
        var action = requestedAction
        if rechecking {
            action.progress.removed = 0
            action.progress.reclaimedBytes = 0
            action.progress.skipped = 0
            action.progress.failed = 0
            action.progress.messages = []
        }
        action.progress.totalUnits = action.selection.count + action.progress.completedCLIUnits
        let acceptedAction = action
        agentCompletedCount = action.progress.removed
        agentReclaimedBytes = action.progress.reclaimedBytes
        agentTaskGeneration = UUID()
        agentCleanupProgress = .init()
        agentCelebrating = false
        agentCleanupHasFeedback = true
        agentFailureApplications = []
        agentRetryAvailable = true
        agentRetryAction = { [weak self] in self?.startAgentAction(acceptedAction, rechecking: true) }
        agentOutcomeMood = nil
        agentOutcomeDetails = []
        agentStatus = L10n.shared.t("task.closeApps.check")
        Task {
            let snapshot = await captureRunningApplicationSnapshot()
            let home = NSHomeDirectory()
            guard await agentActionMayProceed(acceptedAction, snapshot: snapshot, home: home, rechecking: rechecking) else { return }
            await executeAgentAction(acceptedAction, snapshot: snapshot, home: home)
        }
    }

    /// Preflight the same immutable CLI/data plan before any mutation. Agent
    /// outcomes stay on this page, including owners the user needs to quit.
    private func agentActionMayProceed(_ action: AgentTaskAction, snapshot: RunningApplicationSnapshot,
                                      home: String, rechecking: Bool = false) async -> Bool {
        let selection = action.selection
        if !selection.cliInstallations.isEmpty && !snapshot.isComplete {
            agentApplying = false
            agentOutcomeMood = .attention
            agentStatus = L10n.shared.t("task.failure.runtimeUnknown")
            agentOutcomeDetails = [agentStatus]
            recordAgentAttention()
            return false
        }
        let blockers = await Task.detached(priority: .utility) {
            AgentCleanupExecutor.blockingResources(selection.categories,
                skills: selection.skills, installations: selection.installations, servers: selection.servers,
                running: snapshot, home: home, removingAgentIDs: selection.catalogAgentIDs)
        }.value
        var owners = blockers.owners
        let selectedCLIIDs = Set(selection.cliInstallations.map(\.agentID))
        owners += AgentCatalog.definitions.filter { selectedCLIIDs.contains($0.id) }
            .flatMap(\.owners).filter {
                snapshot.contains(processName: $0) || snapshot.contains(bundleIdentifier: $0)
            }
        let waiting = selection.partitioned(by: blockers, waiting: true)
        // Audited live caches may proceed independently of sensitive data.
        // A selected CLI and its associated data wait together until preflight
        // is clear; selecting the CLI never uninstalls it by itself.
        if selection.cliInstallations.isEmpty, waiting.count > 0 {
            let ready = selection.partitioned(by: blockers, waiting: false)
            if ready.count > 0 {
                agentStatus = L10n.shared.tf("agents.status.cleaning", ready.count)
                let onProgress = agentExecutionProgress(ready,
                    completedOffset: action.progress.completedCLIUnits,
                    total: action.progress.totalUnits)
                let outcome = await Task.detached(priority: .utility) {
                    AgentCleanupExecutor.execute(ready.categories, running: snapshot, home: home, permanent: true,
                        skills: ready.skills, installations: ready.installations, servers: ready.servers,
                        removingAgentIDs: selection.removedAgentIDs, onProgress: onProgress)
                }.value
                var progress = action.progress
                progress.merge(outcome)
                await finishAgentMutation(removed: progress.removed, skipped: progress.skipped,
                    reclaimedBytes: progress.reclaimedBytes, failed: progress.failed, messages: progress.messages,
                    pendingAction: .init(selection: selection, progress: progress),
                    pendingOwners: owners, runtimeAvailable: snapshot.isComplete)
                return false
            }
        }
        if !snapshot.isComplete, waiting.count > 0 {
            agentApplying = false
            agentOutcomeMood = .attention
            agentStatus = L10n.shared.t("task.failure.runtimeUnknown")
            agentOutcomeDetails = [agentStatus]
            recordAgentAttention()
            return false
        }
        guard !owners.isEmpty else { return true }
        let names = Self.blockingApplicationNames(owners)
        agentApplying = false
        agentOutcomeMood = .attention
        agentStatus = L10n.shared.t(rechecking ? "task.closeApps.changed" : "task.closeApps.message")
        agentOutcomeDetails = [agentStatus]
        recordAgentAttention(applications: names)
        return false
    }

    static func blockingApplicationNames(_ owners: [String]) -> [String] {
        let applications = NSWorkspace.shared.runningApplications
        var seen = Set<String>()
        return owners.compactMap { owner in
            let app = applications.first {
                [$0.bundleIdentifier, $0.localizedName, $0.executableURL?.lastPathComponent]
                    .compactMap { $0 }.contains { $0.caseInsensitiveCompare(owner) == .orderedSame }
            }
            let name = app?.localizedName ?? owner
            return seen.insert(name.lowercased()).inserted ? name : nil
        }.sorted()
    }

    private func executeAgentAction(_ action: AgentTaskAction, snapshot: RunningApplicationSnapshot, home: String) async {
        let selection = action.selection
        var progress = action.progress
        if !selection.cliInstallations.isEmpty {
            let onProgress = agentExecutionProgress(selection,
                completedOffset: progress.completedCLIUnits, total: progress.totalUnits)
            var succeededIDs = Set<String>()
            var confirmedCLIPaths = Set<String>()
            var retryInstallations: [String: AgentCLIInstallation] = [:]
            var retryRequiresScan = false
            for (index, installation) in selection.cliInstallations.enumerated() {
                agentStatus = L10n.shared.tf("agents.status.uninstalling", installation.name)
                let fresh = index == 0 ? snapshot : await captureRunningApplicationSnapshot()
                let outcome = await Task.detached(priority: .utility) {
                    AgentCLIService.uninstall(installation, home: home, running: fresh,
                        permanent: true, onCurrentFile: { path in
                            onProgress(index, selection.count, path)
                        })
                }.value
                progress.merge(outcome)
                if outcome.succeeded {
                    succeededIDs.insert(installation.id)
                    confirmedCLIPaths.formUnion(installation.managedPaths + installation.executablePaths)
                    progress.completedCLIUnits += 1
                } else {
                    retryInstallations[installation.id] = outcome.retryInstallation ?? installation
                    retryRequiresScan = retryRequiresScan || outcome.requiresRescan
                }
                onProgress(index + 1, selection.count,
                    installation.managedPaths.first ?? installation.executablePaths.first ?? "")
            }
            var remainder = selection
            remainder.cliInstallations = selection.cliInstallations.compactMap { retryInstallations[$0.id] }
            remainder.removedAgentIDs.formUnion(selection.cliInstallations.filter {
                succeededIDs.contains($0.id)
            }.map(\.agentID))
            let remainingData = remainder.excludingCoveredPaths(confirmedCLIPaths)
            progress.completedCLIUnits += max(0, remainder.count - remainingData.count)
            remainder = remainingData
            if !remainder.cliInstallations.isEmpty {
                // Preserve all associated data until the selected CLI phase
                // succeeds. The retry excludes CLIs already removed.
                await finishAgentMutation(removed: progress.removed, skipped: progress.skipped,
                    reclaimedBytes: progress.reclaimedBytes,
                    failed: progress.failed, messages: progress.messages,
                    pendingAction: .init(selection: remainder, progress: progress),
                    retryRequiresScan: retryRequiresScan)
                return
            }
            // Package managers may run for a while. Recheck owners again at
            // the data edge and retain the original scanned file identities.
            let fresh = await captureRunningApplicationSnapshot()
            let next = AgentTaskAction(selection: remainder, progress: progress)
            agentCompletedCount = progress.removed
            agentReclaimedBytes = progress.reclaimedBytes
            agentSelectedCLIInstallations.subtract(succeededIDs)
            let acceptedPaths = Set(remainder.categories.flatMap(\.paths))
            agentCategories = agentCategories.map { $0.selectingPaths(acceptedPaths) }
            agentSelectedSkills = Set(remainder.skills.map(\.path))
            agentSelectedServers = Set(remainder.servers.map(\.id))
            agentSelectedMCPInstallations = Set(remainder.installations.map(\.id))
            agentRetryAction = { [weak self] in self?.startAgentAction(next, rechecking: true) }
            guard await agentActionMayProceed(next, snapshot: fresh, home: home) else { return }
            await executeAgentAction(next, snapshot: fresh, home: home)
            return
        }
        agentStatus = L10n.shared.tf("agents.status.cleaning", selection.count)
        let onProgress = agentExecutionProgress(selection,
            completedOffset: progress.completedCLIUnits, total: progress.totalUnits)
        let outcome = await Task.detached(priority: .utility) {
            AgentCleanupExecutor.execute(selection.categories, running: snapshot, home: home, permanent: true,
                skills: selection.skills, installations: selection.installations, servers: selection.servers,
                removingAgentIDs: selection.removedAgentIDs, onProgress: onProgress)
        }.value
        progress.merge(outcome)
        let incomplete = progress.skipped > 0 || progress.failed > 0
        await finishAgentMutation(removed: progress.removed, skipped: progress.skipped,
            reclaimedBytes: progress.reclaimedBytes,
            failed: progress.failed, messages: progress.messages,
            pendingAction: incomplete ? .init(selection: selection, progress: progress) : nil)
    }

    private func finishAgentMutation(removed: Int, skipped: Int, reclaimedBytes: UInt64, failed: Int, messages: [String],
                                     pendingAction: AgentTaskAction? = nil,
                                     pendingOwners: [String] = [], runtimeAvailable: Bool = true,
                                     retryRequiresScan: Bool = false) async {
        defer { agentApplying = false }
        agentCleanupProgress = .init(phase: .verifying)
        agentCompletedCount = removed
        agentReclaimedBytes = reclaimedBytes
        if !messages.isEmpty { log(messages.joined(separator: "\n")) }
        if removed > 0 {
            CleanupCache.invalidate()
            cleanupScanComplete = false
        }
        resampleAfterMutation()
        let summary = L10n.shared.tf("cleanup.execution.summary", removed, skipped, failed)
        log(summary)
        guard skipped > 0 || failed > 0 || pendingAction != nil else {
            completeAgentMutation(summary: summary, removed: removed, skipped: skipped, failed: failed)
            return
        }
        let original = pendingAction?.selection ?? effectiveAgentCleanupSelection
        agentStatus = L10n.shared.t("agents.status.refreshing")
        let home = NSHomeDirectory()
        let (report, cli) = await Task.detached(priority: .utility) {
            // A removed CLI can leave data after a later failure. Keep those
            // accepted Agent scopes visible even though installed=false now.
            Self.loadAgentInventory(home: home, includingAgentIDs: original.catalogAgentIDs)
        }.value
        updateAgentInventory(report, cli: cli)
        let remaining = report.complete ? original.retainingPresentResources(report) : original
        let selectedPaths = Set(remaining.categories.flatMap(\.paths))
        agentCategories = agentCategories.map { $0.selectingPaths(selectedPaths) }
        agentSelectedSkills = Set(remaining.skills.map(\.path))
        agentSelectedServers = Set(remaining.servers.map(\.id))
        agentSelectedMCPInstallations = Set(remaining.installations.map(\.id))
        agentSelectedCLIInstallations = Set(remaining.cliInstallations.map(\.id))
        if report.complete && remaining.count == 0 && skipped == 0 && failed == 0 {
            completeAgentMutation(summary: summary, removed: removed, skipped: skipped, failed: failed)
            return
        }
        agentOutcomeDetails = removed > 0 ? [] : messages.filter { !$0.hasPrefix("Open-file check ") }
        if removed == 0 && !runtimeAvailable { agentOutcomeDetails.append(L10n.shared.t("task.failure.runtimeRemaining")) }
        if removed == 0 && agentOutcomeDetails.isEmpty && pendingOwners.isEmpty {
            agentOutcomeDetails = [L10n.shared.t("agents.result.noReason")]
        }
        recordAgentAttention(applications: Self.blockingApplicationNames(pendingOwners))
        agentStatus = removed > 0 ? L10n.shared.tf("cleanup.task.reclaimed", ByteFormat.format(reclaimedBytes))
            : summary + "\n" + L10n.shared.t(pendingOwners.isEmpty
                ? "agents.status.incomplete" : "task.closeApps.remaining")
        noteHeaderReaction(removed > 0 ? .success : .attention)
        if remaining.count > 0 && !retryRequiresScan {
            var retainedProgress = pendingAction?.progress ?? AgentCleanupProgress()
            retainedProgress.removed = removed
            retainedProgress.reclaimedBytes = reclaimedBytes
            let retryAction = AgentTaskAction(selection: remaining, progress: retainedProgress)
            agentRetryAction = { [weak self] in self?.startAgentAction(retryAction, rechecking: true) }
            agentRetryAvailable = true
        } else {
            agentRetryAction = nil
            agentRetryAvailable = false
        }
    }

    private func completeAgentMutation(summary: String, removed: Int, skipped: Int, failed: Int) {
        agentCleanupProgress = nil
        agentRetryAction = nil
        agentRetryAvailable = false
        agentFailureApplications = []
        agentFeedbackID += 1
        agentCompletedCount = removed
        agentCelebrating = removed > 0
        // 丢弃过期清单；庆祝结束后回闲置，下一次操作从新扫描开始。
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
        agentOutcomeDetails = []
        agentOutcomeMood = NoriCleanupFeedback.mood(removed: removed, skipped: skipped, failed: failed)
        noteHeaderReaction(NoriHeaderReaction.mood(removed: removed, skipped: skipped, failed: failed))
    }

    func finishAgentCelebration(feedbackID: Int) {
        guard feedbackID == agentFeedbackID, !agentApplying,
              agentOutcomeMood == .success, agentCelebrating else { return }
        agentCelebrating = false
    }

    private func recordAgentAttention(applications: [String] = []) {
        agentCleanupProgress = nil
        agentCelebrating = agentCompletedCount > 0
        agentOutcomeMood = agentCompletedCount > 0 ? .success : .attention
        agentFailureApplications = agentCompletedCount > 0 ? [] : applications
        if agentCompletedCount > 0 { agentOutcomeDetails = [] }
        agentFeedbackID += 1
    }

    private func agentExecutionProgress(_ selection: AgentCleanupSelection,
                                        completedOffset: Int = 0, total plannedTotal: Int = 0)
        -> (Int, Int, String) -> Void {
        let generation = agentTaskGeneration
        let delivery = AgentProgressDelivery()
        agentCleanupProgress = .init(phase: .cleaning, completed: completedOffset,
                                      total: plannedTotal > 0 ? plannedTotal : selection.count)
        return { [weak self] completed, total, path in
            let overallCompleted = completedOffset + completed
            guard delivery.shouldDeliver(completed: overallCompleted, path: path) else { return }
            Task { @MainActor [weak self] in
                guard let self, self.agentTaskGeneration == generation, self.agentApplying,
                      self.agentCleanupProgress?.phase == .cleaning else { return }
                self.agentCleanupProgress = .init(phase: .cleaning,
                    completed: max(self.agentCleanupProgress?.completed ?? 0, overallCompleted),
                    total: plannedTotal > 0 ? plannedTotal : completedOffset + total,
                    currentItem: path)
            }
        }
    }

    func retryFailedAgentCleanup() {
        guard !isBusyExcludingUninstall, uninstallQueue.activeJob == nil,
              !cleanupQueued, let retry = agentRetryAction else { return }
        agentRetryAction = nil
        agentRetryAvailable = false
        retry()
    }

}
