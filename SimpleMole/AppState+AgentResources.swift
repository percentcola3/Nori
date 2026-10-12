import Foundation

@MainActor
extension AppState {
    var selectedAgentUnbindings: AgentResourceChanges {
        .init(skills: agentSkills.filter { $0.linked && agentSelectedSkills.contains($0.path) },
            registrations: agentSkills.flatMap(\.registrations).reduce(into: []) { result, registration in
                if agentSelectedSkillRegistrations.contains(registration.id), !result.contains(registration) {
                    result.append(registration)
                }
            }, servers: agentServers.filter { agentSelectedServers.contains($0.id)
                && !$0.issues.contains(.unreadableConfig) })
    }

    func toggleAgentSkillBinding(_ binding: AgentResourceCatalog.SkillBinding) {
        guard !isAgentTaskBusy else { return }
        if let link = binding.link { toggleAgentSkill(link) }
        if let registration = binding.registration {
            if !agentSelectedSkillRegistrations.insert(registration.id).inserted {
                agentSelectedSkillRegistrations.remove(registration.id)
            }
        }
    }

    func isAgentSkillBindingSelected(_ binding: AgentResourceCatalog.SkillBinding) -> Bool {
        if let link = binding.link { return agentSelectedSkills.contains(link.path) }
        if let registration = binding.registration { return agentSelectedSkillRegistrations.contains(registration.id) }
        return false
    }

    func toggleAgentSkillBindings(_ bindings: [AgentResourceCatalog.SkillBinding]) {
        let removable = bindings.filter(\.removable)
        let selected = !removable.isEmpty && removable.allSatisfy(isAgentSkillBindingSelected)
        for binding in removable where isAgentSkillBindingSelected(binding) == selected { toggleAgentSkillBinding(binding) }
    }

    func requestAgentResourceChanges(_ changes: AgentResourceChanges) {
        guard changes.count > 0, !isAgentTaskBusy, !isCleanupMutationBusy, uninstallQueue.activeJob == nil,
              commandLineToolBusyID == nil, softwareUpdatingID == nil, confirmation == nil, taskNotice == nil else { return }
        let names = changes.skills.map { $0.name + ($0.usedBy.isEmpty ? "" : " · " + $0.usedBy.joined(separator: ", ")) + "\n" + $0.path }
        let serverNames = changes.servers.map { $0.agentName + " · " + $0.name + "\n" + $0.configPath }
        let installationNames = changes.installations.map { $0.name + "\n" + $0.path }
        let registrationNames = changes.registrations.map { "Codex · " + $0.skillPath }
        confirmation = Confirmation(title: l10n.t(changes.deletesBodies ? "agents.manage.deleteTitle" : "agents.manage.unlinkTitle"),
            message: l10n.t(changes.deletesBodies ? "agents.manage.deleteImpact" : "agents.manage.unlinkImpact")
                + "\n\n" + (names + serverNames + installationNames + registrationNames).joined(separator: "\n\n"),
            confirmLabel: l10n.t(changes.deletesBodies ? "agents.manage.delete" : "agents.manage.unlink")) { [weak self] in
                self?.performAgentResourceChanges(changes)
            }
    }

    private func performAgentResourceChanges(_ changes: AgentResourceChanges) {
        guard !isAgentTaskBusy, !isCleanupMutationBusy, uninstallQueue.activeJob == nil,
              commandLineToolBusyID == nil, softwareUpdatingID == nil else { return }
        let selectedPaths = Set(agentCategories.flatMap(\.selectedPaths))
        agentTaskGeneration = UUID()
        agentStorageGeneration = UUID()
        agentStorageCheckingIDs = []
        agentApplying = true
        agentCleanupHasFeedback = true
        agentOutcomeMood = nil
        agentOutcomeDetails = []
        agentFailureApplications = []
        agentRetryAvailable = false
        agentRetryAction = nil
        agentCelebrating = false
        agentCompletedCount = 0
        agentReclaimedBytes = 0
        agentCleanupProgress = .init(phase: .preparing)
        agentStatus = l10n.t("agents.apply.working")
        Task {
            let running = await captureRunningApplicationSnapshot()
            let home = NSHomeDirectory()
            let outcome = await Task.detached(priority: .utility) {
                AgentResourceMutator.execute(changes, running: running, home: home)
            }.value
            agentCleanupProgress = .init(phase: .verifying)
            agentStatus = l10n.t("agents.status.refreshing")
            let (report, cli, applications, footprints, bodies) = await Task.detached(priority: .utility) {
                let control = CleanupScanControl(mode: .deep, totalBudget: 180, directoryBudget: 30)
                let (report, cli) = Self.loadAgentInventory(home: home, control: control)
                return (report, cli, AgentSoftwareInventory.applications(home: home),
                    AgentStorageFootprint.build(report: report, cli: cli), Self.measureAgentCLIBodies(cli, control: control))
            }.value
            updateAgentInventory(report, cli: cli)
            agentApplications = applications
            agentStorageFootprints = footprints
            agentCLIBodySizes = bodies
            agentCategories = agentCategories.map { $0.selectingPaths(selectedPaths) }
            agentSelectedSkills.formIntersection(Set(report.skills.map(\.path)))
            agentSelectedServers.formIntersection(Set(report.servers.map(\.id)))
            agentSelectedMCPInstallations.formIntersection(Set(report.installations.map(\.id)))
            agentSelectedSkillRegistrations.formIntersection(Set(report.skills.flatMap(\.registrations).map(\.id)))
            let summary = outcome.summary
            let skipped = summary.skipped + outcome.refused
            agentCompletedCount = summary.removed
            agentReclaimedBytes = summary.reclaimedBytes
            agentStatus = l10n.tf("cleanup.execution.summary", summary.removed, skipped, summary.failed)
            agentOutcomeDetails = summary.messages
            if !report.complete { agentOutcomeDetails.append(l10n.t("log.scanPartial")) }
            agentOutcomeMood = skipped > 0 || summary.failed > 0 || !report.complete ? .attention : .success
            agentFeedbackID += 1
            agentCleanupProgress = nil
            agentApplying = false
            if summary.removed > 0 { CleanupCache.invalidate(); cleanupScanComplete = false; resampleAfterMutation() }
            noteHeaderReaction(agentOutcomeMood)
        }
    }
}
