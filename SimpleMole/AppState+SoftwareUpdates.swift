import Foundation

@MainActor
extension AppState {
    /// Manual metadata-only checks. Never install software or run an upgrade.
    func checkSoftwareUpdates() {
        guard !isCheckingSoftwareUpdates, !isScanningApps, !isScanningCommandLineTools,
              !uninstallQueue.hasWork, commandLineToolBusyID == nil, softwareUpdatingID == nil else { return }
        let apps = uninstallSegment == 0 ? filteredApps : []
        let tools = uninstallSegment == 1 ? filteredCommandLineTools : []
        guard !apps.isEmpty || !tools.isEmpty else { return }
        let casks = apps.reduce(into: [String: String]()) { tokens, app in
            if let plan = uninstallPlan(for: app), plan.isBrewCask { tokens[app.id] = plan.caskToken }
        }
        let ids = Set(apps.map(SoftwareUpdateService.appKey) + tools.map(SoftwareUpdateService.toolKey))
        isCheckingSoftwareUpdates = true
        softwareUpdateCheckingIDs = ids
        let checker = softwareUpdateChecker
        Task {
            let targets = await Task.detached(priority: .utility) {
                apps.map { SoftwareUpdateService.appTarget($0, cask: casks[$0.id]) }
                    + tools.map(SoftwareUpdateService.toolTarget)
            }.value
            let results = await SoftwareUpdateCheckBatch.run(targets, using: checker)
            let currentIDs = Set(installedApps.map(SoftwareUpdateService.appKey)
                                 + commandLineTools.map(SoftwareUpdateService.toolKey))
            softwareUpdateResults.merge(results.filter { currentIDs.contains($0.key) }) { _, new in new }
            softwareUpdateCheckingIDs = []
            isCheckingSoftwareUpdates = false
        }
    }
}
