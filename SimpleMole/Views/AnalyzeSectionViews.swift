import AppKit
import ImageIO
import SwiftUI

/// 重复文件清单：不套卡片，标题行 + 模式/状态行 + 全量分组平铺，
/// 逐个勾选后清理（每组至少保留一份）。
struct DuplicatesSectionCard: View {
    @ObservedObject var state: AppState
    let onPreview: (String) -> Void
    var showsControls = true
    @ObservedObject private var l10n = L10n.shared

    @State private var collapsedGroups: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var working: Bool {
        state.isScanningDuplicates || state.isDeletingDuplicates
    }

    var body: some View {
        LazyVStack(spacing: 8) {
            if showsControls {
                headerRow
                statusLine
            }
            if state.duplicateGroups.contains(where: { $0.kind == .similarImages }) {
                Text(l10n.t("duplicates.similar.hint"))
                    .font(.system(size: 10))
                    .foregroundStyle(Color.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(state.duplicateGroups.enumerated()), id: \.element.id) { index, group in
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
                .disabled(state.isAnalysisTaskBusy)
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

    /// 与清理页相同：分组标题 + 缩进成员，使用同一个展开节奏。
    private func groupSection(_ group: DuplicateFileGroup, index: Int) -> some View {
        let collapsed = collapsedGroups.contains(group.id)
        // One linear count per group; each visible row then makes a constant-time decision.
        let unselectedCount = group.members.reduce(0) {
            $0 + (state.duplicateSelection.contains($1.path) ? 0 : 1)
        }
        return VStack(spacing: 8) {
            Button {
                withAnimation(reduceMotion ? nil : MoleMotion.panel) {
                    if collapsed { collapsedGroups.remove(group.id) }
                    else { collapsedGroups.insert(group.id) }
                }
            } label: {
                HStack(spacing: 8) {
                    DuplicateKindBadge(kind: group.kind)
                    Text(l10n.tf("duplicates.group.title", index + 1, group.members.count))
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                    Spacer()
                    Text(group.kind == .exact
                         ? l10n.tf("duplicates.group.reclaim", ByteFormat.format(
                            group.members.dropFirst().reduce(0) { $0 + $1.size }))
                         : l10n.t("duplicates.group.similarReview"))
                        .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(collapsed ? -90 : 0))
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .contentShape(Rectangle())
                .modifier(ListRowSurface(emphasis: .header))
            }
            .buttonStyle(MolePlainButtonStyle(pressedScale: 0.995))
            if !collapsed {
                LazyVStack(spacing: 8) {
                    ForEach(group.members) { member in
                        DuplicateFileRow(member: member,
                            isSelected: state.duplicateSelection.contains(member.path),
                            canSelect: DuplicateSelectionPolicy.canSelect(
                                isSelected: state.duplicateSelection.contains(member.path),
                                unselectedCount: unselectedCount), disabled: state.isAnalysisTaskBusy || state.isScanningDuplicates,
                            onToggle: { state.toggleDuplicateSelection(member) },
                            onPreview: { onPreview(member.path) })
                    }
                }
                .padding(.leading, 14)
                .transition(.molePanelReveal)
            }
        }
        .clipped()
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
                    DuplicateThumbnail(path: member.path,
                                       isImage: member.imageInfo != nil || DuplicateThumbnail.isImagePath(member.path))
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
                    if !isSelected {
                        DevTag(text: l10n.t("duplicates.row.keep"), color: .success)
                            .help(canSelect ? "" : l10n.t("duplicates.keepOne"))
                    }
                    Text(ByteFormat.format(member.size))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(MolePlainButtonStyle(pressedScale: 0.99))
            .disabled(disabled || !canSelect)
            .opacity(disabled ? 0.45 : 1)
            .accessibilityLabel(member.path)
            .accessibilityValue(isSelected ? l10n.t("duplicates.row.selected") : l10n.t("duplicates.row.kept"))
            Button(action: onPreview) { Image(systemName: "eye") }
                .buttonStyle(MoleIconButtonStyle(size: 26, showsBackground: false))
                .help(l10n.t("duplicates.preview"))
                .accessibilityLabel(l10n.t("duplicates.preview") + ": " + member.name)
                .disabled(disabled)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: member.path)])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(MoleIconButtonStyle(size: 26, showsBackground: false))
            .help(l10n.t("duplicates.reveal"))
            .accessibilityLabel(l10n.t("duplicates.reveal") + ": " + member.name)
            .disabled(disabled)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .modifier(ListRowSurface(selected: isSelected))
    }
}

struct DuplicateKindBadge: View {
    let kind: DuplicateMode
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        DevTag(text: l10n.t(kind == .exact ? "duplicates.mode.exact" : "duplicates.mode.similar"),
               color: kind == .exact ? .moleAccentText : .warning)
    }
}

/// ImageIO 直接生成小图；串行后台队列限制同时解码的图片数。
struct DuplicateThumbnail: View {
    let path: String
    let isImage: Bool

    static func isImagePath(_ path: String) -> Bool {
        ["png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "tif", "tiff", "bmp"]
            .contains((path as NSString).pathExtension.lowercased())
    }
    @State private var thumbnail: NSImage?
    private static let queue = DispatchQueue(label: "Nori.duplicate-thumbnails", qos: .utility,
                                             attributes: .concurrent)
    /// 滚回来的缩略图直接取缓存，不再重新解码。
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 600
        return cache
    }()

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
            if let cached = Self.cache.object(forKey: path as NSString) {
                thumbnail = cached
                return
            }
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
            let decoded = NSImage(cgImage: image, size: .zero)
            Self.cache.setObject(decoded, forKey: path as NSString)
            thumbnail = decoded
        }
        .accessibilityHidden(true)
    }
}
