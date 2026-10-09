import Foundation

@MainActor
extension AppState {
    // Entry points use their own page's activity. The aggregate is for app-wide
    // presentation and restart safety, not for scheduling unrelated work.
    var isCleanupTaskBusy: Bool {
        isScanning || isApplying || cleanupQueued || isAutoCleanupScanning || isSystemMaintenanceRunning
    }

    var isAnalysisTaskBusy: Bool {
        isAnalyzing || isScanningDuplicates || isSlimming || isDeletingDuplicates
            || isDeletingAnalysisFiles || isRefreshingAnalysisCache
    }

    var isAgentTaskBusy: Bool {
        agentScanning || agentApplying || agentProgramBusyID != nil
    }

    var isSoftwareTaskBusy: Bool {
        uninstallQueue.hasWork || isScanningApps || isScanningCommandLineTools
            || isCheckingSoftwareUpdates || commandLineToolBusyID != nil || softwareUpdatingID != nil
    }

    var isDeveloperTaskBusy: Bool {
        isScanningEnv || isApplyingDevEnv || isRefreshingGc || gcRunningId != nil
            || isDeveloperCommandRunning || isDeveloperConfigurationWriting
            || isNetworkToolRunning || simulatorInventory.isDeleting
    }

    // Cleanup and uninstall can remove the same application data. Read-only
    // scans and unrelated page activity do not participate in this boundary.
    var isCleanupMutationBusy: Bool {
        isApplying || isAutoCleanupMutationActive
    }

    var isAgentMutationBusy: Bool {
        agentApplying || agentProgramBusyID != nil
    }

    /// Mutations outside the cleanup page can share the same application data.
    /// Inventory discovery and page-local selection do not acquire this gate.
    var isCleanupMutationBlocked: Bool {
        uninstallQueue.activeJob != nil || isCleanupSubmissionBlocked
    }

    var isCleanupSubmissionBlocked: Bool {
        isAgentMutationBusy || commandLineToolBusyID != nil || softwareUpdatingID != nil
    }

    var isSoftwareMutationBlocked: Bool {
        isCleanupMutationBusy || isAgentMutationBusy
    }

    var isUninstallMutationBlocked: Bool {
        isCleanupMutationBusy || isAgentMutationBusy
            || commandLineToolBusyID != nil || softwareUpdatingID != nil
    }

    var isBusy: Bool {
        isCleanupTaskBusy || isAnalysisTaskBusy || isAgentTaskBusy
            || isSoftwareTaskBusy || isDeveloperTaskBusy
    }

    func isTaskBusy(for operation: ProtectedOperation) -> Bool {
        switch operation {
        case .cleanupScan, .deepCleanupScan, .quickOptimize, .developerToolsScan,
             .previewAutoCleanup, .runAutoCleanup: return isCleanupTaskBusy
        case .aiScan: return isAgentTaskBusy
        case .installedAppsScan, .uninstall: return isSoftwareTaskBusy
        case .developmentEnvironmentScan: return isDeveloperTaskBusy
        case .diskOverview: return isAnalysisTaskBusy
        }
    }
}
