import Foundation

/// Removing an installation and removing its user data are separate actions.
/// Ordinary Agent cleanup keeps its existing Safe/Protected policy; this flow
/// reviews complete, exclusively owned roots and always uses the Trash.
@MainActor
extension AppState {
    private var canRequestAgentCompleteRemoval: Bool {
        !isAgentTaskBusy && !isCleanupMutationBusy && uninstallQueue.activeJob == nil
            && commandLineToolBusyID == nil && softwareUpdatingID == nil
            && confirmation == nil && taskNotice == nil
    }

    func offerAgentCompleteRemoval(agentIDs: Set<String>, programName: String? = nil) {
        guard !agentIDs.isEmpty, canRequestAgentCompleteRemoval else { return }
        let home = NSHomeDirectory()
        agentProgramBusyID = "data:" + agentIDs.sorted().joined(separator: ",")
        Task { [self] in
            let (plan, cli) = await Task.detached(priority: .utility) {
                (AgentRemovalService.plan(agentIDs: agentIDs, home: home),
                 AgentCatalog.definitions.filter { agentIDs.contains($0.id) }
                    .flatMap { AgentCLIService.installations(for: $0, home: home) })
            }.value
            guard !plan.items.isEmpty else {
                // A program can have no data roots left. Refresh even then so
                // its old Agent/CLI rows do not survive a successful uninstall.
                let (report, currentCLI, footprints, applications, bodies) = await Task.detached(priority: .utility) {
                    let control = CleanupScanControl(mode: .deep, totalBudget: 180, directoryBudget: 30)
                    let (report, cli) = Self.loadAgentInventory(home: home,
                        includingAgentIDs: agentIDs, control: control)
                    return (report, cli, AgentStorageFootprint.build(report: report, cli: cli),
                            AgentSoftwareInventory.applications(home: home),
                            Self.measureAgentCLIBodies(cli, control: control))
                }.value
                updateAgentInventory(report, cli: currentCLI)
                agentStorageFootprints = footprints
                agentApplications = applications
                agentCLIBodySizes = bodies
                clearAgentSelection()
                agentProgramBusyID = nil
                var details = agentRemovalDetails(messages: plan.messages, retained: plan.retainedPaths)
                if !report.complete { details.append(l10n.t("log.scanPartial")) }
                if plan.retainedPaths.isEmpty && plan.messages.isEmpty && report.complete {
                    agentCleanupHasFeedback = true
                    agentStatus = l10n.t("agents.data.empty")
                    agentOutcomeMood = .success
                    agentOutcomeDetails = []
                    agentFeedbackID += 1
                } else {
                    presentTaskNotice(TaskFeedbackNotice(message: l10n.t("agents.data.retainedOnly"), details: details))
                }
                return
            }
            let scope = AgentDataProcessScope.make(agentIDs: agentIDs, cli: cli, home: home)
            let (probe, identities) = await Task.detached(priority: .utility) {
                (SoftwareUpdateProcesses.probe(scope),
                 Dictionary(scope.roots.compactMap { path in
                    DeletionPlan.identity(at: path).map { (path, $0) }
                 }, uniquingKeysWith: { first, _ in first }))
            }.value
            agentProgramBusyID = nil
            guard canRequestAgentCompleteRemoval else { return }
            guard probe.isComplete else {
                presentTaskFailure(details: [l10n.t("cli.uninstall.runtimeUnknown")], detailsAreLocalized: true)
                return
            }
            if !probe.processes.isEmpty {
                confirmation = Confirmation(title: l10n.t("agents.data.running.title"),
                    message: l10n.t("agents.data.running.message") + "\n\n"
                        + Set(probe.processes.map(\.name)).sorted().joined(separator: ", "),
                    confirmLabel: l10n.t("agents.data.running.action")) { [weak self] in
                        guard let self, self.canRequestAgentCompleteRemoval else { return }
                        self.agentProgramBusyID = "data:" + agentIDs.sorted().joined(separator: ",")
                        Task {
                            let stopped = await SoftwareUpdateProcesses.close(scope, stillCurrent: {
                                self.agentProgramBusyID != nil && !Task.isCancelled
                                    && identities.count == scope.roots.count
                                    && identities.allSatisfy { DeletionPlan.identity(at: $0.key) == $0.value }
                            })
                            self.agentProgramBusyID = nil
                            guard stopped else {
                                self.presentTaskFailure(details: [self.l10n.t("cli.uninstall.closeFailed")],
                                                        detailsAreLocalized: true)
                                return
                            }
                            // Closing a consumer may flush its database. Rebuild
                            // the preview before asking for the data consent.
                            self.offerAgentCompleteRemoval(agentIDs: agentIDs, programName: programName)
                        }
                    }
                return
            }
            var message = l10n.tf("agents.data.confirm.message", plan.items.count)
            if let programName { message = l10n.tf("agents.data.programRemoved", programName) + "\n\n" + message }
            message += "\n\n" + l10n.t("agents.data.paths") + "\n" + plan.items.map(\.record).joined(separator: "\n")
            let retained = agentRemovalDetails(messages: plan.messages, retained: plan.retainedPaths)
            if !retained.isEmpty { message += "\n\n" + retained.joined(separator: "\n") }
            confirmation = Confirmation(title: l10n.t("agents.data.confirm.title"), message: message,
                confirmLabel: l10n.t("agents.data.confirm.action")) { [weak self] in
                    guard let self, self.canRequestAgentCompleteRemoval else { return }
                    self.executeAgentCompleteRemoval(plan, home: home, programName: programName)
                }
        }
    }

