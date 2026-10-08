import Foundation

@MainActor
final class AppState {
    enum Page { case devenv, cleanup }
    final class Permissions {
        var fullDiskAccessGranted = true
        func refresh() {}
    }
    var devWorkspaceRefreshToken = 0
    var developerWorkspaceRefreshTask: Task<Void, Never>?
    var devWorkspaceRefreshPending = false
    let permissionCenter = Permissions()
    var isDeveloperTaskBusy = false
    var otherTabBusy = false
    var selectedTab = 0
    var visiblePages: [Page] = [.devenv, .cleanup]
    var runtimeScans = 0
    var cacheScans = 0
    func scanDevEnv(announce: Bool, presentingPermissionCenter: Bool, notifyingUser: Bool) {
        precondition(!announce && !presentingPermissionCenter)
        precondition(notifyingUser)
        runtimeScans += 1
    }
    func scanGc(force: Bool, notifyingUser: Bool) {
        precondition(force)
        precondition(notifyingUser)
        cacheScans += 1
    }
}

@main
struct DeveloperWorkspaceRefreshTests {
    @MainActor static func main() async throws {
        let immediate = AppState()
        immediate.otherTabBusy = true
        immediate.refreshDeveloperWorkspace()
        precondition(immediate.runtimeScans == 1 && immediate.cacheScans == 1)

        let pending = AppState()
        pending.isDeveloperTaskBusy = true
        pending.refreshDeveloperWorkspace()
        precondition(pending.runtimeScans == 0 && pending.devWorkspaceRefreshPending)
        try await Task.sleep(nanoseconds: 30_000_000)
        pending.isDeveloperTaskBusy = false
        try await Task.sleep(nanoseconds: 400_000_000)
        precondition(pending.runtimeScans == 1 && !pending.devWorkspaceRefreshPending)
        precondition(pending.developerWorkspaceRefreshTask == nil)

        let left = AppState()
        left.isDeveloperTaskBusy = true
        left.refreshDeveloperWorkspace()
        left.selectedTab = 1
        left.isDeveloperTaskBusy = false
        try await Task.sleep(nanoseconds: 400_000_000)
        precondition(left.runtimeScans == 0, "Leaving the workbench must cancel a queued scan")

        let reentered = AppState()
        reentered.isDeveloperTaskBusy = true
        reentered.refreshDeveloperWorkspace()
        reentered.refreshDeveloperWorkspace()
        reentered.isDeveloperTaskBusy = false
        try await Task.sleep(nanoseconds: 400_000_000)
        precondition(reentered.runtimeScans == 1 && reentered.devWorkspaceRefreshToken == 2,
                     "Only the latest pending visit should scan")

        let denied = AppState()
        denied.permissionCenter.fullDiskAccessGranted = false
        denied.refreshDeveloperWorkspace()
        precondition(denied.runtimeScans == 1 && denied.devWorkspaceRefreshToken == 1,
                     "Ordinary runtime roots refresh without requesting full disk access")
        print("Developer workspace: immediate, deferred, cancelled, coalesced, and permission-safe refresh passed")
    }
}
