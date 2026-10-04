import Combine
import Foundation

enum AnalyzeMode { case duplicates }

// Production AppState+Duplicates.swift is compiled unchanged against this fixture.
// Operations are confined to generated roots; no application watchers are launched.
@MainActor
final class AppState: ObservableObject {
    final class Permissions { var fullDiskAccessGranted = true }
    let permissionCenter = Permissions()
    @Published var duplicateMode: DuplicateMode = .exact
    @Published var duplicateGroups: [DuplicateFileGroup] = []
    @Published var duplicateSelection: Set<String> = []
    @Published var isAnalyzing = false
    @Published var analysisScanIsFull = false
    @Published var isScanningDuplicates = false
    @Published var isDeletingDuplicates = false
    @Published var duplicateStatus = ""
    @Published var duplicateCoverage = ""
    @Published var duplicateScanFinished = false
    @Published var duplicateLastScanDate: Date?
    var duplicateScanControl: DuplicateScanControl?
    var duplicateScannedRoots: [String] = []
    let duplicateScanProgress = DuplicateScanProgressStore()
    var duplicateScanReclaimableBytes: UInt64 = 0
    var duplicateResultCache: [DuplicateMode: DuplicateCachedResult] = [:]
    let duplicateContentCache = DuplicateContentCache()
    let similarImageFeatureCache = SimilarImageFeatureCache()
    let duplicateWorkspaceStore: DuplicateWorkspaceStore
    var scheduledRuns = 0
    var failures: [String] = []
    var isBusy: Bool { isScanningDuplicates || isDeletingDuplicates }
    var isIncrementalAnalysisScanning: Bool {
        (isAnalyzing || isScanningDuplicates) && !analysisScanIsFull
    }

    init(directory: URL, home: String) {
        duplicateWorkspaceStore = DuplicateWorkspaceStore(directory: directory, home: home)
    }
    func presentTaskFailure(message: String, details: [String] = []) { failures.append(message) }
    func log(_ message: String) {}
    func runScheduledAnalysisScans() { scheduledRuns += 1 }
    func noteAnalysisScanAttempt(for mode: AnalyzeMode) {}
    func refreshAnalysisAfterMutation(removedPaths: Set<String>, changedPaths: Set<String> = []) {
        refreshDuplicateResultsAfterMutation(removedPaths: removedPaths, changedPaths: changedPaths)
    }
    func resampleAfterMutation() {}
}

final class NativeCore: @unchecked Sendable {
    static let shared = NativeCore()
    struct ApplySummary: Sendable {
        var removed = 0
        var skipped = 0
        var failed = 0
        var messages: [String] = []
        var removedPaths: Set<String> = []
    }
    func loadWhitelist(homeDirectory: String) -> [String] { [] }
    func matchesWhitelist(_ path: String, entries: [String]) -> Bool { false }
    func applyCleanup(items: [DeletionPlan.Item], permanent: Bool, allowedRoots: [String],
                      finalValidation: (String) -> Bool) -> ApplySummary { .init() }
}