    private func executeAgentCompleteRemoval(_ plan: AgentRemovalService.Plan, home: String,
                                             programName: String?) {
        agentProgramBusyID = "data:" + plan.agentIDs.sorted().joined(separator: ",")
        Task { [self] in
            let cli = await Task.detached(priority: .utility) {
                AgentCatalog.definitions.filter { plan.agentIDs.contains($0.id) }
                    .flatMap { AgentCLIService.installations(for: $0, home: home) }
            }.value
            let scope = AgentDataProcessScope.make(agentIDs: plan.agentIDs, cli: cli, home: home)
            let probe = await Task.detached(priority: .utility) { SoftwareUpdateProcesses.probe(scope) }.value
            agentProgramBusyID = nil
            guard canRequestAgentCompleteRemoval else { return }
            guard probe.isComplete else {
                presentTaskFailure(details: [l10n.t("cli.uninstall.runtimeUnknown")], detailsAreLocalized: true)
                return
            }
            guard probe.processes.isEmpty else {
                offerAgentCompleteRemoval(agentIDs: plan.agentIDs, programName: programName)
                return
            }
            agentApplying = true
            agentCleanupHasFeedback = true
            agentCelebrating = false
            agentCompletedCount = 0
            agentReclaimedBytes = 0
            agentOutcomeMood = nil
            agentOutcomeDetails = []
            agentFailureApplications = []
            agentRetryAction = nil
            agentRetryAvailable = false
            agentCleanupProgress = .init(phase: .cleaning, total: plan.items.count)
            agentStatus = l10n.t("agents.data.removing")
            let running = await captureRunningApplicationSnapshot()
            let summary = await Task.detached(priority: .utility) {
                // Preserve the reviewed roots and identities. A fresh inventory
                // may reject the plan, but must never expand its authority.
                AgentRemovalService.execute(plan, running: running, home: home)
            }.value
            agentCleanupProgress = .init(phase: .verifying)
            agentStatus = l10n.t("agents.status.refreshing")
            let (report, currentCLI, footprints, applications, bodies, remainingPlan) = await Task.detached(priority: .utility) {
                let control = CleanupScanControl(mode: .deep, totalBudget: 180, directoryBudget: 30)
                let (report, cli) = Self.loadAgentInventory(home: home,
                    includingAgentIDs: plan.agentIDs, control: control)
                return (report, cli, AgentStorageFootprint.build(report: report, cli: cli),
                        AgentSoftwareInventory.applications(home: home),
                        Self.measureAgentCLIBodies(cli, control: control),
                        AgentRemovalService.plan(agentIDs: plan.agentIDs, home: home))
            }.value
            updateAgentInventory(report, cli: currentCLI)
            agentStorageFootprints = footprints
            agentApplications = applications
            agentCLIBodySizes = bodies
            clearAgentSelection()
            agentCompletedCount = summary.removed
            agentReclaimedBytes = summary.reclaimedBytes
            agentCleanupProgress = nil
            agentApplying = false
            agentFeedbackID += 1
            if summary.removed > 0 {
                CleanupCache.invalidate()
                cleanupScanComplete = false
            }
            resampleAfterMutation()
            let remaining = Array(Set(summary.remainingPaths + remainingPlan.items.map(\.record))).sorted()
            let retained = Array(Set(summary.retainedPaths + remainingPlan.retainedPaths)).sorted()
            var details = agentRemovalDetails(messages: Array(Set(summary.messages + remainingPlan.messages)).sorted(),
                                              retained: retained)
            if !remaining.isEmpty { details += [l10n.t("agents.data.remaining")] + remaining }
            if !report.complete { details.append(l10n.t("log.scanPartial")) }
            let incomplete = summary.failed > 0 || summary.skipped > 0 || !remaining.isEmpty
                || !retained.isEmpty || !remainingPlan.messages.isEmpty || !report.complete
            agentOutcomeMood = incomplete ? .attention : .success
            agentOutcomeDetails = details
            agentStatus = l10n.tf(incomplete ? "agents.data.result.partial" : "agents.data.result.complete", summary.removed)
            log(agentStatus + (details.isEmpty ? "" : "\n" + details.joined(separator: "\n")))
            noteHeaderReaction(incomplete ? .attention : .success)
            if incomplete {
                // Recovery starts a new review; it cannot silently accept new
                // paths discovered after the original confirmation.
                let retry: () -> Void = { [weak self] in
                    self?.offerAgentCompleteRemoval(agentIDs: plan.agentIDs, programName: programName)
                }
                agentRetryAction = retry
                agentRetryAvailable = true
                presentAgentTaskFailure(details: details, recovery: retry)
            }
        }
    }

    private func agentRemovalDetails(messages: [String], retained: [String]) -> [String] {
        messages + (retained.isEmpty ? [] : [l10n.t("agents.data.retained")] + retained)
    }
}
