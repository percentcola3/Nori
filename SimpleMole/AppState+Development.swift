import Foundation

@MainActor
extension AppState {
    /// Navigation refreshes read-only inventories; edits and repairs have their own actions.
    func refreshDeveloperWorkspace() {
        devWorkspaceRefreshToken &+= 1
        developerWorkspaceRefreshTask?.cancel()
        developerWorkspaceRefreshTask = nil
        devWorkspaceRefreshPending = false
        permissionCenter.refresh()
        if permissionCenter.fullDiskAccessGranted {
            if isBusy {
                devWorkspaceRefreshPending = true
                developerWorkspaceRefreshTask = Task { [weak self] in
                    guard let self else { return }
                    while self.isBusy {
                        guard !Task.isCancelled, self.isDeveloperWorkspaceVisible else { return }
                        do { try await Task.sleep(nanoseconds: 300_000_000) }
                        catch { return }
                    }
                    guard !Task.isCancelled, self.isDeveloperWorkspaceVisible else { return }
                    self.devWorkspaceRefreshPending = false
                    self.developerWorkspaceRefreshTask = nil
                    self.scanDevEnv(announce: false, presentingPermissionCenter: false)
                    self.scanGc(force: true)
                }
            } else {
                scanDevEnv(announce: false, presentingPermissionCenter: false)
            }
        }
        scanGc(force: true)
    }

    private var isDeveloperWorkspaceVisible: Bool {
        visiblePages.indices.contains(selectedTab) && visiblePages[selectedTab] == .devenv
    }
}
