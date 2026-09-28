import AppKit
import SwiftUI

enum IslandLayout {
    static let panelWidth: CGFloat = 300
    static let handleWidth: CGFloat = 108
    static let handleHeight: CGFloat = 20
    static let metricsHeight: CGFloat = 60
    static let detailBudget: CGFloat = 340
    static let windowMargin: CGFloat = 14
    static let hitSpaceName = "islandRoot"
}

extension AppState.IslandItem {
    var systemImage: String {
        switch self {
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .disk: return "internaldrive"
        case .network: return "network"
        }
    }
    var labelKey: String { "island.item.\(rawValue)" }
    var resource: IslandResource? {
        switch self {
        case .cpu: return .cpu
        case .memory: return .memory
        default: return nil
        }
    }
}

struct FloatingIslandView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var l10n = L10n.shared
    var safeTop: CGFloat = 0
    var collapsedWidth: CGFloat = IslandLayout.handleWidth
    var onOpenMain: () -> Void
    var onHitFrameChange: (CGRect) -> Void
    var onExpandedChange: (Bool) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var islandNamespace
    @FocusState private var focusedResource: IslandResource?
    @State private var expanded = false
    @State private var selectedResource: IslandResource?
    @State private var hoveredResource: IslandResource?
    @State private var hoverDebounce: Task<Void, Never>?
    @State private var resourceDebounce: Task<Void, Never>?

    private var motion: Animation? { reduceMotion ? nil : MoleMotion.panel }
    private var shape: NotchShape { NotchShape(bottomRadius: expanded ? 20 : 10) }

    var body: some View {
        LiquidGlassGroup { islandBody }
    }

    private var islandBody: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: safeTop).allowsHitTesting(false)
            if expanded {
                headerRow.transition(.opacity)
                if let resource = selectedResource {
                    resourcePanel(resource)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            } else {
                Button { setExpanded(true) } label: {
                    HStack(spacing: 4) {
                        ForEach(0..<3, id: \.self) { _ in
                            Circle().fill(Color.islandHandleDot).frame(width: 2.5, height: 2.5)
                        }
                    }
                    .frame(width: collapsedWidth, height: safeTop > 0 ? 10 : IslandLayout.handleHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(l10n.t("settings.island"))
            }
        }
        .frame(width: expanded ? IslandLayout.panelWidth : collapsedWidth)
        .modifier(IslandLiquidSurface(shape: shape, namespace: islandNamespace))
        .contentShape(shape)
        .background {
            GeometryReader { geo in
                let frame = geo.frame(in: .named(IslandLayout.hitSpaceName))
                Color.clear
                    .onAppear { onHitFrameChange(frame) }
                    .onChange(of: frame) { onHitFrameChange($0) }
            }
            .allowsHitTesting(false)
        }
        .onHover(perform: handleHover)
        .animation(motion, value: expanded)
        .animation(motion, value: selectedResource)
        .padding(.horizontal, IslandLayout.windowMargin)
        .padding(.bottom, IslandLayout.windowMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .coordinateSpace(name: IslandLayout.hitSpaceName)
        .environment(\.colorScheme, .dark)
        .onChange(of: focusedResource) { resource in
            if let resource { selectResource(resource) }
        }
        .onDisappear {
            hoverDebounce?.cancel()
            resourceDebounce?.cancel()
            expanded = false
            selectedResource = nil
            hoveredResource = nil
            onExpandedChange(false)
        }
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            ForEach(AppState.IslandItem.allCases.filter { state.islandItems.contains($0) }, id: \.self) { item in
                metric(item).frame(maxWidth: .infinity)
            }
            Button {
                setExpanded(false)
                onOpenMain()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 24, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(l10n.t("island.advanced"))
            .accessibilityLabel(l10n.t("island.advanced"))
            .onHover { if $0 { selectResource(nil) } }
        }
        .padding(.horizontal, 22)
        .frame(height: IslandLayout.metricsHeight)
    }

    @ViewBuilder
    private func metric(_ item: AppState.IslandItem) -> some View {
        if let resource = item.resource {
            Button {
                selectResource(resource)
                state.cleanIslandResource(resource)
            } label: { ring(item) }
                .buttonStyle(.plain)
                .disabled(state.islandCleaningResource != nil)
                .focused($focusedResource, equals: resource)
                .help(l10n.t("island.clean.hint"))
                .accessibilityLabel(l10n.t(item.labelKey) + " · " + l10n.t("island.clean"))
                .accessibilityValue(valueText(item))
                .onHover { hovering in
                    hoveredResource = hovering ? resource : nil
                    if hovering {
                        selectResource(resource)
                    } else {
                        scheduleResourceDismissal()
                    }
                }
        } else {
            ring(item)
                .help(l10n.t(item.labelKey) + " " + valueText(item))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(l10n.t(item.labelKey))
                .accessibilityValue(valueText(item))
                .onHover { if $0 { selectResource(nil) } }
        }
    }

    private func ring(_ item: AppState.IslandItem) -> some View {
        ZStack {
            Circle().stroke(.white.opacity(0.16), lineWidth: 4)
            Circle()
                .trim(from: 0, to: max(0.015, min(1, progress(item))))
                .stroke(healthColor(item), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if let resource = item.resource, state.islandCleaningResource == resource {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: item.resource != nil && (hoveredResource == item.resource || focusedResource == item.resource) ? "bolt.fill" : item.systemImage)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 34, height: 34)
        .padding(6)
        .contentShape(Rectangle())
    }

    private func progress(_ item: AppState.IslandItem) -> Double {
        switch item {
        case .cpu: return state.metrics.cpuPercent / 100
        case .memory: return state.metrics.memoryPercent / 100
        case .disk: return state.metrics.diskUsedPercent / 100
        case .network: return state.metrics.networkRxMBps / max(0.1, state.networkHistory.max() ?? 0.1)
        }
    }

    private func healthColor(_ item: AppState.IslandItem) -> Color {
        // 流量高低不是健康程度；网络保留绿色活动环，不把下载高峰误报为异常。
        guard item != .network else { return .green }
        switch IslandResourcePolicy.health(percent: progress(item) * 100) {
        case .healthy: return .green
        case .elevated: return .orange
        case .high: return .red
        }
    }

    private func valueText(_ item: AppState.IslandItem) -> String {
        switch item {
        case .cpu: return String(format: "%.0f%%", state.metrics.cpuPercent)
        case .memory: return String(format: "%.0f%%", state.metrics.memoryPercent)
        case .disk: return ByteFormat.format(state.metrics.diskFreeBytes)
        case .network: return String(format: "↓%.1f ↑%.1f MB/s", state.metrics.networkRxMBps, state.metrics.networkTxMBps)
        }
    }

    private func resourcePanel(_ resource: IslandResource) -> some View {
        let rows = resource == .cpu ? state.topCPUApps : state.topMemoryApps
        return VStack(spacing: 5) {
            HStack {
                Text(l10n.t(resource == .cpu ? "island.top.cpu" : "island.top.memory"))
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Text(resource == .cpu ? "% CPU" : l10n.t("island.item.memory"))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .padding(.bottom, 4)
            if rows.isEmpty {
                Text(l10n.t("island.process.loading"))
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(.vertical, 12)
            }
            ForEach(rows) { row in
                HStack(spacing: 8) {
                    if let icon = NSRunningApplication(processIdentifier: row.pid)?.icon {
                        Image(nsImage: icon).resizable().frame(width: 19, height: 19)
                    } else {
                        Image(systemName: "app").frame(width: 19, height: 19)
                    }
                    Text(row.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    Text(resource == .cpu ? String(format: "%.1f%%", row.cpu) : ByteFormat.memoryShort(row.memBytes))
                        .monospacedDigit().foregroundStyle(.secondary)
                    Button { state.closeIslandApp(row, resource: resource) } label: {
                        if state.islandClosingPIDs.contains(row.pid) {
                            ProgressView().controlSize(.mini).frame(width: 22, height: 24)
                        } else {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                                .frame(width: 22, height: 24).contentShape(Rectangle())
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!state.canCloseIslandApp(row) || state.islandClosingPIDs.contains(row.pid)
                              || state.islandCleaningResource != nil)
                    .accessibilityLabel(l10n.tf("island.quit", row.name))
                    .help(l10n.t("island.quit.hint"))
                }
                .font(.system(size: 11))
                .frame(height: 29)
            }
            if let status = state.islandResourceStatus[resource] {
                Text(status).font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 5)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .background(Color.white.opacity(0.035))
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { resourceDebounce?.cancel() }
            else { scheduleResourceDismissal() }
        }
    }

    private func selectResource(_ resource: IslandResource?) {
        resourceDebounce?.cancel()
        withAnimation(motion) { selectedResource = resource }
        if resource != nil { state.refreshIslandProcesses() }
    }

    private func scheduleResourceDismissal() {
        resourceDebounce?.cancel()
        resourceDebounce = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, state.islandCleaningResource == nil,
                  state.islandClosingPIDs.isEmpty else { return }
            withAnimation(motion) { selectedResource = nil }
        }
    }

    private func handleHover(_ hovering: Bool) {
        hoverDebounce?.cancel()
        hoverDebounce = Task { @MainActor in
            try? await Task.sleep(nanoseconds: hovering ? 100_000_000 : 400_000_000)
            guard !Task.isCancelled else { return }
            setExpanded(hovering)
        }
    }

    private func setExpanded(_ value: Bool) {
        guard expanded != value else { return }
        withAnimation(motion) {
            expanded = value
            if !value {
                resourceDebounce?.cancel()
                selectedResource = nil
                hoveredResource = nil
            }
        }
        if value { state.refreshMetrics(); state.refreshIslandProcesses(force: true) }
        onExpandedChange(value)
    }
}
