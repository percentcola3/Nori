import AppKit
import ImageIO
import SwiftUI

/// 大文件/图片/视频子分类卡片：头部汇总 + 预览行 + 展开全部。
struct SlimSectionCard: View {
    @ObservedObject var state: AppState
    let section: AnalyzeSection
    let candidates: [SlimCandidate]
    let isExpanded: Bool
    let onToggleExpand: () -> Void
    /// 按行所在目录发起“定时清理”规则创建（磁盘分析目录未经清理策略
    /// 验证，规则创建时需要用户确认“仅可再生内容”）。
    let onScheduleDirectory: (String) -> Void
    @ObservedObject private var l10n = L10n.shared

    private static let previewCount = 5

    private var visibleCandidates: [SlimCandidate] {
        isExpanded ? candidates : Array(candidates.prefix(Self.previewCount))
    }

    var body: some View {
        VStack(spacing: 4) {
            header
            ForEach(visibleCandidates) { candidate in
                let directory = (candidate.path as NSString).deletingLastPathComponent
                SlimCandidateRow(
                    candidate: candidate,
                    isSelected: state.slimSelection.contains(candidate.path),
                    disabled: state.isBusy,
                    onToggle: { state.toggleSlimSelection(candidate) },
                    onReveal: { state.revealPath(candidate.path) },
                    onAutoClean: { onScheduleDirectory(directory) },
                    autoCleanCovered: state.autoCleanupRuleCovering(directory: directory) != nil
                )
            }
            if candidates.count > Self.previewCount {
                Button(action: onToggleExpand) {
                    Label(isExpanded ? l10n.t("analyze.section.collapse")
                                     : l10n.tf("analyze.section.showAll", candidates.count),
                          systemImage: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                }
                .buttonStyle(MolePlainButtonStyle())
                .disabled(state.isBusy)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.surface2))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.hairline, lineWidth: 1))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button(action: onToggleExpand) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14)
            }
            .buttonStyle(MolePlainButtonStyle())
            .disabled(state.isBusy)
            .accessibilityLabel(l10n.t(isExpanded ? "analyze.section.collapse"
                                                 : "analyze.section.expand"))
            Image(systemName: section.symbol)
                .font(.system(size: 11))
                .foregroundStyle(Color.moleAccentText)
            VStack(alignment: .leading, spacing: 1) {
                Text(l10n.t(section.titleKey))
                    .font(.system(size: 12, weight: .semibold))
                Text(summary)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 6)
            Button(l10n.t("slim.selectAll")) {
                state.toggleSelectAllSlimCandidates(in: section)
            }
            .buttonStyle(SecondaryButtonStyle())
            .controlSize(.small)
            .disabled(state.isBusy)
        }
    }

    private var summary: String {
        switch section {
        case .largeFiles:
            return l10n.tf("analyze.section.summary.files", candidates.count,
                           ByteFormat.format(candidates.reduce(0) { $0 + $1.size }))
        case .images:
            let summary = state.analyzeMediaSummary
            return l10n.tf("slim.headline.images", summary.imageCount,
                           ByteFormat.format(summary.imageBytes), MediaSlimPolicy.perKindCap)
        case .videos:
            let summary = state.analyzeMediaSummary
            return l10n.tf("slim.headline.videos", summary.videoCount,
                           ByteFormat.format(summary.videoBytes), MediaSlimPolicy.perKindCap)
        }
    }
}

/// 重复文件清单：不套卡片，标题行 + 模式/状态行 + 全量分组平铺，
/// 逐个勾选后清理（每组至少保留一份）。
struct DuplicatesSectionCard: View {
    @ObservedObject var state: AppState
    let onPreview: (String) -> Void
    @ObservedObject private var l10n = L10n.shared

    private var working: Bool {
        state.isScanningDuplicates || state.isDeletingDuplicates
    }

