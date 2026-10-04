import AppKit
import Foundation

/// 磁盘分析结果的瘦身子分类；重复文件单独成节，不参与瘦身。
enum AnalyzeSection: String, CaseIterable, Identifiable {
    case largeFiles, images, videos
    var id: String { rawValue }
}

/// 分析侧边栏的独立分类。切换只展示已保存的结果，扫描由显式操作触发。
enum AnalyzeMode: String, CaseIterable, Identifiable {
    case disk, largeFiles, images, videos, duplicates
    var id: String { rawValue }

    /// 聚焦模式对应的子分类；重复文件没有单一对应。
    var section: AnalyzeSection? {
        switch self {
        case .disk, .duplicates: return nil
        case .largeFiles: return .largeFiles
        case .images: return .images
        case .videos: return .videos
        }
    }

    var runsDuplicateComparison: Bool {
        self == .duplicates
    }

    var titleKey: String {
        switch self {
        case .disk: return "analyze.section.disk"
        case .largeFiles: return "analyze.section.largeFiles"
        case .images: return "analyze.section.images"
        case .videos: return "analyze.section.videos"
        case .duplicates: return "analyze.section.duplicates"
        }
    }

    /// 主按钮文案。下拉只改待执行的类型，按下主按钮才开始这一类扫描。
    var actionKey: String { "analyze.scan.action.\(rawValue)" }
    var detailKey: String { "analyze.scan.detail.\(rawValue)" }

    /// 面板顺序：磁盘浏览、大文件、重复文件、视频、图片。
    static let menuOrder: [AnalyzeMode] = [.disk, .largeFiles, .duplicates, .videos, .images]
}

struct SlimProgress: Equatable {
    let index: Int
    let total: Int
    let name: String
    var fraction: Double?
}

/// 聚合视图里的一行：大文件、图片或视频。扫描层已过滤系统位置，这里全部可操作。
struct SlimCandidate: Identifiable, Equatable {
    let name: String
    let path: String
    let size: UInt64
    let kind: MediaKind?
    var id: String { path }
    var operation: SlimOperation { SlimOperation.operation(for: path) }
}

/// 分析清理清单中的文件或目录，不参与图片瘦身。
struct AnalysisFileItem: Identifiable, Equatable {
    let name: String
    let path: String
    let size: UInt64
    var id: String { path }
}

/// 文件瘦身：只有图片走压缩（降分辨率/重编码）；
/// 大文件、视频与重复文件保留删除（移入废纸篓）路线。
@MainActor
extension AppState {
    func slimCandidates(in section: AnalyzeSection) -> [SlimCandidate] {
        switch section {
        case .largeFiles, .videos:
            // 大文件/视频不再提供瘦身候选：它们在页面上走删除清单。
            return []
        case .images:
            return analyzeMedia.filter { $0.kind == .image }.map {
                SlimCandidate(name: $0.name, path: $0.path, size: $0.size, kind: $0.kind)
            }
        }
    }

    var slimSelectedCandidates: [SlimCandidate] {
        AnalyzeSection.allCases
            .flatMap { slimCandidates(in: $0) }
            .filter { slimSelection.contains($0.path) }
    }

    var slimSelectedBytes: UInt64 {
        slimSelectedCandidates.reduce(0) { $0 &+ $1.size }
    }

    func toggleSlimSelection(_ candidate: SlimCandidate) {
        guard !isBusy else { return }
        if slimSelection.contains(candidate.path) {
            slimSelection.remove(candidate.path)
        } else {
            slimSelection.insert(candidate.path)
        }
    }

    // MARK: 各分类共用勾选、删除；图片额外支持压缩

