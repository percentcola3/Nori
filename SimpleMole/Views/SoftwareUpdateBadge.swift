import SwiftUI

struct SoftwareUpdateBadge: View {
    let result: SoftwareUpdateResult?
    let isChecking: Bool
    var showsInstalled = false
    var externalPending = false
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        HStack(spacing: 6) {
            if showsInstalled, let result, !result.installed.isEmpty {
                Text(result.installed).foregroundStyle(.secondary)
            }
            if isChecking {
                Text(l10n.t("software.updates.checking")).foregroundStyle(.secondary)
            } else if externalPending {
                Text(l10n.t("software.install.external")).foregroundStyle(.secondary)
            } else if let result {
                Text(label(result))
                    .foregroundStyle(result.state == .available ? Color.success : Color.secondary)
                    .help(result.state == .unsupported ? l10n.t("software.updates.unsupportedHint") : result.source)
            }
        }
        .font(.system(size: 10))
        .lineLimit(1)
    }

    private func label(_ result: SoftwareUpdateResult) -> String {
        switch result.state {
        case .available: return l10n.tf("software.updates.available", result.latest ?? "")
        case .current: return l10n.t("software.updates.current")
        case .unsupported: return l10n.t("software.updates.unsupported")
        case .failed: return l10n.t("software.updates.failed")
        }
    }
}
