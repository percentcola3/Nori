import SwiftUI

/// The operation stays on one page from preparation through the result.
/// While working, only the current file changes; result feedback appears after completion.
struct NoriCleanupTaskStage: View {
    enum Phase: Hashable { case working, success, attention }
    enum ScanSource {
        case cleanup, agents

        var titleKey: String { self == .agents ? "agents.scan" : "cleanup.scan" }
        var symbol: String { self == .agents ? "sparkle.magnifyingglass" : "magnifyingglass" }
    }

    let phase: Phase
    var progress: CleanupTaskProgress? = nil
    var statusText = ""
    var details: [String] = []
    var applications: [String] = []
    var completedCount = 0
    var reclaimedBytes: UInt64 = 0
    var feedbackID = 0
    var scanSource: ScanSource = .cleanup
    var scanDisabled = false
    var onScan: (() -> Void)? = nil

    @ObservedObject private var l10n = L10n.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct CelebrationIdentity: Hashable {
        let phase: Phase
        let feedbackID: Int
        let reduceMotion: Bool
    }

    var body: some View {
        if phase == .working {
            NoriPlaceholderStage { size in
                NoriStatusAnimation(mood: .tidying, size: size, assetName: "nori-tidying")
                NoriCurrentFileView(path: progress?.phase == .cleaning ? progress?.currentItem ?? "" : "")
            }
        } else {
        GeometryReader { geometry in
            let contentWidth = min(560, max(0, geometry.size.width - 48))
            let size = min(220, max(140, min(geometry.size.width * 0.28,
                                           geometry.size.height * 0.30)))
            ScrollView {
                VStack(spacing: 18) {
                    NoriStatusAnimation(mood: mood, size: size,
                                        assetName: phase == .working ? "nori-tidying" : nil)
                        .id(CelebrationIdentity(phase: phase, feedbackID: feedbackID,
                                                reduceMotion: reduceMotion))
                    feedback(maxDetailHeight: min(180, geometry.size.height * 0.25))
                }
                .frame(width: contentWidth)
                .frame(maxWidth: .infinity, minHeight: max(0, geometry.size.height - 48))
                .padding(24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var mood: NoriMood {
        switch phase {
        case .working: return .tidying
        case .success: return .success
        case .attention: return .attention
        }
    }

    @ViewBuilder
    private func feedback(maxDetailHeight: CGFloat) -> some View {
        switch phase {
        case .working:
            NoriCurrentFileView(path: progress?.phase == .cleaning ? progress?.currentItem ?? "" : "")
        case .success:
            resultSummary(icon: "checkmark.circle.fill", tint: .success) {
                Text(l10n.tf("cleanup.task.reclaimed", ByteFormat.format(reclaimedBytes)))
                    .font(.system(size: 17, weight: .semibold).monospacedDigit())
                    .multilineTextAlignment(.center)
            }
        case .attention:
            VStack(spacing: 14) {
                resultSummary(icon: "exclamationmark.triangle.fill", tint: .danger) {
                    Text(l10n.t("cleanup.task.failed"))
                        .font(.system(size: 15, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !applications.isEmpty {
                    Text(l10n.tf("cleanup.task.closeApps", applications.joined(separator: ", ")))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.warning)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !details.isEmpty {
                    ViewThatFits(in: .vertical) {
                        detailText
                        ScrollView { detailText }
                    }
                    .frame(maxHeight: maxDetailHeight)
                    .fixedSize(horizontal: false, vertical: true)
                }
                scanButton
            }
        }
    }

    private var detailText: some View {
        Text(details.joined(separator: "\n\n"))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    /// 图标和文字直接显示在结果舞台上，不再单独垫一层卡片。
    private func resultSummary<Label: View>(icon: String, tint: Color,
                                         @ViewBuilder label: () -> Label) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(tint)
            label()
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var scanButton: some View {
        if let onScan {
            Button(action: onScan) {
                Label(l10n.t(scanSource.titleKey), systemImage: scanSource.symbol)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(scanDisabled)
        }
    }
}

/// Shared compact file activity for scanning and cleanup. A fixed line prevents
/// changing paths from shifting the surrounding controls or wrapping.
struct NoriCurrentFileView: View {
    let path: String

    private var displayPath: String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    var body: some View {
        Text(displayPath)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: 320)
            .frame(height: 18)
            .animation(nil, value: path)
            .help(path)
            .accessibilityAddTraits(.updatesFrequently)
    }
}
