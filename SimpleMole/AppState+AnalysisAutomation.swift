import Foundation

@MainActor
extension AppState {
    /// Manual scans share the retry clock so cancelling a scan cannot immediately
    /// restart the same category through its automatic completion hook.
    func noteAnalysisScanAttempt(for mode: AnalyzeMode) {
        analysisAutoScanPreferences.noteAttempt(for: mode, at: Date())
        analysisAutoScanPreferences.save()
    }

    /// Called at startup, hourly, and when a scan finishes. Each invocation starts
    /// at most one category so foreground work and other scheduled tasks take priority.
    /// Completion checks the remaining categories again, without changing the sidebar selection.
    func runScheduledAnalysisScans(force: Bool = false) {
        guard !isAnalysisTaskBusy, !isAnalyzing, !isScanningDuplicates, !isDeletingAnalysisFiles,
              analyzingMode == nil else { return }

        let now = Date()
        // A restored home-only cache remains immediately usable. Expand it
        // once through the incremental worker rather than waiting for its
        // normal interval; the same attempt clock still limits failed retries.
        let diskNeedsScopeExpansion = analysisInventoryCache.restore()[.disk].map { snapshot in
            let required = AnalysisInventoryWorker.defaultRoots(home: snapshot.home, kind: .disk)
            return !Set(snapshot.roots).isSuperset(of: required)
        } ?? false
        let dueModes = AnalyzeMode.menuOrder.filter { mode in
            analysisHasScanned(mode)
                && analysisAutoScanPreferences.isDue(mode, lastScanAt: analysisScanDate(for: mode),
                    now: now, force: force || (mode == .disk && diskNeedsScopeExpansion))
        }.sorted { lhs, rhs in
            let left = analysisScanDate(for: lhs) ?? .distantPast
            let right = analysisScanDate(for: rhs) ?? .distantPast
            return left < right
        }
        guard let mode = dueModes.first else { return }

        // Checking permissions must never open a consent dialog from background work.
        permissionCenter.refresh()
        guard permissionCenter.fullDiskAccessGranted else { return }
        noteAnalysisScanAttempt(for: mode)
        scanAnalysisMode(mode, forceFull: false)
    }
}