    /// 当前分类可清理的项目；磁盘浏览只选择最右侧目录内的项目。
    func analysisFileItems(for mode: AnalyzeMode) -> [AnalysisFileItem] {
        switch mode {
        case .disk:
            return diskBrowserEntries(at: diskBrowserNavigation.last ?? diskBrowserRootPath)
                .filter(diskBrowserCanSelect).map {
                    AnalysisFileItem(name: $0.name, path: $0.path, size: $0.size)
                }
        case .largeFiles:
            return analyzeLargeFiles.map {
                AnalysisFileItem(name: $0.name, path: $0.path, size: $0.size)
            }
        case .videos, .images:
            let kind: MediaKind = mode == .videos ? .video : .image
            return analyzeMedia.filter { $0.kind == kind }.map {
                AnalysisFileItem(name: $0.name, path: $0.path, size: $0.size)
            }
        case .duplicates:
            return []
        }
    }

    /// Navigation never touches the filesystem or recomputes tree capacities.
    func diskBrowserEntries(at path: String) -> [AnalyzeEntry] {
        diskBrowserEntriesByPath[path] ?? []
    }

    func diskBrowserCanSelect(_ entry: AnalyzeEntry) -> Bool {
        entry.isPartial != true &&
            AnalysisFileDeletionPlan.isEligible(path: entry.path, homeDirectory: diskBrowserHomePath,
                                                allowsDirectories: true)
    }

    func openDiskBrowserDirectory(_ entry: AnalyzeEntry, in parentPath: String) {
        guard entry.isDir, let index = diskBrowserNavigation.firstIndex(of: parentPath),
              diskBrowserEntries(at: parentPath).contains(where: { $0.path == entry.path && $0.isDir }),
              diskBrowserEntriesByPath[entry.path] != nil else { return }
        let navigation = Array(diskBrowserNavigation.prefix(index + 1)) + [entry.path]
        guard navigation != diskBrowserNavigation else { return }
        diskBrowserNavigation = navigation
        setAnalysisSelection([], for: .disk)
    }

    func navigateDiskBrowser(to path: String) {
        guard let index = diskBrowserNavigation.firstIndex(of: path) else { return }
        let navigation = Array(diskBrowserNavigation.prefix(index + 1))
        guard navigation != diskBrowserNavigation else { return }
        diskBrowserNavigation = navigation
        setAnalysisSelection([], for: .disk)
    }

    var analysisFileSelectedItems: [AnalysisFileItem] {
        analysisFileItems(for: analyzeMode).filter { analysisSelection(for: analyzeMode).contains($0.path) }
    }

    var analysisFileSelectedBytes: UInt64 {
        analysisFileSelectedItems.reduce(0) { $0 &+ $1.size }
    }

    func toggleAnalysisFileSelection(_ item: AnalysisFileItem) {
        guard !isBusy, analysisFileItems(for: analyzeMode).contains(where: { $0.path == item.path }) else { return }
        var selection = analysisSelection(for: analyzeMode)
        if selection.contains(item.path) {
            selection.remove(item.path)
        } else {
            selection.insert(item.path)
        }
        setAnalysisSelection(selection, for: analyzeMode)
    }

    func analysisSelection(for mode: AnalyzeMode) -> Set<String> {
        analysisFileSelectionsByMode[mode] ?? []
    }

    private func setAnalysisSelection(_ paths: Set<String>, for mode: AnalyzeMode) {
        analysisFileSelectionsByMode[mode] = paths
        if mode == analyzeMode { analysisFileSelection = paths }
        if mode == .images { slimSelection = paths }
    }

    func selectAllAnalysisFiles() {
        guard !isBusy else { return }
        setAnalysisSelection(Set(analysisFileItems(for: analyzeMode).map(\.path)), for: analyzeMode)
    }

    func deselectAllAnalysisFiles() {
        guard !isBusy else { return }
        setAnalysisSelection([], for: analyzeMode)
    }

    /// 个人文件没有可安全默认删除的候选，默认保留；重复文件使用自己的保留策略。
    func selectDefaultAnalysisFiles() { deselectAllAnalysisFiles() }

    func toggleSelectAllAnalysisFiles() {
        guard !isBusy else { return }
        let paths = analysisFileItems(for: analyzeMode).map(\.path)
        var selection = analysisSelection(for: analyzeMode)
        if paths.allSatisfy(selection.contains) {
            selection.subtract(paths)
        } else {
            selection.formUnion(paths)
        }
        setAnalysisSelection(selection, for: analyzeMode)
    }

