import SwiftUI

/// The operation stays on one page from preparation through the result.
/// While working, only the current file changes; result feedback appears after completion.
struct NoriCleanupTaskStage: View {
    enum Phase: Hashable { case working, success, attention }

    let phase: Phase
    var progress: CleanupTaskProgress? = nil
    var statusText = ""
    var details: [String] = []
    var applications: [String] = []
    var completedCount = 0
    var reclaimedBytes: UInt64 = 0
    var feedbackID = 0
    var retryAvailable = false
    var onRetry: (() -> Void)? = nil

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
            resultCard(icon: "checkmark.circle.fill", tint: .success) {
                Text(l10n.tf("cleanup.task.reclaimed", ByteFormat.format(reclaimedBytes)))
                    .font(.system(size: 17, weight: .semibold).monospacedDigit())
                    .multilineTextAlignment(.center)
            }
        case .attention:
            VStack(spacing: 14) {
                resultCard(icon: "exclamationmark.triangle.fill", tint: .danger) {
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
                    ScrollView {
                        Text(details.joined(separator: "\n\n"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .frame(maxHeight: maxDetailHeight)
                }
                cleanupButton
            }
        }
    }

    /// 结果摘要卡：surface 底色承托状态图标与关键数字，动画后随舞台一起离场。
    private func resultCard<Label: View>(icon: String, tint: Color,
                                         @ViewBuilder label: () -> Label) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(tint)
            label()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.surface2))
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var cleanupButton: some View {
        if let onRetry {
            Button(action: onRetry) {
                Label(l10n.t("cleanup.quickClean"), systemImage: "trash.fill")
            }
            .buttonStyle(PrimaryButtonStyle())
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
