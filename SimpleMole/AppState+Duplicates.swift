import AppKit
import Foundation

@MainActor
extension AppState {
    var duplicateSelectedCount: Int { duplicateSelection.count }
    var duplicateSelectedBytes: UInt64 {
        guard !duplicateSelection.isEmpty else { return 0 }
        return duplicateGroups.reduce(0) { total, group in
            total + group.members.reduce(0) { $0 + (duplicateSelection.contains($1.path) ? $1.size : 0) }
        }
    }

    /// 完全重复组每组保留一份后的可释放量。相似图片组大小不一，不估算。
    var duplicateSelectionIncludesSimilar: Bool {
        !duplicateSelection.isEmpty && duplicateGroups.contains { group in
            group.kind == .similarImages && group.members.contains { duplicateSelection.contains($0.path) }
        }
    }

    var duplicateReclaimableBytes: UInt64 {
        guard duplicateMode == .exact, !duplicateGroups.isEmpty else { return 0 }
        return duplicateScanReclaimableBytes
    }

    func setDuplicateMode(_ mode: DuplicateMode) {
        guard !isBusy, !isScanningDuplicates, duplicateMode != mode else { return }
        cacheCurrentDuplicateSelection()
        duplicateMode = mode
        restoreDuplicateResult()
    }

    private func restoreDuplicateResult() {
        if let cached = duplicateResultCache[duplicateMode] {
            duplicateGroups = cached.snapshot.groups
            duplicateSelection = cached.selection
            duplicateScannedRoots = cached.snapshot.roots
            duplicateScanFinished = true
            duplicateStatus = cached.status
            duplicateCoverage = cached.coverage
            duplicateScanReclaimableBytes = cached.snapshot.reclaimableBytes
            duplicateLastScanDate = cached.scannedAt
            return
        }
        duplicateGroups = []
        duplicateSelection = []
        duplicateScannedRoots = []
        duplicateScanFinished = false
        duplicateStatus = ""
        duplicateCoverage = ""
        duplicateScanReclaimableBytes = 0
        duplicateLastScanDate = nil
        duplicateScanProgress.reset()
    }

    private func cacheCurrentDuplicateSelection() {
        guard var cached = duplicateResultCache[duplicateMode] else { return }
        cached.selection = duplicateSelection
        duplicateResultCache[duplicateMode] = cached
        persistDuplicateResults()
    }

    private func persistDuplicateResults() {
        duplicateWorkspaceStore.save(duplicateResultCache, contentCache: duplicateContentCache,
                                     featureCache: similarImageFeatureCache)
    }

    func restorePersistedDuplicateResults() {
        let store = duplicateWorkspaceStore
        let revision = store.currentRevision
        let contentCache = duplicateContentCache
        let featureCache = similarImageFeatureCache
        Task {
            let saved = await Task.detached(priority: .utility) {
                store.load(contentCache: contentCache, featureCache: featureCache)
            }.value
            guard revision == store.currentRevision else { return }
            duplicateResultCache.merge(saved) { current, _ in current }
            if !isScanningDuplicates, !duplicateScanFinished { restoreDuplicateResult() }
            runScheduledAnalysisScans()
        }
    }

    /// 全盘扫描的重复文件子分类：家目录内做内容级比对，系统文件、
    /// 包目录与隐藏位置由扫描策略直接排除，用户无需选择范围。
    func scanDuplicateFiles(forceFull: Bool = false) {
        guard !isBusy, !isAnalyzing, !isScanningDuplicates else { return }
        guard permissionCenter.fullDiskAccessGranted else {
            duplicateStatus = L10n.shared.t("duplicates.status.noAccess")
            presentTaskFailure(message: duplicateStatus)
            return
        }
        noteAnalysisScanAttempt(for: .duplicates)
        beginDuplicateScan(roots: [NSHomeDirectory()], home: NSHomeDirectory(), forceFull: forceFull)
    }