    /// 普通文件移入废纸篓；已确认可重建的缓存按策略清理，并局部同步结果。
    func deleteAnalysisFiles(_ paths: [String], mode: AnalyzeMode? = nil) {
        guard !isBusy, !isDeletingAnalysisFiles, !paths.isEmpty else { return }
        let sourceMode = mode ?? analyzeMode
        let inventoryKind: AnalysisInventoryKind = sourceMode == .disk ? .disk
            : sourceMode == .images ? .images : sourceMode == .videos ? .videos : .largeFiles
        let snapshot = analysisInventoryCache.restore()[inventoryKind]
        let scanFingerprints = snapshot.map { inventory in
            Set(paths).reduce(into: [String: AnalysisFileFingerprint]()) { fingerprints, path in
                fingerprints[path] = inventory.files[path] ?? inventory.directories[path]?.fingerprint
            }
        }
        let homeDirectory = sourceMode == .disk ? diskBrowserHomePath : NSHomeDirectory()
        // Capture the confirmed current inventory and identities before yielding.
        let plan = AnalysisFileDeletionPlan(
            requestedPaths: paths,
            inventoryPaths: Set(analysisFileItems(for: sourceMode).map(\.path)),
            scanFingerprints: scanFingerprints,
            allowsDirectories: sourceMode == .disk)
        isDeletingAnalysisFiles = true
        Task {
            let applied = await plan.executeWithAdministrator(homeDirectory: homeDirectory) {
                await AdministratorCleanupService.apply(items: $0)
            }
            let removed = applied.removedPaths
            let failed = applied.failed + applied.skipped
            refreshAnalysisAfterMutation(removedPaths: removed)
            isDeletingAnalysisFiles = false
            let summary = L10n.shared.tf("analyze.delete.done", removed.count, failed)
            statusText = summary
            analyzeStatus = summary
            analysisStatuses[sourceMode] = summary
            log(summary)
            if failed == 0, !removed.isEmpty { noteHeaderReaction(.success) }
            else if failed > 0 { noteHeaderReaction(.attention) }
            if failed > 0 {
                presentTaskFailure(message: summary,
                    details: applied.messages.filter { !$0.hasPrefix("Open-file check ") })
            }
            resampleAfterMutation()
        }
    }

    /// 某一子分类的全选/取消全选；不影响其他分类的已选项。
    func toggleSelectAllSlimCandidates(in section: AnalyzeSection) {
        guard !isBusy else { return }
        let paths = slimCandidates(in: section).map(\.path)
        if paths.allSatisfy(slimSelection.contains) {
            slimSelection.subtract(paths)
        } else {
            slimSelection.formUnion(paths)
        }
    }

