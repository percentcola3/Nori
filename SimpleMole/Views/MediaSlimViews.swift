import SwiftUI
import AppKit
import QuickLookThumbnailing

/// 磁盘分析的视图切换：目录浏览 / 大文件 / 图片 / 视频。
struct AnalyzeModePicker: View {
    @ObservedObject var state: AppState
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        PillPicker(items: AnalyzeMode.allCases.map(title), selection: Binding(
            get: { AnalyzeMode.allCases.firstIndex(of: state.analyzeMode) ?? 0 },
            set: { state.setAnalyzeMode(AnalyzeMode.allCases[$0]) }))
    }

    private func title(_ mode: AnalyzeMode) -> String {
        let summary = state.analyzeMediaSummary
        switch mode {
        case .directories: return l10n.t("analyze.mode.directories")
        case .largeFiles: return l10n.tf("analyze.mode.largeFiles", state.analyzeLargeFiles.count)
        case .images: return l10n.tf("analyze.mode.images", summary.imageCount)
        case .videos: return l10n.tf("analyze.mode.videos", summary.videoCount)
        }
    }
}

/// 聚合清单：缩略图 + 名称 + 所在目录 + 大小；只有用户自管位置的文件可勾选。
struct SlimCandidateListView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        let candidates = state.slimCandidates
        if candidates.isEmpty {
            EmptyStateView(symbol: emptySymbol,
                           title: l10n.t("slim.empty.title"),
                           subtitle: l10n.t(emptySubtitleKey))
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Text(headline)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    if candidates.contains(where: \.eligible) {
                        Button(l10n.t("slim.selectAll")) { state.selectAllSlimCandidates() }
                            .buttonStyle(SecondaryButtonStyle())
                            .controlSize(.small)
                            .disabled(state.isBusy)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(candidates) { candidate in
                            SlimCandidateRow(candidate: candidate,
                                             isSelected: state.slimSelection.contains(candidate.path),
                                             disabled: state.isBusy) {
                                state.toggleSlimSelection(candidate)
                            } onReveal: {
                                state.revealPath(candidate.path)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var headline: String {
        let summary = state.analyzeMediaSummary
        switch state.analyzeMode {
        case .images:
            return l10n.tf("slim.headline.images", summary.imageCount,
                           ByteFormat.format(summary.imageBytes), MediaSlimPolicy.perKindCap)
        case .videos:
            return l10n.tf("slim.headline.videos", summary.videoCount,
                           ByteFormat.format(summary.videoBytes), MediaSlimPolicy.perKindCap)
        default:
            return l10n.t("slim.headline.largeFiles")
        }
    }

    private var emptySymbol: String {
        switch state.analyzeMode {
        case .images: return "photo.on.rectangle.angled"
        case .videos: return "film"
        default: return "doc.zipper"
        }
    }

    private var emptySubtitleKey: String {
        switch state.analyzeMode {
        case .images: return "slim.empty.images"
        case .videos: return "slim.empty.videos"
        default: return "slim.empty.largeFiles"
        }
    }
}

private struct SlimCandidateRow: View {
    let candidate: SlimCandidate
    let isSelected: Bool
    let disabled: Bool
    let onToggle: () -> Void
    let onReveal: () -> Void
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggle) {
                HStack(spacing: 10) {
                    Image(systemName: candidate.eligible
                          ? (isSelected ? "checkmark.circle.fill" : "circle") : "lock.fill")
                        .font(.system(size: candidate.eligible ? 13 : 10))
                        .foregroundStyle(isSelected
                            ? AnyShapeStyle(Color.moleAccentText) : AnyShapeStyle(.tertiary))
                        .frame(width: 18)
                    MediaThumbnail(path: candidate.path, size: candidate.size, kind: candidate.kind)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(candidate.name)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(displayDirectory)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 6)
                    Text(l10n.t(candidate.eligible ? operationKey : "slim.readonly"))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.quaternary))
                    SizeBadge(text: ByteFormat.format(candidate.size), prominent: isSelected)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(MoleSelectableRowButtonStyle(isSelected: isSelected, verticalPadding: 5))
            .disabled(disabled || !candidate.eligible)

            Button(action: onReveal) {
                Image(systemName: "folder")
            }
            .buttonStyle(MoleIconButtonStyle(isActive: false, tint: .secondary, size: 24))
        }
    }

    private var operationKey: String {
        switch candidate.operation {
        case .compressImage: return "slim.op.image"
        case .transcodeVideo: return "slim.op.video"
        case .archive: return "slim.op.archive"
        }
    }

    private var displayDirectory: String {
        let directory = (candidate.path as NSString).deletingLastPathComponent
        let home = NSHomeDirectory()
        return directory.hasPrefix(home) ? "~" + directory.dropFirst(home.count) : directory
    }
}

