import AppKit
import ImageIO
import QuickLook
import SwiftUI

/// 扫描范围与磁盘分析列表独立；所有删除项都由用户逐个选择。
struct DuplicateFilesView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var l10n = L10n.shared
    @State private var previewURL: URL?
    @State private var showTrashConfirmation = false

    private var working: Bool {
        state.isScanningDuplicates || state.isDeletingDuplicates
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            scope
            modePicker
            status
            Divider()
            results
            Divider()
            footer
        }
        .padding(20)
        .frame(width: 800, height: 660)
        .quickLookPreview($previewURL)
        .interactiveDismissDisabled(working)
        .alert(l10n.tf("duplicates.trash.title", state.duplicateSelectedCount),
               isPresented: $showTrashConfirmation) {
            Button(l10n.t("common.cancel"), role: .cancel) {}
            Button(l10n.t("duplicates.trash"), role: .destructive) {
                state.deleteSelectedDuplicates()
            }
        } message: {
            Text(trashConfirmationMessage)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(l10n.t("duplicates.title"))
                    .font(.system(size: 17, weight: .semibold))
                Text(l10n.t("duplicates.scope.hint"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(l10n.t("common.done")) { state.showDuplicateFiles = false }
                .buttonStyle(SecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
                .disabled(working)
        }
    }

    private var scope: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(l10n.t("duplicates.scope.title"))
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                suggestedFolder("Downloads", key: "duplicates.scope.downloads")
                suggestedFolder("Documents", key: "duplicates.scope.documents")
                Button { state.chooseDuplicateFolders() } label: {
                    Label(l10n.t("duplicates.scope.choose"), systemImage: "folder.badge.plus")
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(working || state.isBusy)
            }
            if state.duplicateRoots.isEmpty {
                Text(l10n.t("duplicates.scope.empty"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 3)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(state.duplicateRoots, id: \.self) { path in
                            HStack(spacing: 8) {
                                Image(systemName: "folder")
                                    .foregroundStyle(.secondary)
                                Text(displayPath(path))
                                    .font(.system(size: 10, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 4)
                                Button { state.removeDuplicateRoot(path) } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(MoleIconButtonStyle(size: 20))
                                .accessibilityLabel(l10n.t("duplicates.scope.remove") + ": " + path)
                                .disabled(working || state.isBusy)
                            }
                        }
                    }
                }
                .frame(height: min(CGFloat(state.duplicateRoots.count) * 24, 72))
            }
            Text(l10n.t("duplicates.scope.exclusions"))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.surface2))
    }

    private func suggestedFolder(_ name: String, key: String) -> some View {
        let path = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(name).path
        return Button { state.addDuplicateRoot(path) } label: {
            Label(l10n.t(key), systemImage: "plus")
        }
        .buttonStyle(SecondaryButtonStyle())
        .disabled(working || state.isBusy || state.duplicateRoots.contains {
            path == $0 || path.hasPrefix($0 + "/")
        })
    }

    private var modePicker: some View {
        HStack(spacing: 12) {
            Picker(l10n.t("duplicates.mode.label"), selection: Binding(
                get: { state.duplicateMode },
                set: { state.setDuplicateMode($0) }
            )) {
                Text(l10n.t("duplicates.mode.exact")).tag(DuplicateMode.exact)
                Text(l10n.t("duplicates.mode.similar")).tag(DuplicateMode.similarImages)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 310)
            .disabled(working || state.isBusy)
            Spacer()
            if state.isScanningDuplicates {
                Button(l10n.t("common.cancel")) { state.cancelDuplicateScan() }
                    .buttonStyle(SecondaryButtonStyle())
            } else {
                Button { state.scanDuplicateFiles() } label: {
                    Label(l10n.t("duplicates.scan"), systemImage: "magnifyingglass")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(state.duplicateRoots.isEmpty || working || state.isBusy)
            }
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 5) {
            if state.duplicateMode == .similarImages {
                Text(l10n.t("duplicates.similar.hint"))
                    .foregroundStyle(Color.warning)
                Text(l10n.t("duplicates.sharpness.hint"))
                    .foregroundStyle(.secondary)
            }
            if !state.duplicateStatus.isEmpty {
                HStack(spacing: 6) {
                    if working { ProgressView().controlSize(.mini) }
                    Text(state.duplicateStatus)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
            if !state.duplicateCoverage.isEmpty {
                Text(state.duplicateCoverage)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
        }
        .font(.system(size: 11))
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var results: some View {
        if state.duplicateGroups.isEmpty {
            EmptyStateView(symbol: state.isScanningDuplicates ? "magnifyingglass" : "square.on.square",
                           title: l10n.t(emptyTitleKey),
                           subtitle: l10n.t(emptySubtitleKey))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(Array(state.duplicateGroups.enumerated()), id: \.element.id) { index, group in
                        groupCard(group, index: index)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func groupCard(_ group: DuplicateFileGroup, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
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
            ForEach(group.members) { member in
                DuplicateFileRow(
                    member: member,
                    isSelected: state.duplicateSelection.contains(member.path),
                    canSelect: state.canSelectDuplicate(member, group: group),
                    disabled: working || state.isBusy,
                    onToggle: { state.toggleDuplicateSelection(member) },
                    onPreview: { previewURL = URL(fileURLWithPath: member.path) }
                )
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.surface2))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.hairline, lineWidth: 1))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(state.duplicateSelectedCount == 0
                 ? l10n.t("duplicates.selection.hint")
                 : l10n.tf("duplicates.selection.count", state.duplicateSelectedCount,
                           ByteFormat.format(state.duplicateSelectedBytes)))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Button { showTrashConfirmation = true } label: {
                Label(l10n.t("duplicates.trash"), systemImage: "trash")
            }
            .buttonStyle(DangerButtonStyle())
            .disabled(state.duplicateSelectedCount == 0 || working || state.isBusy)
        }
    }

    private var emptyTitleKey: String {
        if state.isScanningDuplicates { return "duplicates.empty.scanning" }
        return state.duplicateScanFinished ? "duplicates.empty.none" : "duplicates.empty.initial"
    }

    private var emptySubtitleKey: String {
        if state.isScanningDuplicates { return "duplicates.empty.scanningHint" }
        return state.duplicateScanFinished ? "duplicates.empty.noneHint" : "duplicates.empty.initialHint"
    }

    private var trashConfirmationMessage: String {
        let selection = l10n.tf("duplicates.selection.count", state.duplicateSelectedCount,
                                ByteFormat.format(state.duplicateSelectedBytes))
        let explanation = l10n.t(state.duplicateMode == .exact
                                 ? "duplicates.trash.message" : "duplicates.trash.similarMessage")
        return selection + "\n\n" + explanation
    }

    private func displayPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

private struct DuplicateFileRow: View {
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
private struct DuplicateThumbnail: View {
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