    func revealPath(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func requestSlim() {
        guard !isBusy, !slimSelectedCandidates.isEmpty else { return }
        showSlimSheet = true
    }

    func startSlim() {
        showSlimSheet = false
        let targets = slimSelectedCandidates
        guard !isBusy, !targets.isEmpty else { return }
        let options = slimOptions
        let scanFingerprints = analysisInventoryCache.restore()[.images]?.files
        isSlimming = true
        log(L10n.shared.tf("slim.log.start", targets.count))
        slimTask = Task { [weak self] in
            let slimmer = MediaSlimmer()
            var outcomes: [SlimOutcome] = []
            for (index, target) in targets.enumerated() {
                if Task.isCancelled { break }
                self?.slimProgress = SlimProgress(index: index + 1, total: targets.count,
                                                  name: target.name, fraction: nil)
                let outcome = await slimmer.slim(path: target.path, options: options, validateSource: {
                    scanFingerprints == nil || scanFingerprints?[target.path] == AnalysisFileFingerprint.read(target.path)
                }) { fraction in
                    Task { @MainActor [weak self] in self?.slimProgress?.fraction = fraction }
                }
                outcomes.append(outcome)
                self?.logSlimOutcome(outcome)
            }
            self?.finishSlim(outcomes, requested: targets.count)
        }
    }

    func cancelSlim() {
        slimTask?.cancel()
    }

    private func logSlimOutcome(_ outcome: SlimOutcome) {
        let name = (outcome.path as NSString).lastPathComponent
        switch outcome.status {
        case .slimmed:
            log(L10n.shared.tf("slim.log.done", name, ByteFormat.format(outcome.originalBytes),
                        ByteFormat.format(outcome.newBytes)))
        case .notSmaller:
            log(L10n.shared.tf("slim.log.notSmaller", name))
        case .unsupported:
            log(L10n.shared.tf("slim.log.unsupported", name, L10n.shared.t(outcome.message ?? "")))
        case .failed:
            log(L10n.shared.tf("slim.log.failed", name, L10n.shared.t(outcome.message ?? "")))
        case .cancelled:
            break
        }
    }

    private func finishSlim(_ outcomes: [SlimOutcome], requested: Int) {
        isSlimming = false
        slimProgress = nil
        slimTask = nil
        let slimmed = outcomes.filter { $0.status == .slimmed }
        let saved = slimmed.reduce(UInt64(0)) { $0 &+ $1.savedBytes }
        let notSmaller = outcomes.filter { $0.status == .notSmaller }.count
        let unsupported = outcomes.filter { $0.status == .unsupported }.count
        let failed = outcomes.filter { $0.status == .failed }.count
        let cancelled = requested - outcomes.filter { $0.status != .cancelled }.count

        var parts = [slimOptions.replaceOriginal
            ? L10n.shared.tf("slim.summary.replaced", slimmed.count, ByteFormat.format(saved))
            : L10n.shared.tf("slim.summary.copied", slimmed.count)]
        if notSmaller > 0 { parts.append(L10n.shared.tf("slim.summary.notSmaller", notSmaller)) }
        if unsupported > 0 { parts.append(L10n.shared.tf("slim.summary.unsupported", unsupported)) }
        if failed > 0 { parts.append(L10n.shared.tf("slim.summary.failed", failed)) }
        if cancelled > 0 { parts.append(L10n.shared.tf("slim.summary.cancelled", cancelled)) }
        statusText = parts.joined(separator: " · ")
        analyzeStatus = statusText
        analysisStatuses[.images] = statusText
        if cancelled == requested {
            noteHeaderReaction(nil)
        } else {
            noteHeaderReaction((failed > 0 || cancelled > 0) ? .attention : .success)
        }
        log(statusText)
        if failed > 0 || unsupported > 0 {
            presentTaskFailure(message: statusText, details: outcomes.compactMap { outcome in
                guard outcome.status == .failed || outcome.status == .unsupported else { return nil }
                let reason = outcome.message.map { L10n.shared.t($0) } ?? ""
                return outcome.path + (reason.isEmpty ? "" : "\n" + reason)
            }, detailsAreLocalized: true)
        }
        applySlimOutcomes(outcomes)
        resampleAfterMutation()
    }

    /// 就地更新清单，并让涉及目录的缓存失效，下次进入时重新统计。
    private func applySlimOutcomes(_ outcomes: [SlimOutcome]) {
        guard !outcomes.isEmpty else { return }
        var changed = Set<String>()
        for outcome in outcomes {
            // Even a failed placement may have moved the original to Trash.
            // Re-read attempted paths to reflect their actual final state.
            if outcome.status == .slimmed || outcome.status == .failed { changed.insert(outcome.path) }
            if let output = outcome.outputPath { changed.insert(output) }
        }
        refreshAnalysisAfterMutation(removedPaths: [], changedPaths: changed)
        let completedPaths = outcomes.filter { $0.status == .slimmed }.map(\.path)
        slimSelection.subtract(completedPaths)
        var selected = analysisSelection(for: .images)
        selected.subtract(completedPaths)
        setAnalysisSelection(selected, for: .images)
    }
}
