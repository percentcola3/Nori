import SwiftUI

struct IslandNetworkProbeView: View {
    @ObservedObject var controller: IslandNetworkProbe
    /// Live interface throughput (MB/s) feeding the gauge while a test runs.
    let liveDownloadMBps: Double
    let liveUploadMBps: Double
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var mode: IslandNetworkProbe.Mode = .ping
    @State private var lastStarted: IslandNetworkProbe.Mode?

    /// A test started from one tab is never hidden: while it runs, force its tab.
    private var activeMode: IslandNetworkProbe.Mode { controller.running ?? mode }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(l10n.t("island.network.title")).font(.system(size: 12, weight: .semibold))
            modeSwitch
            if activeMode == .ping { pingContent } else { bandwidthContent }
        }
        .padding(.horizontal, IslandLayout.contentInset + 10)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .onAppear {
            if controller.running == nil, controller.bandwidthResult != nil, controller.pingResult == nil {
                mode = .bandwidth
            }
        }
        .onChange(of: controller.running) { running in
            if let running { mode = running }
        }
    }

    private var modeSwitch: some View {
        HStack(spacing: 0) {
            segment(.ping, key: "island.network.ping", symbol: "waveform.path")
            segment(.bandwidth, key: "island.network.speed", symbol: "speedometer")
        }
        .padding(2)
        .background(Capsule().fill(Color.surface2))
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85), value: activeMode)
    }

    private func segment(_ segmentMode: IslandNetworkProbe.Mode, key: String, symbol: String) -> some View {
        Label(l10n.t(key), systemImage: symbol)
            .font(.system(size: 10.5, weight: .medium))
            .frame(maxWidth: .infinity).frame(height: 24)
            .background(Capsule().fill(activeMode == segmentMode ? Color.selectionFill : Color.clear))
            .foregroundStyle(activeMode == segmentMode ? Color.textPrimary : Color.textSecondary)
            .allowsHitTesting(false).accessibilityHidden(true)
            .overlay { IslandActionTarget(label: l10n.t(key)) { mode = segmentMode } }
    }

    private var pingContent: some View {
        Group {
            HStack(spacing: 7) {
                TextField(l10n.t("island.network.host"), text: $controller.host)
                    .textFieldStyle(.plain).font(.system(size: 11))
                    .padding(.horizontal, 10).frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.surface2))
                    .onSubmit { start(.ping) }
                    .disabled(controller.running != nil)
                    .accessibilityLabel(l10n.t("island.network.host"))
                    .frame(maxWidth: .infinity)
                probeButton("island.network.ping", symbol: "waveform.path", enabled: controller.running == nil) { start(.ping) }
                if controller.running == .ping {
                    probeButton("island.network.stop", symbol: "stop.fill") { controller.cancel() }
                }
            }
            if let result = controller.pingResult {
                HStack(spacing: 7) {
                    resultCell("island.network.latency", value: result.averageMilliseconds.map { String(format: "%.1f ms", $0) } ?? "—")
                    resultCell("island.network.loss", value: String(format: "%.1f%%", result.lossPercent))
                    resultCell("island.network.jitter", value: result.jitterMilliseconds.map { String(format: "%.1f ms", $0) } ?? "—")
                }
            }
            statusLine(for: .ping)
        }
    }

    private var gaugeValue: Double {
        if controller.running == .bandwidth {
            return max(liveDownloadMBps, liveUploadMBps) * 8
        }
        return controller.bandwidthResult?.downloadMbps ?? 0
    }

    private var gaugeCaption: String {
        if controller.running == .bandwidth { return l10n.t("island.network.live") }
        if controller.bandwidthResult != nil { return l10n.t("island.network.download") }
        return l10n.t("island.network.speed")
    }

    private var gaugeDetail: String? {
        guard controller.running != .bandwidth, let result = controller.bandwidthResult else { return nil }
        var detail = "↑ " + String(format: "%.1f Mbps", result.uploadMbps)
        if let idle = result.idleMilliseconds {
            detail += " · " + l10n.tf("island.network.idle", String(format: "%.1f", idle))
        }
        return detail
    }

    private var bandwidthContent: some View {
        Group {
            IslandSpeedGauge(value: gaugeValue, caption: gaugeCaption, detail: gaugeDetail)
                .frame(maxWidth: .infinity)
                .animation(reduceMotion ? nil : .spring(response: 0.6, dampingFraction: 0.8), value: gaugeValue)
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                if controller.running == .bandwidth {
                    probeButton("island.network.stop", symbol: "stop.fill") { controller.cancel() }
                } else {
                    probeButton("island.network.start", symbol: "speedometer", enabled: controller.running == nil) { start(.bandwidth) }
                }
                Spacer(minLength: 0)
            }
            statusLine(for: .bandwidth)
                .frame(maxWidth: .infinity)
        }
    }

    private func start(_ testMode: IslandNetworkProbe.Mode) {
        lastStarted = testMode
        controller.start(testMode)
    }

    @ViewBuilder
    private func statusLine(for testMode: IslandNetworkProbe.Mode) -> some View {
        if controller.running == testMode {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(l10n.t(testMode == .ping ? "island.network.pinging" : "island.network.measuring"))
            }.font(.system(size: 10)).foregroundStyle(.secondary)
        } else if controller.running == nil, let error = controller.errorKey,
                  lastStarted == nil || lastStarted == testMode {
            Text(l10n.t(error)).font(.system(size: 10)).foregroundStyle(Color.warning)
                .fixedSize(horizontal: false, vertical: true)
        } else if controller.running == nil, controller.stopped,
                  lastStarted == nil || lastStarted == testMode {
            Text(l10n.t("island.network.stopped")).font(.system(size: 10)).foregroundStyle(.secondary)
        } else if controller.running == nil, testMode == .bandwidth, let result = controller.bandwidthResult {
            Text(l10n.t(result.summaryKey))
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
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
            .padding(.horizontal, 11).frame(height: 28)
            .background(Capsule().fill(Color.surface2))
            .foregroundStyle(enabled ? Color.textPrimary : Color.textSecondary)
            .allowsHitTesting(false).accessibilityHidden(true)
            .overlay { IslandActionTarget(label: l10n.t(key), isEnabled: enabled, action: action) }
    }
}
