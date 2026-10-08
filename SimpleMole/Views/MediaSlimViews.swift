import SwiftUI
import AppKit
import QuickLookThumbnailing

struct MediaThumbnail: View {
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
                .disabled(selected.isEmpty || state.isAnalysisTaskBusy)
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
