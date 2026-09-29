import AppKit
import Foundation

enum AnalyzeMode: String, CaseIterable, Identifiable {
    case directories, largeFiles, images, videos
    var id: String { rawValue }
}

struct SlimProgress: Equatable {
    let index: Int
    let total: Int
    let name: String
    var fraction: Double?
}

/// 聚合视图里的一行：大文件、图片或视频。只有位于用户自管位置的文件可勾选瘦身。
struct SlimCandidate: Identifiable, Equatable {
    let name: String
    let path: String
    let size: UInt64
    let kind: MediaKind?
    let eligible: Bool
    var id: String { path }
    var operation: SlimOperation { SlimOperation.operation(for: path) }
}

/// 文件瘦身：从磁盘分析的聚合视图发起，逐个压缩/转码/打包；
/// 结果不变小就丢弃，替换时原件移入废纸篓。
@MainActor
extension AppState {
    var slimCandidates: [SlimCandidate] {
        switch analyzeMode {
        case .directories:
            return []
        case .largeFiles:
            let home = NSHomeDirectory()
            return analyzeLargeFiles.map {
                SlimCandidate(name: $0.name, path: $0.path, size: $0.size,
                              kind: MediaSlimPolicy.kind(forPath: $0.path),
                              eligible: MediaSlimPolicy.isEligible($0.path, home: home))
            }
        case .images, .videos:
            let kind: MediaKind = analyzeMode == .images ? .image : .video
            return analyzeMedia.filter { $0.kind == kind }.map {
                SlimCandidate(name: $0.name, path: $0.path, size: $0.size, kind: $0.kind, eligible: true)
            }
        }
    }

    var slimSelectedCandidates: [SlimCandidate] {
        slimCandidates.filter { $0.eligible && slimSelection.contains($0.path) }
    }

    var slimSelectedBytes: UInt64 {
        slimSelectedCandidates.reduce(0) { $0 &+ $1.size }
    }

    func setAnalyzeMode(_ mode: AnalyzeMode) {
        guard analyzeMode != mode else { return }
        analyzeMode = mode
        slimSelection.removeAll()
    }

    func toggleSlimSelection(_ candidate: SlimCandidate) {
        guard candidate.eligible, !isBusy else { return }
        if slimSelection.contains(candidate.path) {
            slimSelection.remove(candidate.path)
        } else {
            slimSelection.insert(candidate.path)
        }
    }

    func selectAllSlimCandidates() {
        let eligible = slimCandidates.filter(\.eligible).map(\.path)
        if eligible.allSatisfy(slimSelection.contains) {
            slimSelection.removeAll()
        } else {
            slimSelection = Set(eligible)
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
