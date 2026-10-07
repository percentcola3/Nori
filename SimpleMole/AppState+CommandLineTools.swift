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
        guard !isScanningCommandLineTools, force || !commandLineToolsScanned else { return }
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
        }
    }

    func uninstallCommandLineTool(_ tool: CommandLineTool) {
        guard commandLineToolBusyID == nil, !isBusy, tool.canUninstall,
              commandLineTools.contains(tool) else { return }
        commandLineToolBusyID = tool.id
        commandLineToolStatus = L10n.shared.tf("cli.status.uninstalling", tool.name)
        let home = NSHomeDirectory()
        let agentInstallation = tool.agentInstallation ?? tool.agentInstallationID.flatMap { id in
            agentCLIInstallations.first { $0.id == id }
        }
        Task {
            let snapshot = await captureRunningApplicationSnapshot()
            let outcome: CommandLineToolInventory.Outcome = await Task.detached(priority: .utility) {
                if let agentInstallation {
                    let result = AgentCLIService.uninstall(agentInstallation, home: home, running: snapshot)
                    return .init(succeeded: result.succeeded, messages: result.messages,
                                 reclaimedBytes: result.reclaimedBytes)
                }
                return CommandLineToolInventory.uninstall(tool, home: home, running: snapshot)
            }.value
            commandLineToolBusyID = nil
            if outcome.succeeded {
                commandLineTools.removeAll { $0.id == tool.id }
                if tool.agentID != nil { agentHasScanned = false }
                resampleAfterMutation()
            } else {
                presentTaskFailure(message: L10n.shared.tf("cli.status.failed", tool.name),
                                   details: outcome.messages.filter { !$0.isEmpty })
            }
            if !outcome.messages.isEmpty { log(outcome.messages.joined(separator: "\n")) }
            commandLineToolStatus = L10n.shared.tf("cli.status.count", commandLineTools.count,
                ByteFormat.format(commandLineTools.reduce(0) { $0 &+ $1.bytes }))
        }
    }
}