private struct MediaThumbnail: View {
    let path: String
    let size: UInt64
    let kind: MediaKind?
    @Environment(\.displayScale) private var displayScale
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color.surface2)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .bottomTrailing) {
            if kind == .video {
                Image(systemName: "play.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(.white)
                    .padding(3)
                    .background(Circle().fill(.black.opacity(0.55)))
                    .padding(2)
            }
        }
        .task(id: "\(path)#\(size)", priority: .utility) {
            guard kind != nil else { return }
            image = await MediaThumbnailStore.thumbnail(path: path, size: size, scale: displayScale)
        }
    }

    private var symbol: String {
        switch kind {
        case .image: return "photo"
        case .video: return "film"
        case nil: return "doc"
        }
    }
}

enum MediaThumbnailStore {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 400
        cache.totalCostLimit = 48 * 1_024 * 1_024
        return cache
    }()

    static func thumbnail(path: String, size: UInt64, scale: CGFloat) async -> NSImage? {
        let key = "\(path)#\(size)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let request = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: path),
            size: CGSize(width: 40, height: 40),
            scale: scale,
            representationTypes: .thumbnail)
        let image: NSImage? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                    continuation.resume(returning: representation?.nsImage)
                }
            }
        } onCancel: {
            QLThumbnailGenerator.shared.cancel(request)
        }
        guard !Task.isCancelled, let image else { return nil }
        cache.setObject(image, forKey: key, cost: Int(40 * scale * 40 * scale * 4))
        return image
    }
}

/// 瘦身选项：按选中文件的类型只展示相关项；这一步就是执行前的确认。
struct SlimOptionsSheet: View {
    @ObservedObject var state: AppState
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        let selected = state.slimSelectedCandidates
        let operations = Set(selected.map(\.operation))
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(l10n.tf("slim.sheet.title", selected.count, ByteFormat.format(state.slimSelectedBytes)))
                    .font(.system(size: 14, weight: .semibold))
                Text(l10n.t("slim.sheet.subtitle"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if operations.contains(.compressImage) {
                section(l10n.tf("slim.sheet.images", selected.filter { $0.operation == .compressImage }.count)) {
                    Picker(l10n.t("slim.format"), selection: $state.slimOptions.imageFormat) {
                        Text(l10n.t("slim.format.keep")).tag(SlimOptions.ImageFormat.keep)
                        Text(l10n.t("slim.format.heic")).tag(SlimOptions.ImageFormat.heic)
                    }
                    .pickerStyle(.segmented)
                    Picker(l10n.t("slim.quality"), selection: $state.slimOptions.quality) {
                        Text(l10n.t("slim.quality.high")).tag(SlimOptions.Quality.high)
                        Text(l10n.t("slim.quality.medium")).tag(SlimOptions.Quality.medium)
                        Text(l10n.t("slim.quality.low")).tag(SlimOptions.Quality.low)
                    }
                    .pickerStyle(.segmented)
                    Toggle(l10n.t("slim.limitEdge"), isOn: $state.slimOptions.limitLongEdge)
                        .toggleStyle(.checkbox)
                    Text(l10n.t(state.slimOptions.imageFormat == .keep
                                ? "slim.format.keep.hint" : "slim.format.heic.hint"))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if operations.contains(.transcodeVideo) {
                section(l10n.tf("slim.sheet.videos", selected.filter { $0.operation == .transcodeVideo }.count)) {
                    Picker(l10n.t("slim.video"), selection: $state.slimOptions.videoPreset) {
                        Text(l10n.t("slim.video.p1080")).tag(SlimOptions.VideoPreset.p1080)
                        Text(l10n.t("slim.video.original")).tag(SlimOptions.VideoPreset.original)
                    }
                    .pickerStyle(.segmented)
                    Text(l10n.t("slim.video.hint"))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if operations.contains(.archive) {
                section(l10n.tf("slim.sheet.archive", selected.filter { $0.operation == .archive }.count)) {
                    Text(l10n.t("slim.archive.hint"))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            section(l10n.t("slim.result")) {
                Picker("", selection: $state.slimOptions.replaceOriginal) {
                    Text(l10n.t("slim.result.replace")).tag(true)
                    Text(l10n.t("slim.result.copy")).tag(false)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            HStack {
                Spacer()
                Button(l10n.t("common.cancel")) { state.showSlimSheet = false }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button { state.startSlim() } label: {
                    Label(l10n.t("slim.start"), systemImage: "arrow.down.right.and.arrow.up.left")
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty || state.isBusy)
            }
        }
        .padding(18)
        .frame(width: 440)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.surface2))
    }
}
