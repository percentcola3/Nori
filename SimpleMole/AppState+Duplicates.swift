import AppKit
import Foundation

enum DuplicateMode: String, CaseIterable, Identifiable {
    case exact, similarImages
    var id: String { rawValue }
}

struct DuplicateImageInfo: Sendable {
    let width: Int
    let height: Int
    let sharpness: Double
}

struct DuplicateFileRecord: Identifiable, Sendable {
    let file: DuplicateFile
    var imageInfo: DuplicateImageInfo? = nil
    var id: String { file.path }
    var path: String { file.path }
    var name: String { file.name }
    var size: UInt64 { file.size }
}

struct DuplicateFileGroup: Identifiable, Sendable {
    let id: String
    let members: [DuplicateFileRecord]
}

@MainActor
extension AppState {
    var duplicateSelectedCount: Int { duplicateSelection.count }
    var duplicateSelectedBytes: UInt64 {
        duplicateGroups.flatMap(\.members)
            .filter { duplicateSelection.contains($0.path) }.reduce(0) { $0 + $1.size }
    }

    func chooseDuplicateFolders() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.prompt = L10n.shared.t("duplicates.scope.choose")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { addDuplicateRoot(url.path) }
    }

    func addDuplicateRoot(_ path: String) {
        guard !isBusy else { return }
        let root = URL(fileURLWithPath: path).standardizedFileURL.path
        guard DuplicateScanner.isAllowedRoot(root) else {
            duplicateStatus = L10n.shared.t("duplicates.scope.rejected")
            return
        }
        guard !duplicateRoots.contains(where: { root == $0 || root.hasPrefix($0 + "/") }) else { return }
        duplicateRoots.removeAll { $0.hasPrefix(root + "/") }
        duplicateRoots.append(root)
        resetDuplicateResults()
    }

    func removeDuplicateRoot(_ path: String) {
        guard !isBusy else { return }
        duplicateRoots.removeAll { $0 == path }
        resetDuplicateResults()
    }

    func setDuplicateMode(_ mode: DuplicateMode) {
        guard !isBusy, duplicateMode != mode else { return }
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
    }

    func scanDuplicateFiles() {
        guard !isBusy, !duplicateRoots.isEmpty else { return }
        guard permissionCenter.fullDiskAccessGranted else {
            showDuplicateFiles = false
            requestScanAccess(.duplicateScan)
            return
        }
        resetDuplicateResults()
        let control = DuplicateScanControl()
        duplicateScanControl = control
        isScanningDuplicates = true
        duplicateStatus = L10n.shared.tf("duplicates.status.enumerating", 0)
        let roots = duplicateRoots
        let mode = duplicateMode
        let progress: (DuplicateScanProgress) -> Void = { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self, self.duplicateScanControl === control, !control.isCancelled else { return }
                let l10n = L10n.shared
                switch event.phase {
                case "enumerating":
                    self.duplicateStatus = l10n.tf("duplicates.status.enumerating", event.scannedFiles)
                case "similar-images", "similar-grouping":
                    self.duplicateStatus = l10n.tf("duplicates.status.images", event.processedFiles, event.totalCandidates)
                default:
                    self.duplicateStatus = l10n.tf("duplicates.status.hashing", event.processedFiles, event.totalCandidates)
                }
            }
        }
        Task {
            if mode == .exact {
                let result = await Task.detached(priority: .utility) {
                    DuplicateScanner.scan(roots: roots, control: control, progress: progress)
                }.value
                guard duplicateScanControl === control else { return }
                let cancelled = result.cancelled || control.isCancelled
                duplicateGroups = cancelled ? [] : result.groups.map { group in
                    DuplicateFileGroup(id: group.id, members: group.files.map { DuplicateFileRecord(file: $0) })
                }
                finishDuplicateScan(roots: result.roots, scanned: result.files.count,
                    skipped: result.skippedFiles, partial: result.isPartial,
                    cancelled: cancelled, error: result.error)
            } else {
                let result = await Task.detached(priority: .utility) {
                    SimilarImageScanner.scan(roots: roots, control: control, progress: progress)
                }.value
                guard duplicateScanControl === control else { return }
                let cancelled = result.cancelled || control.isCancelled
                duplicateGroups = cancelled ? [] : result.groups.map { group in
                    DuplicateFileGroup(id: group.id, members: group.files.map { image in
                        DuplicateFileRecord(file: image.file,
                            imageInfo: DuplicateImageInfo(width: image.pixelWidth,
                                height: image.pixelHeight, sharpness: image.sharpnessScore))
                    })
                }
                finishDuplicateScan(roots: result.roots, scanned: result.scannedFiles,
                    skipped: result.skippedFiles, partial: result.isPartial,
                    cancelled: cancelled, error: result.error)
                if result.exactCopiesSkipped > 0 {
                    duplicateCoverage += " · " + L10n.shared.tf("duplicates.coverage.exactSkipped", result.exactCopiesSkipped)
                }
            }
        }
    }

    private func finishDuplicateScan(roots: [String], scanned: Int, skipped: Int,
                                     partial: Bool, cancelled: Bool, error: String?) {
        duplicateScannedRoots = roots
        isScanningDuplicates = false
        duplicateScanControl = nil
        duplicateScanFinished = true
        duplicateCoverage = L10n.shared.tf("duplicates.coverage", scanned, skipped)
        if partial { duplicateCoverage += " · " + L10n.shared.t("duplicates.coverage.partial") }
        if cancelled {
            duplicateGroups = []
            duplicateStatus = L10n.shared.t("duplicates.status.cancelled")
        } else if let error {
            duplicateStatus = L10n.shared.t("duplicates.status.failed")
            log(error)
        } else {
            duplicateStatus = L10n.shared.tf("duplicates.status.complete", duplicateGroups.count)
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

    /// Called only after the sheet's explicit Trash confirmation. This native
    /// route retains the cleanup whitelist and open-file checks, with a fresh
    /// group/content validation at each final mutation edge.
    func deleteSelectedDuplicates() {
        guard !isBusy, !duplicateSelection.isEmpty else { return }
        let plan: DuplicateDeletionPlan
        do {
            plan = try DuplicateDeletionPlan(groups: duplicateGroups.map {
                DuplicateDeletionGroup(files: $0.members.map(\.file), requiresExactMatch: duplicateMode == .exact)
            }, selectedPaths: duplicateSelection, roots: duplicateScannedRoots)
        } catch {
            duplicateStatus = L10n.shared.t("duplicates.status.invalidSelection")
            return
        }
        isDeletingDuplicates = true
        duplicateStatus = L10n.shared.t("duplicates.status.deleting")
        let control = DuplicateScanControl()
        Task {
            let summary = await Task.detached(priority: .utility) {
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
            resetDuplicateResults()
            duplicateStatus = L10n.shared.tf("duplicates.status.deleted", summary.removed, summary.skipped, summary.failed)
            for message in summary.messages { log(message) }
            analyzeCache.clear()
        }
    }
}