    /// The production entry point uses the current home. Explicit roots make
    /// the operation boundary testable with generated fixtures only.
    func beginDuplicateScan(roots: [String], home: String, forceFull: Bool = false) {
        guard !isBusy, !isAnalyzing, !isScanningDuplicates else { return }
        cacheCurrentDuplicateSelection()
        duplicateScanProgress.reset()
        let control = DuplicateScanControl()
        duplicateScanControl = control
        analysisScanIsFull = forceFull || !duplicateScanFinished
        isScanningDuplicates = true
        duplicateStatus = L10n.shared.tf("duplicates.status.enumerating", 0)
        let mode = duplicateMode
        let previousResult = duplicateResultCache[mode]
        let contentCache = forceFull ? nil : duplicateContentCache
        let featureCache = forceFull ? nil : similarImageFeatureCache
        let progress: (DuplicateScanProgress) -> Void = { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self, self.duplicateScanControl === control, !control.isCancelled else { return }
                self.duplicateScanProgress.update(event)
            }
        }
        Task {
            let result = await Task.detached(priority: .utility) {
                mode == .exact
                    ? DuplicateScanWorker.scanAll(roots: roots, control: control, home: home,
                        contentCache: contentCache, featureCache: featureCache, progress: progress)
                    : DuplicateScanWorker.scan(mode: mode, roots: roots, control: control,
                        home: home, contentCache: contentCache, featureCache: featureCache, progress: progress)
            }.value
            guard duplicateScanControl === control else { return }
            finishDuplicateScan(result, cancelled: result.cancelled || control.isCancelled,
                                previousResult: previousResult)
        }
    }

    private func finishDuplicateScan(_ result: DuplicateScanSnapshot, cancelled: Bool,
                                     previousResult: DuplicateCachedResult?) {
        isScanningDuplicates = false
        analysisScanIsFull = false
        duplicateScanControl = nil
        duplicateScanProgress.reset()
        if cancelled {
            duplicateStatus = L10n.shared.t("duplicates.status.cancelled")
        } else if let error = result.error {
            duplicateStatus = L10n.shared.t("duplicates.status.failed")
            log(error)
            presentTaskFailure(message: duplicateStatus, details: [error])
        } else {
            duplicateGroups = result.groups
            duplicateScannedRoots = result.roots
            duplicateScanReclaimableBytes = result.reclaimableBytes
            if let previousResult {
                let knownPaths = Set(previousResult.snapshot.groups.flatMap { $0.members.map(\.path) })
                duplicateSelection = DuplicateSelectionPolicy.safeSelection(
                    previousResult.selection.union(result.defaultSelection.subtracting(knownPaths)),
                    groups: result.groups, mode: duplicateMode)
            } else { duplicateSelection = result.defaultSelection }
            duplicateScanFinished = true
            let scannedAt = Date()
            duplicateLastScanDate = scannedAt
            duplicateCoverage = duplicateCoverageDescription(result)
            // Skipped items never become cleanup candidates. Partial coverage
            // belongs in the status line, without interrupting result review.
            duplicateStatus = L10n.shared.tf("duplicates.status.complete", duplicateGroups.count)
            duplicateResultCache[duplicateMode] = DuplicateCachedResult(snapshot: result,
                selection: duplicateSelection, status: duplicateStatus, coverage: duplicateCoverage,
                scannedAt: scannedAt)
            persistDuplicateResults()
        }
        runScheduledAnalysisScans()
    }

    private func duplicateCoverageDescription(_ snapshot: DuplicateScanSnapshot) -> String {
        var description = L10n.shared.tf("duplicates.coverage", snapshot.scanned, snapshot.skipped)
        if snapshot.partial { description += " · " + L10n.shared.t("duplicates.coverage.partial") }
        if snapshot.exactCopiesSkipped > 0 {
            description += " · " + L10n.shared.tf("duplicates.coverage.exactSkipped", snapshot.exactCopiesSkipped)
        }
        return description
    }

    func cancelDuplicateScan() { duplicateScanControl?.cancel() }

    func canSelectDuplicate(_ record: DuplicateFileRecord, group: DuplicateFileGroup) -> Bool {
        guard !isBusy, !isScanningDuplicates,
              group.members.contains(where: { $0.path == record.path }) else { return false }
        if duplicateSelection.contains(record.path) { return true }
        return group.members.contains { $0.path != record.path && !duplicateSelection.contains($0.path) }
    }

    func toggleDuplicateSelection(_ record: DuplicateFileRecord) {
        guard let group = duplicateGroups.first(where: { $0.members.contains(where: { $0.path == record.path }) }),
              canSelectDuplicate(record, group: group) else { return }
        if duplicateSelection.contains(record.path) { duplicateSelection.remove(record.path) }
        else { duplicateSelection.insert(record.path) }
        cacheCurrentDuplicateSelection()
    }

    func selectAllDuplicates() { selectDefaultDuplicates() }

    func deselectAllDuplicates() {
        guard !isBusy, !isScanningDuplicates else { return }
        duplicateSelection = []
        cacheCurrentDuplicateSelection()
    }

    func selectDefaultDuplicates() {
        guard !isBusy, !isScanningDuplicates else { return }
        duplicateSelection = DuplicateSelectionPolicy.suggestedSelection(groups: duplicateGroups, mode: duplicateMode)
        cacheCurrentDuplicateSelection()
    }

    /// Keep each cached submode synchronized after cleanup or image compression.
    /// Only affected entries and groups change; this never starts another scan.
    func refreshDuplicateResultsAfterMutation(removedPaths: Set<String>, changedPaths: Set<String> = []) {
        guard !removedPaths.isEmpty || !changedPaths.isEmpty else { return }
        duplicateWorkspaceStore.noteMutation()
        cacheCurrentDuplicateSelection()
        duplicateContentCache.invalidate(paths: removedPaths.union(changedPaths))
        similarImageFeatureCache.invalidate(paths: removedPaths.union(changedPaths))
        for mode in Array(duplicateResultCache.keys) {
            guard var cached = duplicateResultCache[mode] else { continue }
            cached.snapshot = cached.snapshot.refreshing(removedPaths: removedPaths, changedPaths: changedPaths)
            cached.selection = DuplicateSelectionPolicy.safeSelection(cached.selection,
                groups: cached.snapshot.groups, mode: mode)
            cached.status = L10n.shared.tf("duplicates.status.complete", cached.snapshot.groups.count)
            cached.coverage = duplicateCoverageDescription(cached.snapshot)
            duplicateResultCache[mode] = cached
        }
        restoreDuplicateResult()
        persistDuplicateResults()
    }

    /// Runs only after the section's explicit Trash confirmation. This native
    /// route retains the cleanup whitelist and open-file checks, with a fresh
    /// group/content validation at each final mutation edge.
    func deleteSelectedDuplicates() {
        guard !isBusy, !duplicateSelection.isEmpty else { return }
        let groups = duplicateGroups
        let selectedPaths = duplicateSelection
        let roots = duplicateScannedRoots
        let mode = duplicateMode
        isDeletingDuplicates = true
        duplicateStatus = L10n.shared.t("duplicates.status.deleting")
        let control = DuplicateScanControl()
        Task {
            let summary = await Task.detached(priority: .utility) { () -> NativeCore.ApplySummary? in
                guard let plan = try? DuplicateDeletionPlan(groups: groups.map {
                    DuplicateDeletionGroup(files: $0.members.map(\.file),
                                           requiresExactMatch: mode == .exact && $0.kind == .exact)
                }, selectedPaths: selectedPaths, roots: roots) else { return nil }
                let core = NativeCore.shared
                return core.applyCleanup(items: plan.items, permanent: false, allowedRoots: plan.roots,
                    finalValidation: { path in
                        let whitelist = core.loadWhitelist(homeDirectory: plan.home)
                        guard !core.matchesWhitelist(path, entries: whitelist) else { return false }
                        do { try plan.validate(path, control: control); return true }
                        catch { return false }
                    })
            }.value
            isDeletingDuplicates = false
            guard let summary else {
                duplicateStatus = L10n.shared.t("duplicates.status.invalidSelection")
                presentTaskFailure(message: duplicateStatus)
                return
            }
            refreshAnalysisAfterMutation(removedPaths: summary.removedPaths)
            duplicateStatus = L10n.shared.tf("duplicates.status.deleted", summary.removed, summary.skipped, summary.failed)
            if var cached = duplicateResultCache[mode] {
                cached.status = duplicateStatus
                duplicateResultCache[mode] = cached
                persistDuplicateResults()
            }
            for message in summary.messages { log(message) }
            if summary.failed > 0 || summary.skipped > 0 {
                presentTaskFailure(message: duplicateStatus,
                    details: summary.messages.filter { !$0.hasPrefix("Open-file check ") })
            }
            resampleAfterMutation()
        }
    }
}
