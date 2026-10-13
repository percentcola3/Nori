import SwiftUI

struct IslandNetworkProbeView: View {
    @ObservedObject var controller: IslandNetworkProbe
    @ObservedObject private var l10n = L10n.shared
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(l10n.t("island.network.title")).font(.system(size: 12, weight: .semibold))
                Spacer()
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                    .frame(width: 24, height: 24).allowsHitTesting(false).accessibilityHidden(true)
                    .overlay { IslandActionTarget(label: l10n.t("island.network.close"), action: onClose) }
            }
            HStack(spacing: 7) {
                Text("Ping").font(.system(size: 11, weight: .medium))
                TextField(l10n.t("island.network.host"), text: $controller.host)
                    .textFieldStyle(.plain).font(.system(size: 11))
                    .padding(.horizontal, 8).frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.surface2))
                    .onSubmit { controller.start(.ping) }
                    .disabled(controller.running != nil)
                    .accessibilityLabel(l10n.t("island.network.host"))
            }
            HStack(spacing: 6) {
                probeButton("island.network.ping", symbol: "waveform.path", enabled: controller.running == nil) { controller.start(.ping) }
                probeButton("island.network.speed", symbol: "speedometer", enabled: controller.running == nil) { controller.start(.bandwidth) }
                if controller.running != nil {
                    probeButton("island.network.stop", symbol: "stop.fill") { controller.cancel() }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 7) {
                resultCell("island.network.latency", value: controller.pingResult?.averageMilliseconds.map { String(format: "%.1f ms", $0) } ?? "—")
                resultCell("island.network.loss", value: controller.pingResult.map { String(format: "%.1f%%", $0.lossPercent) } ?? "—")
            }
            HStack(spacing: 7) {
                resultCell("island.network.download", value: controller.bandwidthResult.map { String(format: "%.1f Mbps", $0.downloadMbps) } ?? "—")
                resultCell("island.network.upload", value: controller.bandwidthResult.map { String(format: "%.1f Mbps", $0.uploadMbps) } ?? "—")
            }
            if let latency = controller.bandwidthResult?.idleMilliseconds {
                Text(l10n.tf("island.network.idle", String(format: "%.1f", latency)))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if let running = controller.running {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(l10n.t(running == .ping ? "island.network.pinging" : "island.network.measuring"))
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            } else if let error = controller.errorKey {
                Text(l10n.t(error)).font(.system(size: 10)).foregroundStyle(Color.warning)
                    .fixedSize(horizontal: false, vertical: true)
            } else if controller.stopped {
                Text(l10n.t("island.network.stopped")).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Text(l10n.t("island.network.hint"))
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }.padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func resultCell(_ key: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(l10n.t(key)).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 15, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(9)
        .modifier(ListRowSurface())
    }

    private func probeButton(_ key: String, symbol: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Label(l10n.t(key), systemImage: symbol).font(.system(size: 10.5, weight: .medium))
            .padding(.horizontal, 9).frame(height: 28)
            .background(Capsule().fill(Color.surface2))
            .foregroundStyle(enabled ? Color.primary : Color.secondary)
            .allowsHitTesting(false).accessibilityHidden(true)
            .overlay { IslandActionTarget(label: l10n.t(key), isEnabled: enabled, action: action) }
    }
}
