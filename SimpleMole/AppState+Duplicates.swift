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
    var duplicateReclaimableBytes: UInt64 {
        guard duplicateMode == .exact, !duplicateGroups.isEmpty else { return 0 }
        return duplicateScanReclaimableBytes
    }

    func setDuplicateMode(_ mode: DuplicateMode) {
        guard !isBusy, !isScanningDuplicates, duplicateMode != mode else { return }
        duplicateMode = mode
        resetDuplicateResults()
    }

    private func resetDuplicateResults() {
        duplicateGroups = []
        duplicateSelection = []
        duplicateScannedRoots = []
        duplicateScanFinished = false
        duplicateStatus = ""
        duplicateCoverage = ""
        duplicateScanReclaimableBytes = 0
        duplicateScanProgress.reset()
    }

    /// 全盘扫描的重复文件子分类：家目录内做内容级比对，系统文件、
    /// 包目录与隐藏位置由扫描策略直接排除，用户无需选择范围。
    func scanDuplicateFiles() {
        guard !isBusy, !isScanningDuplicates else { return }
        guard permissionCenter.fullDiskAccessGranted else {
            duplicateStatus = L10n.shared.t("duplicates.status.noAccess")
            presentTaskFailure(message: duplicateStatus)
            return
        }
        resetDuplicateResults()
        let control = DuplicateScanControl()
        duplicateScanControl = control
        isScanningDuplicates = true
        duplicateStatus = L10n.shared.tf("duplicates.status.enumerating", 0)
        let roots = [NSHomeDirectory()]
        let mode = duplicateMode
        let progress: (DuplicateScanProgress) -> Void = { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self, self.duplicateScanControl === control, !control.isCancelled else { return }
                self.duplicateScanProgress.update(event)
            }
        }
        Task {
            let result = await Task.detached(priority: .utility) {
                DuplicateScanWorker.scan(mode: mode, roots: roots, control: control, progress: progress)
            }.value
            guard duplicateScanControl === control else { return }
            let cancelled = result.cancelled || control.isCancelled
            duplicateScanReclaimableBytes = cancelled ? 0 : result.reclaimableBytes
            duplicateGroups = cancelled ? [] : result.groups
            finishDuplicateScan(roots: result.roots, scanned: result.scanned,
                skipped: result.skipped, partial: result.partial,
                cancelled: cancelled, error: result.error)
            if result.exactCopiesSkipped > 0 {
                duplicateCoverage += " · " + L10n.shared.tf("duplicates.coverage.exactSkipped", result.exactCopiesSkipped)
            }
        }
    }

    private func finishDuplicateScan(roots: [String], scanned: Int, skipped: Int,
                                     partial: Bool, cancelled: Bool, error: String?) {
        duplicateScannedRoots = roots
        isScanningDuplicates = false
        duplicateScanControl = nil
        duplicateScanProgress.reset()
        duplicateScanFinished = true
        duplicateCoverage = L10n.shared.tf("duplicates.coverage", scanned, skipped)
        if partial { duplicateCoverage += " · " + L10n.shared.t("duplicates.coverage.partial") }
        if cancelled {
            duplicateGroups = []
            duplicateStatus = L10n.shared.t("duplicates.status.cancelled")
        } else if let error {
            duplicateStatus = L10n.shared.t("duplicates.status.failed")
            log(error)
            presentTaskFailure(message: duplicateStatus, details: [error])
        } else {
            duplicateStatus = L10n.shared.tf("duplicates.status.complete", duplicateGroups.count)
            if partial {
                presentTaskFailure(message: L10n.shared.t("duplicates.coverage.partial"),
                    details: [duplicateCoverage], detailsAreLocalized: true)
            }
        }
    }

    func cancelDuplicateScan() { duplicateScanControl?.cancel() }

    func canSelectDuplicate(_ record: DuplicateFileRecord, group: DuplicateFileGroup) -> Bool {
        guard !isBusy, group.members.contains(where: { $0.path == record.path }) else { return false }
        if duplicateSelection.contains(record.path) { return true }
        return group.members.contains { $0.path != record.path && !duplicateSelection.contains($0.path) }
    }

    func toggleDuplicateSelection(_ record: DuplicateFileRecord) {
        guard let group = duplicateGroups.first(where: { $0.members.contains(where: { $0.path == record.path }) }),
              canSelectDuplicate(record, group: group) else { return }
        if duplicateSelection.contains(record.path) { duplicateSelection.remove(record.path) }
        else { duplicateSelection.insert(record.path) }
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
                    DuplicateDeletionGroup(files: $0.members.map(\.file), requiresExactMatch: mode == .exact)
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
            resetDuplicateResults()
            duplicateStatus = L10n.shared.tf("duplicates.status.deleted", summary.removed, summary.skipped, summary.failed)
            for message in summary.messages { log(message) }
            if summary.failed > 0 || summary.skipped > 0 {
                presentTaskFailure(message: duplicateStatus,
                    details: summary.messages.filter { !$0.hasPrefix("Open-file check ") })
            }
            analyzeCache.clear()
            resampleAfterMutation()
        }
    }
}