    var body: some View {
        VStack(spacing: 6) {
            headerRow
            statusLine
            if state.duplicateMode == .similarImages && !state.duplicateGroups.isEmpty {
                Text(l10n.t("duplicates.similar.hint"))
                    .font(.system(size: 10))
                    .foregroundStyle(Color.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(state.duplicateGroups.enumerated()), id: \.element.id) { index, group in
                if index > 0 {
                    Divider().padding(.leading, 2)
                }
                groupSection(group, index: index)
            }
            if state.duplicateGroups.isEmpty {
                emptyRow
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.on.square")
                .font(.system(size: 11))
                .foregroundStyle(Color.moleAccentText)
            VStack(alignment: .leading, spacing: 1) {
                Text(l10n.t("analyze.section.duplicates"))
                    .font(.system(size: 12, weight: .semibold))
                if !state.duplicateGroups.isEmpty {
                    Text(groupSummary)
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 6)
            if working {
                Button(l10n.t("common.cancel")) { state.cancelDuplicateScan() }
                    .buttonStyle(SecondaryButtonStyle())
                    .controlSize(.small)
            } else {
                Button { state.scanDuplicateFiles() } label: {
                    Label(l10n.t("duplicates.scan"), systemImage: "magnifyingglass")
                }
                .buttonStyle(SecondaryButtonStyle())
                .controlSize(.small)
                .disabled(state.isBusy)
            }
        }
    }

    private var groupSummary: String {
        if state.duplicateMode == .exact {
            return l10n.tf("analyze.section.summary.duplicates", state.duplicateGroups.count,
                           ByteFormat.format(state.duplicateReclaimableBytes))
        }
        return l10n.tf("analyze.section.summary.similar", state.duplicateGroups.count)
    }

    private var statusLine: some View {
        HStack(spacing: 8) {
            Picker(l10n.t("duplicates.mode.label"), selection: Binding(
                get: { state.duplicateMode },
                set: { state.setDuplicateMode($0) }
            )) {
                Text(l10n.t("duplicates.mode.exact")).tag(DuplicateMode.exact)
                Text(l10n.t("duplicates.mode.similar")).tag(DuplicateMode.similarImages)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)
            .disabled(working || state.isBusy)
            HStack(spacing: 6) {
                Text(statusText)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            .font(.system(size: 10))
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusText: String {
        if state.isAnalyzing { return l10n.t("analyze.section.waiting") }
        var parts: [String] = []
        if !state.duplicateStatus.isEmpty { parts.append(state.duplicateStatus) }
        if !state.duplicateCoverage.isEmpty { parts.append(state.duplicateCoverage) }
        if parts.isEmpty { parts.append(l10n.t("duplicates.status.idle")) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var emptyRow: some View {
        if state.duplicateScanFinished, !working {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.moleAccentText)
                Text(l10n.t("duplicates.empty.none"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.vertical, 2)
        }
    }

    /// 分组平铺：组头一行 + 成员行，无背景容器。
    private func groupSection(_ group: DuplicateFileGroup, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(l10n.tf(state.duplicateMode == .exact
                             ? "duplicates.group.exact" : "duplicates.group.similar",
                             index + 1, group.members.count))
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Text(l10n.t("duplicates.keepOne"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)
            ForEach(group.members) { member in
                DuplicateFileRow(
                    member: member,
                    isSelected: state.duplicateSelection.contains(member.path),
                    canSelect: state.canSelectDuplicate(member, group: group),
                    disabled: state.isBusy,
                    onToggle: { state.toggleDuplicateSelection(member) },
                    onPreview: { onPreview(member.path) }
                )
            }
        }
    }
}

/// 重复组内的一行：勾选删除、预览、在 Finder 中显示。
struct DuplicateFileRow: View {
    let member: DuplicateFileRecord
    let isSelected: Bool
    let canSelect: Bool
    let disabled: Bool
    let onToggle: () -> Void
    let onPreview: () -> Void
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggle) {
                HStack(spacing: 10) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14))
                        .foregroundStyle(isSelected ? Color.moleAccentText : Color.secondary)
                    DuplicateThumbnail(path: member.path, isImage: member.imageInfo != nil)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(member.name)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(member.path)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let info = member.imageInfo {
                            Text(l10n.tf("duplicates.dimensions", info.width, info.height)
                                 + " · " + l10n.tf("duplicates.quality", info.sharpness))
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(ByteFormat.format(member.size))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(MoleSelectableRowButtonStyle(isSelected: isSelected, verticalPadding: 6))
            .disabled(disabled || !canSelect)
            .accessibilityLabel(member.path)
            .accessibilityValue(isSelected ? l10n.t("duplicates.row.selected") : l10n.t("duplicates.row.kept"))
            Button(action: onPreview) { Image(systemName: "eye") }
                .buttonStyle(MoleIconButtonStyle(size: 26))
                .accessibilityLabel(l10n.t("duplicates.preview") + ": " + member.name)
                .disabled(disabled)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: member.path)])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(MoleIconButtonStyle(size: 26))
            .accessibilityLabel(l10n.t("duplicates.reveal") + ": " + member.name)
            .disabled(disabled)
        }
    }
}

/// ImageIO 直接生成小图；串行后台队列限制同时解码的图片数。
struct DuplicateThumbnail: View {
    let path: String
    let isImage: Bool
    @State private var thumbnail: NSImage?
    private static let queue = DispatchQueue(label: "Nori.duplicate-thumbnails", qos: .utility)

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color.surface1)
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: isImage ? "photo" : "doc")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: path) {
            thumbnail = nil
            guard isImage else { return }
            let image: CGImage? = await withCheckedContinuation { continuation in
                Self.queue.async {
                    let result = autoreleasepool { () -> CGImage? in
                        let options = [kCGImageSourceShouldCache: false] as CFDictionary
                        guard let source = CGImageSourceCreateWithURL(
                            URL(fileURLWithPath: path) as CFURL, options) else { return nil }
                        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: 128,
                            kCGImageSourceShouldCacheImmediately: true
                        ] as CFDictionary)
                    }
                    continuation.resume(returning: result)
                }
            }
            guard !Task.isCancelled, let image else { return }
            thumbnail = NSImage(cgImage: image, size: .zero)
        }
        .accessibilityHidden(true)
    }
}

extension AnalyzeSection {
    var symbol: String {
        switch self {
        case .largeFiles: return "doc.zipper"
        case .images: return "photo"
        case .videos: return "film"
        }
    }

    var titleKey: String {
        switch self {
        case .largeFiles: return "analyze.section.largeFiles"
        case .images: return "analyze.section.images"
        case .videos: return "analyze.section.videos"
        }
    }
}
