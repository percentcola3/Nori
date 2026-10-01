import AppKit
import Foundation

/// 磁盘分析结果的瘦身子分类；重复文件单独成节，不参与瘦身。
enum AnalyzeSection: String, CaseIterable, Identifiable {
    case largeFiles, images, videos
    var id: String { rawValue }
}

/// 磁盘分析页顶部分段按钮组选择的类型：每次只聚焦一个子分类，
/// 内容不重复出现。重复文件的内容级比对只在选中“重复文件”时自动跟进。
enum AnalyzeMode: String, CaseIterable, Identifiable {
    case largeFiles, images, videos, duplicates
    var id: String { rawValue }

    /// 聚焦模式对应的子分类；重复文件没有单一对应。
    var section: AnalyzeSection? {
        switch self {
        case .duplicates: return nil
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
        case .largeFiles: return "analyze.section.largeFiles"
        case .images: return "analyze.section.images"
        case .videos: return "analyze.section.videos"
        case .duplicates: return "analyze.section.duplicates"
        }
    }
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

/// 文件瘦身：从磁盘分析的聚合视图发起，逐个压缩/转码/打包；
/// 结果不变小就丢弃，替换时原件移入废纸篓。
@MainActor
extension AppState {
    func slimCandidates(in section: AnalyzeSection) -> [SlimCandidate] {
        switch section {
        case .largeFiles:
            return analyzeLargeFiles.map {
                SlimCandidate(name: $0.name, path: $0.path, size: $0.size,
                              kind: MediaSlimPolicy.kind(forPath: $0.path))
            }
        case .images, .videos:
            let kind: MediaKind = section == .images ? .image : .video
            return analyzeMedia.filter { $0.kind == kind }.map {
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
        isSlimming = true
        log(L10n.shared.tf("slim.log.start", targets.count))
        slimTask = Task { [weak self] in
            let slimmer = MediaSlimmer()
            var outcomes: [SlimOutcome] = []
            for (index, target) in targets.enumerated() {
                if Task.isCancelled { break }
                self?.slimProgress = SlimProgress(index: index + 1, total: targets.count,
                                                  name: target.name, fraction: nil)
                let outcome = await slimmer.slim(path: target.path, options: options) { fraction in
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
        if cancelled == requested {
            noteHeaderReaction(nil)
        } else {
            noteHeaderReaction((failed > 0 || cancelled > 0) ? .attention : .success)
        }
        log(statusText)
        applySlimOutcomes(slimmed)
    }

    /// 就地更新清单，并让涉及目录的缓存失效，下次进入时重新统计。
    private func applySlimOutcomes(_ outcomes: [SlimOutcome]) {
        guard !outcomes.isEmpty else { return }
        let home = NSHomeDirectory()
        var removed = Set<String>()
        var added: [MediaFile] = []
        for outcome in outcomes {
            if outcome.replaced { removed.insert(outcome.path) }
            if let output = outcome.outputPath,
               let kind = MediaSlimPolicy.kind(forPath: output),
               MediaSlimPolicy.isEligible(output, home: home) {
                added.append(MediaFile(name: (output as NSString).lastPathComponent,
                                       path: output, size: outcome.newBytes, kind: kind))
            }
            analyzeCache.invalidate((outcome.path as NSString).deletingLastPathComponent)
        }
        analyzeMedia = (analyzeMedia.filter { !removed.contains($0.path) } + added)
            .sorted { $0.size > $1.size }
        analyzeLargeFiles.removeAll { removed.contains($0.path) }
        analyzeEntries.removeAll { removed.contains($0.path) }
        slimSelection.subtract(removed)
        slimSelection.subtract(outcomes.map(\.path))
    }
}
