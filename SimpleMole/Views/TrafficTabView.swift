import SwiftUI

/// 按应用展示系统采样流量与当前连接。
struct TrafficTabView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var store: TrafficMonitorStore
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var detailApp: TrafficAppSelection?

    init(state: AppState) {
        self.state = state
        self.store = state.trafficMonitor
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                if store.sampling {
                    ProgressView()
                        .controlSize(.mini)
                }
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Toggle(l10n.t("netmon.persistent"), isOn: $store.persistentMonitoring)
                    .toggleStyle(MoleSwitchToggleStyle())
                    .controlSize(.small)
                    .font(.system(size: 11))
                Button(l10n.t("netmon.reset")) { store.resetSession() }
                    .controlSize(.small)
                    .disabled(store.rows.isEmpty && store.physicalDown == 0 && store.physicalUp == 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            HStack(spacing: 6) {
                TrafficSummaryCard(title: l10n.t("netmon.card.physical"),
                                   down: store.physicalDown, up: store.physicalUp, tint: Color.moleAccentText)
                TrafficSummaryCard(title: l10n.t("netmon.card.tunnel"),
                                   down: store.tunnelDown, up: store.tunnelUp, tint: .secondary)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            // 会话信息与排序控件共用一行。
            HStack(spacing: 8) {
                Text(l10n.tf("netmon.session.started", store.sessionStartedAt.formatted(date: .abbreviated, time: .shortened))
                     + (store.historySaveFailed ? "" : " · " + l10n.t("netmon.history.saved")))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Picker(l10n.t("netmon.sort.title"), selection: $store.sortOrder) {
                    ForEach(TrafficSortOrder.allCases, id: \.rawValue) { order in
                        Text(l10n.t(order.titleKey)).tag(order)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
                Text(l10n.t("netmon.sort.descending"))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            if store.historySaveFailed {
                Text(l10n.t("netmon.history.saveFailed"))
                    .font(.system(size: 10))
                    .foregroundStyle(Color.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            if store.rows.isEmpty {
                EmptyStateView(symbol: "antenna.radiowaves.left.and.right",
                               title: l10n.t("netmon.empty.title"),
                               subtitle: l10n.t("netmon.empty.subtitle"))
                    .transition(reduceMotion ? .opacity : .moleStateSwap)
            } else {
                appList
                    .transition(reduceMotion ? .opacity : .moleStateSwap)
            }

            Text(l10n.t("netmon.footnote"))
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
        }
        .sheet(item: $detailApp) { selection in
            TrafficAppDetailSheet(store: store, appKey: selection.id)
                .frame(minWidth: 680, minHeight: 460)
        }
        // 首条采样到达时从空态切换到应用列表走弹簧过渡。
        .animation(reduceMotion ? nil : MoleMotion.panel, value: store.rows.isEmpty)
        .onAppear { store.setPageVisible(true) }
        .onDisappear { store.setPageVisible(false) }
    }

    private var statusText: String {
        if !store.bytesSourceAvailable { return l10n.t("netmon.status.bytesUnavailable") }
        if let lastSample = store.lastSample {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            return l10n.tf("netmon.status.lastSample", formatter.string(from: lastSample))
        }
        return l10n.t("netmon.status.sampling")
    }

    private var appList: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(Array(store.rows.enumerated()), id: \.element.id) { index, row in
                    Button {
                        detailApp = TrafficAppSelection(id: row.appKey)
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Text("\(index + 1)")
                                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(minWidth: 18)
                                ProcessAppIcon(
                                    row: ProcessRow(pid: row.representativePID,
                                                    startIdentity: "",
                                                    name: row.displayName,
                                                    detail: "",
                                                    isNativeApp: row.bundleIdentifier != nil,
                                                    cpu: 0, mem: 0, memBytes: 0),
                                    size: 26,
                                    fallbackSystemName: "terminal.fill",
                                    fallbackTint: .secondary,
                                    validatesNativeStartIdentity: false)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.displayName)
                                        .font(.system(size: 12, weight: .medium))
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    Text("\(l10n.t("netmon.col.sampleRate")) \(rateText(row.rateDown, row.rateUp))")
                                        .font(.system(size: 10).monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                TrafficMetric(label: l10n.t(store.sortOrder.titleKey),
                                              value: ByteFormat.short(store.sortOrder.bytes(in: row)),
                                              isElevated: false)
                                TrafficMetric(label: l10n.t("netmon.col.conns"),
                                              value: "\(row.connectionCount)",
                                              isElevated: false)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            Text("↓\(ByteFormat.short(row.sessionDown)) ↑\(ByteFormat.short(row.sessionUp))")
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Color.surface2))
                        .contentShape(RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
    }

    private func rateText(_ down: Double, _ up: Double) -> String {
        "↓\(ByteFormat.short(UInt64(max(down, 0))))/s ↑\(ByteFormat.short(UInt64(max(up, 0))))/s"
    }
}

// MARK: - 子组件

private struct TrafficAppSelection: Identifiable {
    let id: String
}

private struct TrafficSummaryCard: View {
    let title: String
    let down: UInt64
    let up: UInt64
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(tint)
                .lineLimit(1)
                .truncationMode(.tail)
            Text("↓\(ByteFormat.short(down)) ↑\(ByteFormat.short(up))")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.surface2))
    }
}

private struct TrafficMetric: View {
    let label: String
    let value: String
    let isElevated: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(label)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(isElevated ? Color.warning : Color.secondary)
                .lineLimit(1)
        }
        .frame(minWidth: 52, alignment: .trailing)
    }
}

private struct TrafficExitBadge: View {
    let kind: TrafficExitKind
    @ObservedObject private var l10n = L10n.shared

    private var tint: Color {
        switch kind {
        case .direct: return .secondary
        case .tunnel: return .indigo
        case .loopback: return .gray
        case .unknown: return .secondary
        }
    }

    var body: some View {
        Text(l10n.t(kind.titleKey))
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .frame(height: 16)
            .background(Capsule().fill(tint.opacity(0.12)))
            .fixedSize()
    }
}

/// 应用会话累计与当前端点，按稳定 appKey 读取最新数据。
private struct TrafficAppDetailSheet: View {
    @ObservedObject var store: TrafficMonitorStore
    let appKey: String
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.dismiss) private var dismiss

    private var row: TrafficAppRow? { store.rows.first { $0.appKey == appKey } }
    private var endpoints: [TrafficEndpointRow] { store.endpointsByApp[appKey] ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(row?.displayName ?? l10n.t("netmon.detail.title"))
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(16)

            if let row {
                HStack(spacing: 6) {
                    TrafficSummaryCard(title: l10n.t("netmon.detail.session"),
                                       down: row.sessionDown, up: row.sessionUp, tint: .secondary)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            Text(l10n.t("netmon.detail.scope"))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)

            HStack {
                Text(l10n.t("netmon.detail.endpoints"))
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.bottom, 6)

            if endpoints.isEmpty {
                Text(l10n.t("netmon.detail.noEndpoints"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 16)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(endpoints) { endpoint in
                            TrafficEndpointRowView(endpoint: endpoint)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 2)
                }
            }
        }
    }
}

private struct TrafficEndpointRowView: View {
    let endpoint: TrafficEndpointRow
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        HStack(spacing: 8) {
            TrafficExitBadge(kind: endpoint.kind)
            Text(endpoint.remote)
                .font(.system(size: 11, weight: .medium).monospaced())
                .textSelection(.enabled)
            Text(endpoint.proto.uppercased())
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Spacer()
            Text(l10n.tf("netmon.detail.active", endpoint.activeConnections))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.surface2))
    }
}
