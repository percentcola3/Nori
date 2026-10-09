import Foundation

private enum AgentProgramSelection {
    case cli(AgentCLIInstallation)
    case app(UninstallApp)

    var name: String { switch self { case .cli(let item): return item.name; case .app(let item): return item.name } }
    var key: String { switch self { case .cli(let item): return item.id; case .app(let item): return item.id } }
    var path: String { switch self { case .cli(let item): return item.managedPaths.first ?? item.executablePaths.first ?? ""; case .app(let item): return item.path } }
    var agentIDs: Set<String> { switch self { case .cli(let item): return [item.agentID]; case .app(let item): return AgentSoftwareInventory.agentIDs(for: item) } }
}

@MainActor
extension AppState {
    func uninstallAgentCLI(_ installation: AgentCLIInstallation) {
        guard agentCLIInstallations.contains(installation) else { return }
        requestAgentProgramRemoval(.cli(installation))
    }

    func uninstallAgentApplication(_ app: UninstallApp) {
        guard agentApplications.values.contains(where: { $0.contains(app) }) else { return }
        requestAgentProgramRemoval(.app(app))
    }

    /// The software CLI row and the Agent row share the same removal flow.
    func uninstallAgentTool(_ tool: CommandLineTool) {
        guard commandLineTools.contains(tool), let installation = tool.agentInstallation else { return }
        requestAgentProgramRemoval(.cli(installation))
    }

    private func requestAgentProgramRemoval(_ selection: AgentProgramSelection) {
        guard !isAgentTaskBusy, !isCleanupMutationBusy, uninstallQueue.activeJob == nil,
              commandLineToolBusyID == nil, softwareUpdatingID == nil,
              confirmation == nil, taskNotice == nil, agentProgramIsAvailable(selection) else { return }
        if case .app(let app) = selection {
            guard !uninstallQueue.containsPendingOrActive(app) else { return }
        }
        let identity = DeletionPlan.identity(at: selection.path)
        agentProgramBusyID = selection.key
        Task {
            let processes = await Task.detached(priority: .utility) {
                switch selection {
                case .cli(let installation):
                    return SoftwareUpdateProcesses.probe(.tool(AgentSoftwareInventory.commandLineTool(for: installation)))
                case .app(let app):
                    let snapshot = ProcessSampler.shared.snapshot()
                    return SoftwareUpdateProcesses.Probe(
                        processes: UninstallProcessController.processes(for: app, samples: snapshot.processes),
                        isComplete: snapshot.isComplete)
                }
            }.value
            agentProgramBusyID = nil
            guard agentProgramIsAvailable(selection), confirmation == nil, taskNotice == nil else { return }
            guard processes.isComplete else {
                presentTaskFailure(message: l10n.tf("cli.status.failed", selection.name),
                    details: [l10n.t("cli.uninstall.runtimeUnknown")], detailsAreLocalized: true)
                return
            }
            showAgentProgramRemovalConfirmation(selection, identity: identity, processes: processes)
        }
    }

    private func showAgentProgramRemovalConfirmation(_ selection: AgentProgramSelection, identity: String?,
                                                     processes: SoftwareUpdateProcesses.Probe) {
        var message = l10n.tf("agents.program.confirm.message", selection.path)
        let running = !processes.processes.isEmpty
        if running {
            message += "\n\n" + l10n.tf("cli.uninstall.confirm.running", selection.name)
                + "\n" + Set(processes.processes.map(\.name)).sorted().joined(separator: ", ")
        }
        confirmation = Confirmation(title: l10n.tf("cli.uninstall.confirm.title", selection.name),
            message: message, confirmLabel: l10n.t(running ? "cli.uninstall.confirm.closeAction" : "uninstall.action")) { [weak self] in
                guard let self, !self.isAgentTaskBusy, !self.isCleanupMutationBusy,
                      self.uninstallQueue.activeJob == nil, self.commandLineToolBusyID == nil,
                      self.softwareUpdatingID == nil,
                      self.agentProgramIsAvailable(selection) else { return }
                if case .app(let app) = selection {
                    guard !self.uninstallQueue.containsPendingOrActive(app) else { return }
                }
                self.agentProgramBusyID = selection.key
                Task { await self.performAgentProgramRemoval(selection, identity: identity, mayClose: running) }
            }
    }

    private func agentProgramIsAvailable(_ selection: AgentProgramSelection) -> Bool {
        switch selection {
        case .cli(let installation):
            return agentCLIInstallations.contains(installation)
                || commandLineTools.contains { $0.agentInstallation == installation }
        case .app(let app):
            return agentApplications.values.contains { $0.contains(app) } || installedApps.contains(app)
        }
    }

    private func performAgentProgramRemoval(_ selection: AgentProgramSelection, identity: String?, mayClose: Bool) async {
        let succeeded: Bool
        switch selection {
        case .cli(let installation):
            let result = await CLIUninstallWorkflow.execute(AgentSoftwareInventory.commandLineTool(for: installation),
                identity: identity, mayClose: mayClose)
            switch result {
            case .needsConfirmation(let processes):
                agentProgramBusyID = nil
                showAgentProgramRemovalConfirmation(selection, identity: identity, processes: processes)
                return
            case .failed(let reason):
                presentTaskFailure(message: l10n.tf("cli.status.failed", selection.name),
                    details: [l10n.t(reason)], detailsAreLocalized: true)
                succeeded = false
            case .finished(let outcome):
                succeeded = outcome.succeeded
                if !succeeded { presentTaskFailure(message: l10n.tf("cli.status.failed", selection.name), details: outcome.messages) }
                if !outcome.messages.isEmpty { log(outcome.messages.joined(separator: "\n")) }
            }
            if succeeded {
                agentCLIInstallations.removeAll { $0.id == installation.id }
                commandLineTools.removeAll { $0.agentInstallation?.id == installation.id }
                commandLineToolStatus = l10n.tf("cli.status.count", commandLineTools.count,
                    ByteFormat.format(commandLineTools.reduce(0) { $0 &+ $1.bytes }))
            }
        case .app(let app):
            let result = await executeAgentApplicationRemoval(app, progress: { _ in })
            switch result {
            case .applied(let summary):
                succeeded = summary.succeeded && summary.removedPaths.contains(app.path)
                if !succeeded { presentTaskFailure(message: l10n.tf("cli.status.failed", app.name), details: summary.messages) }
            case .processesCouldNotStop:
                succeeded = false
                presentTaskFailure(message: l10n.tf("cli.status.failed", app.name),
                    details: [l10n.t("uninstall.reason.stop")], detailsAreLocalized: true)
            case .planUnavailable:
                succeeded = false
                presentTaskFailure(message: l10n.tf("cli.status.failed", app.name),
                    details: [l10n.t("cli.uninstall.changed")], detailsAreLocalized: true)
            }
            if succeeded {
                installedApps.removeAll { $0.id == app.id }
                for id in Array(agentApplications.keys) { agentApplications[id]?.removeAll { $0.id == app.id } }
            }
        }
        agentProgramBusyID = nil
        guard succeeded else { return }
        softwareUpdateResults = softwareUpdateResults.filter { key, _ in !key.contains(selection.path) }
        invalidateAgentStorageFootprints()
        CleanupCache.invalidate()
        cleanupScanComplete = false
        resampleAfterMutation()
        offerAgentAssociatedDataCleanup(agentIDs: selection.agentIDs, programName: selection.name)
    }
}
