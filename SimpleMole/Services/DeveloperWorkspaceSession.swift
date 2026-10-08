import Foundation

/// App-owned models retain pending commands and drafts across page switches.
@MainActor
final class DeveloperWorkspaceSession {
    let workspace = DeveloperWorkspaceModel()
    let shell = DeveloperShellModel()
    let network = DeveloperNetworkModel()
    let networkTools = DeveloperNetworkToolsModel()
    let cli = DeveloperCLIModel()
    let ssh = DeveloperSSHGitModel()
    private var shellRevision = 0

    init(state: AppState) {
        workspace.attach(state: state)
        shell.canWrite = { [weak state] in state?.isDeveloperTaskBusy == false }
        shell.savingStateChanged = { [weak self, weak state] saving in
            guard let self, let state else { return }
            if saving {
                state.isDeveloperConfigurationWriting = true
            } else if self.shell.revision == self.shellRevision {
                state.isDeveloperConfigurationWriting = false
            } else {
                self.shellRevision = self.shell.revision
                // Keep the global write lock until the environment is current.
                Task { [weak self, weak state] in
                    guard let self else {
                        state?.isDeveloperConfigurationWriting = false
                        return
                    }
                    await DeveloperTerminalEnvironmentService.shared.invalidate()
                    await self.workspace.refresh(forceEnvironment: true)
                    self.workspace.didChangeEnvironment()
                    state?.isDeveloperConfigurationWriting = false
                }
            }
        }
    }
}
