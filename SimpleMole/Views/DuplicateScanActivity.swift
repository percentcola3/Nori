import SwiftUI

/// Frequent progress changes invalidate only the caption beside the bundled SVG.
struct DuplicateScanActivity: View {
    @ObservedObject var progress: DuplicateScanProgressStore
    let onCancel: () -> Void
    @ObservedObject private var l10n = L10n.shared

    private var status: String {
        guard let event = progress.progress else { return l10n.tf("duplicates.status.enumerating", 0) }
        switch event.phase {
        case "enumerating":
            return l10n.tf("duplicates.status.enumerating", event.scannedFiles)
        case "similar-images", "similar-grouping":
            return l10n.tf("duplicates.status.images", event.processedFiles, event.totalCandidates)
        default:
            return l10n.tf("duplicates.status.hashing", event.processedFiles, event.totalCandidates)
        }
    }

    private var currentPath: String {
        guard let path = progress.progress?.currentPath, !path.isEmpty else { return "" }
        let home = NSHomeDirectory()
        return path == home || path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    var body: some View {
        NoriPlaceholderStage { size in
            NoriStatusAnimation(mood: .working, size: size, assetName: "nori-disk")
            Text(status)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .animation(nil, value: status)
            Text(currentPath)
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).frame(maxWidth: 460)
                .animation(nil, value: currentPath)
            Button(action: onCancel) {
                Label(l10n.t("common.cancel"), systemImage: "xmark.circle")
            }
            .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
        }
    }
}
