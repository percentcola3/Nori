import Foundation

/// 软件页「命令行工具」：Homebrew / npm / pnpm / pipx / uv / cargo / go 安装的工具。
/// Agent 的 CLI 与此处是同一条记录；它的数据仍在 Agent 页处理。
@MainActor
extension AppState {
    var filteredCommandLineTools: [CommandLineTool] {
        let needle = uninstallSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return commandLineTools }
        return commandLineTools.filter {
            $0.name.lowercased().contains(needle) || $0.manager.displayName.lowercased().contains(needle)
                || ($0.installationSource?.lowercased().contains(needle) ?? false)
                || ($0.agentInstallation?.name.lowercased().contains(needle) ?? false)
        }
    }

    func scanCommandLineTools(force: Bool = false) {
        guard !isScanningCommandLineTools, commandLineToolBusyID == nil, softwareUpdatingID == nil,
              confirmation == nil, force || !commandLineToolsScanned else { return }
        commandLineToolUninstallGeneration = UUID()
        isScanningCommandLineTools = true
        commandLineToolStatus = L10n.shared.t("cli.status.scanning")
        let home = NSHomeDirectory()
        Task {
            let tools = await Task.detached(priority: .utility) {
                CommandLineToolInventory.scan(home: home)
            }.value
            commandLineTools = tools
            softwareUpdateResults = softwareUpdateResults.filter { !$0.key.hasPrefix("cli:") }
            commandLineToolsScanned = true
            isScanningCommandLineTools = false
            commandLineToolStatus = tools.isEmpty ? L10n.shared.t("cli.status.none")
                : L10n.shared.tf("cli.status.count", tools.count, ByteFormat.format(tools.reduce(0) { $0 &+ $1.bytes }))
            ensureAgentStorageFootprints(for: Set(tools.compactMap(\.agentID)))
        }
    }

    func uninstallCommandLineTool(_ tool: CommandLineTool) {
        guard !isSoftwareTaskBusy else { return }
        if tool.agentInstallation != nil {
            uninstallAgentTool(tool)
            return
        }
        guard !isSoftwareMutationBlocked,
              confirmation == nil, taskNotice == nil, tool.canUninstall,
              commandLineTools.contains(tool) else { return }
        let generation = UUID()
        commandLineToolUninstallGeneration = generation
        let identity = DeletionPlan.identity(at: tool.path)
        commandLineToolBusyID = tool.id
        commandLineToolStatus = l10n.tf("cli.status.checkingProcesses", tool.name)
        Task {
            let processes = await Task.detached(priority: .utility) {
                SoftwareUpdateProcesses.probe(.tool(tool))
            }.value
            guard commandLineToolUninstallGeneration == generation else { return }
            commandLineToolBusyID = nil
            refreshCommandLineToolStatus()
            guard commandLineTools.contains(tool), confirmation == nil, taskNotice == nil else { return }
            guard processes.isComplete else {
                presentTaskFailure(message: l10n.tf("cli.status.failed", tool.name),
                                   details: [l10n.t("cli.uninstall.runtimeUnknown")], detailsAreLocalized: true)
                return
            }
            presentCommandLineToolUninstallConfirmation(tool, identity: identity,
                                                       generation: generation, processes: processes)
        }
    }

    private func presentCommandLineToolUninstallConfirmation(_ tool: CommandLineTool, identity: String?,
                                                             generation: UUID,
                                                             processes: SoftwareUpdateProcesses.Probe) {
        let isRunning = !processes.processes.isEmpty
        var message = l10n.tf(tool.agentID == nil ? "cli.uninstall.confirm.message" : "cli.uninstall.confirm.agentMessage",
                              tool.installationSource ?? tool.manager.displayName, tool.path)
        if isRunning {
            message += "\n\n" + l10n.tf("cli.uninstall.confirm.running", tool.name)
                + "\n" + Set(processes.processes.map(\.name)).sorted().joined(separator: ", ")
        }
        confirmation = Confirmation(title: l10n.tf("cli.uninstall.confirm.title", tool.name), message: message,
            confirmLabel: l10n.t(isRunning ? "cli.uninstall.confirm.closeAction" : "uninstall.action")) { [weak self] in
                guard let self, self.commandLineToolUninstallGeneration == generation,
                      !self.isSoftwareTaskBusy, !self.isSoftwareMutationBlocked,
                      !self.isCheckingSoftwareUpdates, !self.isScanningCommandLineTools,
                      self.commandLineTools.contains(tool) else { return }
                self.commandLineToolBusyID = tool.id
                self.commandLineToolStatus = self.l10n.tf("cli.status.uninstalling", tool.name)
                Task { await self.performCommandLineToolUninstall(tool, identity: identity,
                                                                  generation: generation, mayClose: isRunning) }
            }
    }

    private func performCommandLineToolUninstall(_ tool: CommandLineTool, identity: String?,
                                                generation: UUID, mayClose: Bool) async {
        let result = await CLIUninstallWorkflow.execute(tool, identity: identity, mayClose: mayClose)
        guard commandLineToolUninstallGeneration == generation else { return }
        commandLineToolBusyID = nil
        switch result {
        case .needsConfirmation(let processes):
            presentCommandLineToolUninstallConfirmation(tool, identity: identity,
                                                       generation: generation, processes: processes)
        case .failed(let reasonKey):
            presentTaskFailure(message: l10n.tf("cli.status.failed", tool.name),
                               details: [l10n.t(reasonKey)], detailsAreLocalized: true)
        case .finished(let outcome):
            if outcome.succeeded {
                commandLineTools.removeAll { $0.id == tool.id }
                softwareUpdateResults.removeValue(forKey: SoftwareUpdateService.toolKey(tool))
                if tool.agentID != nil { agentHasScanned = false }
                resampleAfterMutation()
            } else {
                presentTaskFailure(message: l10n.tf("cli.status.failed", tool.name),
                                   details: outcome.messages.filter { !$0.isEmpty })
            }
            if !outcome.messages.isEmpty { log(outcome.messages.joined(separator: "\n")) }
        }
        refreshCommandLineToolStatus()
    }

    private func refreshCommandLineToolStatus() {
        commandLineToolStatus = l10n.tf("cli.status.count", commandLineTools.count,
            ByteFormat.format(commandLineTools.reduce(0) { $0 &+ $1.bytes }))
    }
}
