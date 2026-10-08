import Foundation

/// Coordinates a confirmed CLI removal without consulting desktop-app owners.
/// Installation identity and exact process ownership are checked again at the
/// mutation edge; low-level removers retain their own package/root validation.
@MainActor
enum CLIUninstallWorkflow {
    enum Result {
        case finished(CLIUninstallService.Outcome)
        case needsConfirmation(SoftwareUpdateProcesses.Probe)
        case failed(reasonKey: String)
    }

    struct Environment {
        var probe: @MainActor (SoftwareUpdateProcesses.Scope) async -> SoftwareUpdateProcesses.Probe
        var close: @MainActor (SoftwareUpdateProcesses.Scope, @escaping @MainActor () -> Bool) async -> Bool
        var remove: @MainActor (CommandLineTool, RunningApplicationSnapshot) async -> CLIUninstallService.Outcome
        var identity: @MainActor (String) -> String?

        static var live: Self {
            Self(probe: { scope in
                await Task.detached(priority: .utility) { SoftwareUpdateProcesses.probe(scope) }.value
            }, close: { scope, stillCurrent in
                await SoftwareUpdateProcesses.close(scope, stillCurrent: stillCurrent)
            }, remove: { tool, running in
                await Task.detached(priority: .utility) {
                    if let installation = tool.agentInstallation {
                        let result = AgentCLIService.uninstall(installation, home: NSHomeDirectory(), running: running)
                        return CLIUninstallService.Outcome(succeeded: result.succeeded,
                            messages: result.messages, reclaimedBytes: result.reclaimedBytes)
                    }
                    return CLIUninstallService.uninstall(tool, running: running)
                }.value
            }, identity: { DeletionPlan.identity(at: $0) })
        }
    }

    static func execute(_ tool: CommandLineTool, identity originalIdentity: String?,
                        mayClose: Bool, environment: Environment? = nil) async -> Result {
        let environment = environment ?? .live
        let scope = SoftwareUpdateProcesses.Scope.tool(tool)
        let stillCurrent: @MainActor () -> Bool = {
            guard !Task.isCancelled, let originalIdentity, !originalIdentity.isEmpty,
                  environment.identity(tool.path) == originalIdentity else { return false }
            guard let installation = tool.agentInstallation else { return true }
            return !installation.identities.isEmpty && installation.identities.allSatisfy {
                !$0.value.isEmpty && environment.identity($0.key) == $0.value
            }
        }
        guard stillCurrent() else { return .failed(reasonKey: "cli.uninstall.changed") }

        let initial = await environment.probe(scope)
        guard stillCurrent() else { return .failed(reasonKey: "cli.uninstall.changed") }
        guard initial.isComplete else { return .failed(reasonKey: "cli.uninstall.runtimeUnknown") }
        if !initial.processes.isEmpty {
            guard mayClose else { return .needsConfirmation(initial) }
            guard await environment.close(scope, stillCurrent) else {
                return .failed(reasonKey: stillCurrent() ? "cli.uninstall.closeFailed" : "cli.uninstall.changed")
            }
        }

        // A tool can start during confirmation, shutdown or an idle preflight.
        // A fresh process at this edge requires renewed confirmation.
        let final = await environment.probe(scope)
        guard stillCurrent() else { return .failed(reasonKey: "cli.uninstall.changed") }
        guard final.isComplete else { return .failed(reasonKey: "cli.uninstall.runtimeUnknown") }
        guard final.processes.isEmpty else { return .needsConfirmation(final) }

        // Only exact scoped ownership enters the lower-level process guard.
        // Including the global owner snapshot would confuse desktop apps with
        // their separately installed command-line tools.
        let running = RunningApplicationSnapshot(processNames: final.processes.map(\.name),
                                                  isComplete: final.isComplete)
        return .finished(await environment.remove(tool, running))
    }
}
