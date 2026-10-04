import Darwin
import Foundation

@main
struct DuplicateWorkspaceTests {
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else {
            FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
            exit(1)
        }
    }

    @MainActor
    static func waitForScan(_ state: AppState) async throws {
        let deadline = Date().addingTimeInterval(20)
        while state.isScanningDuplicates, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        expect(!state.isScanningDuplicates, "fixture scan must finish promptly")
        expect(!state.analysisScanIsFull && !state.isIncrementalAnalysisScanning,
               "completed, failed and cancelled scans must clear their presentation state")
    }

    @MainActor
    static func main() async throws {
        let home = URL(fileURLWithPath: CommandLine.arguments[1]).standardized
        let root = home.appendingPathComponent("Documents")
        let archive = home.appendingPathComponent("Archive")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for index in 0..<3 {
            try Data(repeating: 23, count: 256 * 1_024).write(to: root.appendingPathComponent("copy-\(index).dat"))
        }
        let state = AppState(directory: archive, home: home.path)
        state.isAnalyzing = true
        state.beginDuplicateScan(roots: [root.path], home: home.path, forceFull: true)
        expect(!state.isScanningDuplicates && state.duplicateScanControl == nil
               && !state.analysisScanIsFull && state.isIncrementalAnalysisScanning,
               "an active inventory scan must block duplicate scans without changing its incremental presentation")
        state.isAnalyzing = false
        state.beginDuplicateScan(roots: [root.path], home: home.path)
        expect(state.analysisScanIsFull && !state.isIncrementalAnalysisScanning,
               "an initial scan must use the full-scan presentation without an explicit force flag")
        try await waitForScan(state)
        expect(state.duplicateScanFinished && state.duplicateGroups.count == 1
               && state.duplicateSelection.count == 2 && state.scheduledRuns == 1,
               "a successful production state scan must commit its result and continue scheduled tasks")
        let scannedAt = state.duplicateLastScanDate
        state.deselectAllDuplicates()
        let chosen = state.duplicateGroups[0].members[0]
        state.toggleDuplicateSelection(chosen)
        let selected = state.duplicateSelection
        let members = state.duplicateGroups[0].members.map(\.path)
        state.setDuplicateMode(.similarImages)
        expect(!state.duplicateScanFinished && state.duplicateGroups.isEmpty && state.duplicateLastScanDate == nil,
               "an unscanned submode must start with its own placeholder")
        state.beginDuplicateScan(roots: [root.path], home: home.path)
        expect(state.analysisScanIsFull && !state.isIncrementalAnalysisScanning,
               "an unscanned duplicate submode must also present as a full scan")
        try await waitForScan(state)
        expect(state.duplicateScanFinished && state.duplicateGroups.isEmpty,
               "a completed empty image result must still be reusable")
        state.setDuplicateMode(.exact)
        expect(state.duplicateGroups[0].members.map(\.path) == members
               && state.duplicateSelection == selected && state.duplicateLastScanDate == scannedAt,
               "submode switches must restore groups, review choices and last scan time")

        state.beginDuplicateScan(roots: [root.path], home: home.path)
        expect(!state.analysisScanIsFull && state.isIncrementalAnalysisScanning,
               "a cached rescan without the force flag must use incremental presentation")
        expect(state.duplicateGroups[0].members.map(\.path) == members && state.duplicateScanFinished,
               "re-scanning must keep the completed list visible while discovery runs")
        state.cancelDuplicateScan()
        try await waitForScan(state)
        expect(state.duplicateGroups[0].members.map(\.path) == members
               && state.duplicateSelection == selected && state.duplicateLastScanDate == scannedAt
               && state.scheduledRuns == 3,
               "cancellation must preserve prior results and continue the automatic queue")
        state.beginDuplicateScan(roots: [home.appendingPathComponent("Library").path], home: home.path, forceFull: true)
        expect(state.analysisScanIsFull && !state.isIncrementalAnalysisScanning,
               "a forced scan must use full-scan presentation even when prior results remain cached")
        try await waitForScan(state)
        expect(state.duplicateGroups[0].members.map(\.path) == members
               && state.duplicateSelection == selected && state.duplicateLastScanDate == scannedAt
               && state.scheduledRuns == 4 && !state.failures.isEmpty,
               "a failed rescan must retain the last completed workspace and resume queued work")

        let fresh = AppState(directory: home.appendingPathComponent("FreshArchive"), home: home.path)
        fresh.beginDuplicateScan(roots: [home.appendingPathComponent("Library").path], home: home.path)
        try await waitForScan(fresh)
        expect(!fresh.duplicateScanFinished && fresh.duplicateLastScanDate == nil,
               "a failed first scan must retain an unscanned workspace")

        state.selectAllDuplicates()
        expect(state.duplicateSelection.count == 2,
               "select-all must select all extra copies and preserve one keeper")
        state.refreshAnalysisAfterMutation(removedPaths: [chosen.path])
        expect(state.duplicateGroups[0].members.count == 2 && state.duplicateResultCache[.exact]?.snapshot.scanned == 2
               && state.duplicateScanFinished && state.duplicateLastScanDate == scannedAt,
               "known cleanup must patch groups and counts without changing the completed scan time")
        expect(state.duplicateGroups.allSatisfy { group in
            group.members.contains { !state.duplicateSelection.contains($0.path) }
        }, "a mutation must retain at least one copy in every surviving group")
        let unchanged = state.duplicateGroups[0].members[0].file
        let store = state.duplicateWorkspaceStore
        await Task.detached { store.flush() }.value
        let restored = AppState(directory: archive, home: home.path)
        restored.restorePersistedDuplicateResults()
        let deadline = Date().addingTimeInterval(10)
        while restored.duplicateResultCache.count < 2, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        expect(restored.duplicateScanFinished && restored.duplicateResultCache.count == 2
               && restored.duplicateGroups[0].members.map(\.path) == state.duplicateGroups[0].members.map(\.path)
               && restored.duplicateSelection == state.duplicateSelection && restored.duplicateLastScanDate == scannedAt,
               "a fresh production state must restore both submode results and review choices from disk")
        expect(restored.duplicateContentCache.digest(for: unchanged, sample: false) == unchanged.sha256,
               "verified complete digests must also survive an app restart")
        restored.setDuplicateMode(.similarImages)
        expect(restored.duplicateScanFinished && restored.duplicateGroups.isEmpty,
               "persisted completed-empty submodes must avoid another automatic scan on selection")
        let racedRestore = AppState(directory: archive, home: home.path)
        racedRestore.restorePersistedDuplicateResults()
        racedRestore.refreshAnalysisAfterMutation(removedPaths: [unchanged.path])
        try await Task.sleep(nanoseconds: 300_000_000)
        expect(racedRestore.duplicateResultCache.isEmpty && !racedRestore.duplicateScanFinished,
               "a late disk restore must not resurrect results invalidated by a known concurrent cleanup")
        print("Duplicate workspace: mode reuse, preserved cancellation/failure, scheduler continuation, incremental cleanup, keep-one selection and persistent restart reuse passed")
    }
}
