import SwiftUI

/// Plain content text: installation bytes and associated data have distinct
/// scopes. Session/state bytes never inherit the garbage label.
struct AgentStorageSummaryView: View {
    let storage: AgentStorageFootprint.Totals
    var isLoading = false
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if isLoading {
                Text(l10n.t("agents.storage.loading"))
            } else {
                Text(l10n.tf("agents.storage.identified", ByteFormat.format(storage.identifiedDataBytes)))
                Text(l10n.tf("agents.storage.breakdown", ByteFormat.format(storage.reclaimableBytes),
                             ByteFormat.format(storage.preservedBytes)))
                    .font(.system(size: 9))
                if !storage.measurementComplete {
                    Text(l10n.t("agents.storage.partial")).font(.system(size: 9))
                }
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}
