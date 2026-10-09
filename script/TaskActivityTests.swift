import Foundation

// State-only fixture: the task predicates below are compiled from production.
@MainActor final class AppState {
    final class Queue { var hasWork = false; var activeJob: UUID? }
    final class Simulator { var isDeleting = false }
    let uninstallQueue = Queue()
    let simulatorInventory = Simulator()
    var isScanning = false
    var isApplying = false
    var cleanupQueued = false
    var isAutoCleanupScanning = false
    var isAutoCleanupMutationActive = false
    var isSystemMaintenanceRunning = false
    var isAnalyzing = false
    var isScanningDuplicates = false
    var isSlimming = false
    var isDeletingDuplicates = false
    var isDeletingAnalysisFiles = false
    var isRefreshingAnalysisCache = false
    var agentScanning = false
    var agentApplying = false
    var agentProgramBusyID: String?
    var isScanningApps = false
    var isScanningCommandLineTools = false
    var isCheckingSoftwareUpdates = false
    var commandLineToolBusyID: String?
    var softwareUpdatingID: String?
    var isScanningEnv = false
    var isApplyingDevEnv = false
    var isRefreshingGc = false
    var gcRunningId: String?
    var isDeveloperCommandRunning = false
    var isDeveloperConfigurationWriting = false
    var isNetworkToolRunning = false
}

enum ProtectedOperation {
    case cleanupScan, deepCleanupScan, quickOptimize, developerToolsScan
    case previewAutoCleanup, runAutoCleanup, aiScan, installedAppsScan, uninstall
    case developmentEnvironmentScan, diskOverview
}

@main struct TaskActivityTests {
    @MainActor static func main() {
        let flags: [(ReferenceWritableKeyPath<AppState, Bool>, ProtectedOperation)] = [
            (\.isScanning, .cleanupScan), (\.isApplying, .cleanupScan),
            (\.cleanupQueued, .cleanupScan), (\.isAutoCleanupScanning, .cleanupScan),
            (\.isSystemMaintenanceRunning, .cleanupScan),
            (\.isAnalyzing, .diskOverview), (\.isScanningDuplicates, .diskOverview),
            (\.isSlimming, .diskOverview), (\.isDeletingDuplicates, .diskOverview),
            (\.isDeletingAnalysisFiles, .diskOverview), (\.isRefreshingAnalysisCache, .diskOverview),
            (\.agentScanning, .aiScan), (\.agentApplying, .aiScan),
            (\.isScanningApps, .installedAppsScan), (\.isScanningCommandLineTools, .installedAppsScan),
            (\.isCheckingSoftwareUpdates, .installedAppsScan),
            (\.isScanningEnv, .developmentEnvironmentScan), (\.isApplyingDevEnv, .developmentEnvironmentScan),
            (\.isRefreshingGc, .developmentEnvironmentScan),
            (\.isDeveloperCommandRunning, .developmentEnvironmentScan),
            (\.isDeveloperConfigurationWriting, .developmentEnvironmentScan),
            (\.isNetworkToolRunning, .developmentEnvironmentScan)
        ]
        for (flag, owner) in flags {
            let state = AppState()
            state[keyPath: flag] = true
            precondition(state.isBusy, "Restart safety must see every page's work")
            precondition(state.isTaskBusy(for: owner), "A task must prevent its own page's reentry")
            let pageFlags = [state.isCleanupTaskBusy, state.isAnalysisTaskBusy, state.isAgentTaskBusy,
                             state.isSoftwareTaskBusy, state.isDeveloperTaskBusy]
            precondition(pageFlags.filter { $0 }.count == 1,
                         "Work on one page must not block unrelated pages")
        }
        let state = AppState()
        state.isScanning = true
        precondition(!state.isUninstallMutationBlocked, "Read-only cleanup must not delay uninstall")
        state.isScanning = false
        state.cleanupQueued = true
        precondition(!state.isUninstallMutationBlocked, "Queued cleanup must not block its own resumption")
        state.cleanupQueued = false
        state.isApplying = true
        precondition(state.isUninstallMutationBlocked, "Deletions of overlapping app data must not race")
        state.isApplying = false
        state.uninstallQueue.hasWork = true
        precondition(state.isSoftwareTaskBusy && state.isBusy && !state.isCleanupTaskBusy)
        state.uninstallQueue.hasWork = false
        state.agentProgramBusyID = "agent-cli"
        precondition(state.isAgentTaskBusy && state.isUninstallMutationBlocked && !state.isSoftwareTaskBusy)
        precondition(state.isAgentMutationBusy && state.isCleanupMutationBlocked)
        state.agentProgramBusyID = nil
        state.commandLineToolBusyID = "software-cli"
        precondition(state.isSoftwareTaskBusy && state.isUninstallMutationBlocked && !state.isAgentTaskBusy)
        state.commandLineToolBusyID = nil
        state.softwareUpdatingID = "update"
        precondition(state.isSoftwareTaskBusy && state.isUninstallMutationBlocked && !state.isAgentTaskBusy)
        state.softwareUpdatingID = nil
        state.uninstallQueue.activeJob = UUID()
        precondition(state.isCleanupMutationBlocked, "An active uninstall must gate overlapping cleanup")
        state.uninstallQueue.activeJob = nil
        state.agentScanning = true
        state.isScanningApps = true
        precondition(!state.isCleanupMutationBlocked, "Read-only Agent/software scans must not gate cleanup")
        state.agentScanning = false
        state.isScanningApps = false
        state.isAutoCleanupScanning = true
        precondition(!state.isUninstallMutationBlocked && !state.isSoftwareMutationBlocked,
                     "Read-only automatic-cleanup preview must not block another page's mutation")
        state.isAutoCleanupMutationActive = true
        precondition(state.isUninstallMutationBlocked && state.isSoftwareMutationBlocked,
                     "Preparing or applying automatic cleanup must reserve the shared mutation gate")
        state.isAutoCleanupScanning = false
        state.isAutoCleanupMutationActive = false
        state.isSystemMaintenanceRunning = true
        precondition(!state.isUninstallMutationBlocked && !state.isSoftwareMutationBlocked,
                     "Read-only system-maintenance inspection must not acquire a mutation claim")
        state.isSystemMaintenanceRunning = false
        state.gcRunningId = "gc"
        precondition(state.isDeveloperTaskBusy && !state.isUninstallMutationBlocked)
        state.gcRunningId = nil
        state.simulatorInventory.isDeleting = true
        precondition(state.isDeveloperTaskBusy && !state.isCleanupTaskBusy)
        print("PASS: independent page activity, own reentry, restart safety and overlapping deletion guards")
    }
}
