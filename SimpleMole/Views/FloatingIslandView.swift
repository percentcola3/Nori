import AppKit
import SwiftUI

enum IslandLayout {
    static let panelWidth: CGFloat = 300
    /// 无刘海屏的虚拟刘海宽度，与 MacBook 硬件刘海（约 185pt）加 8pt 边一致。
    static let virtualNotchWidth: CGFloat = 193
    /// 硬件刘海是实黑遮挡，玻璃必须在刘海下沿再露出这一截才看得见手柄。
    static let notchLipHeight: CGFloat = 8
    static let notchBottomRadius: CGFloat = 9
    static let metricsHeight: CGFloat = 76
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
    /// 刘海屏为硬件刘海高度，无刘海屏为菜单栏高度（虚拟刘海）。
    var safeTop: CGFloat = 0
    var hardwareNotch = false
    var collapsedWidth: CGFloat = IslandLayout.virtualNotchWidth
    var onOpenMain: () -> Void
    var onHitFrameChange: (CGRect, NotchShape) -> Void
    var onExpandedChange: (Bool) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedResource: IslandResource?
    @State private var expanded = false
    @State private var selectedResource: IslandResource?
    @State private var hoveredResource: IslandResource?
    @State private var hoverDebounce: Task<Void, Never>?
    @State private var resourceDebounce: Task<Void, Never>?
    @State private var feedbackDismissal: Task<Void, Never>?
    @State private var feedbackPinned = false
    @State private var islandHovered = false
    @State private var moreHovered = false
    @State private var morePressed = false
    @State private var expandedHeight: CGFloat = IslandLayout.metricsHeight
    @State private var visibleSize: CGSize = .zero
    @State private var resourceHoverDebounce: Task<Void, Never>?
    @State private var ringReveal: CGFloat = 1
    @State private var ringReplay: Task<Void, Never>?

    private var motion: Animation? {
        reduceMotion ? nil : .spring(response: 0.52, dampingFraction: 0.8)
    }
    /// 详情展开/收起也走弹簧：表面高度跟随生长的“液态”手感来自轻微过冲，
    /// easeInOut 的匀速段落会让生长显得机械。
    private var detailMotion: Animation? {
        reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.82)
    }
    private var visibleShape: NotchShape {
        NotchShape(bottomRadius: expanded ? 20 : IslandLayout.notchBottomRadius,
                   shoulderRadius: expanded ? 10 : 4)
    }

    var body: some View {
        LiquidGlassGroup { islandBody }
    }

    private var islandBody: some View {
        VStack(spacing: 0) {
            // Keep one surface alive: animate its bounds and shoulder geometry,
            // rather than cross-fading two unrelated backgrounds.
            // 表面从物理顶边起画并盖住硬件刘海，肩角才能与屏幕顶边相接；
            // 内容自身按 safeTop 下移避让刘海。
            ZStack(alignment: .top) {
                expandedPanel
                    .padding(.top, safeTop)
                    .fixedSize(horizontal: false, vertical: true)
                    .background {
                        GeometryReader { geo in
                            Color.clear.preference(key: IslandExpandedHeightKey.self,
                                                   value: geo.size.height)
                        }
                    }
                    .opacity(expanded ? 1 : 0)
                    .allowsHitTesting(expanded)
                    .accessibilityHidden(!expanded)
                collapsedHandle
                    .opacity(expanded ? 0 : 1)
                    .allowsHitTesting(!expanded)
                    .accessibilityHidden(expanded)
            }
            .frame(width: expanded ? IslandLayout.panelWidth : collapsedWidth,
                   height: expanded ? expandedHeight : collapsedHeight,
                   alignment: .top)
            .modifier(IslandLiquidSurface(shape: visibleShape, isExpanded: expanded))
            .onPreferenceChange(IslandExpandedHeightKey.self) { height in
                if height > 0 { expandedHeight = height }
            }
            .contentShape(visibleShape)
            .background {
                GeometryReader { geo in
                    let frame = geo.frame(in: .named(IslandLayout.hitSpaceName))
                    Color.clear
                        .onAppear {
                            visibleSize = geo.size
                            onHitFrameChange(frame, visibleShape)
                        }
                        // 命中区域只信几何变化这一条通道：frame 的值在形变提交后
                        // 直接取到最终布局。绝不能再挂 onChange(of: expanded) 补报——
                        // 那个闭包捕获的是形变前的旧几何，且与 frame 通知同一拍到达，
                        // 会把展开后的命中区覆盖回折叠手柄矩形，展开面板上的所有
                        // 点击（更多/一键优化）都会被窗口判定"此处不存在"而穿透。
                        .onChange(of: frame) {
                            visibleSize = geo.size
                            onHitFrameChange($0, visibleShape)
                        }
                }
                .allowsHitTesting(false)
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    handleHover(visibleShape.path(in: CGRect(origin: .zero, size: visibleSize)).contains(point))
                case .ended: handleHover(false)
                }
            }
        }
        .animation(motion, value: expanded)
        .animation(detailMotion, value: selectedResource)
        .animation(detailMotion, value: expandedHeight)
        .padding(.horizontal, IslandLayout.windowMargin)
        .padding(.bottom, IslandLayout.windowMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .coordinateSpace(name: IslandLayout.hitSpaceName)
        .environment(\.colorScheme, .dark)
        .onChange(of: focusedResource) { resource in
            if let resource { selectResource(resource) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .smIslandPointerExited)) { _ in
            handleHover(false)
        }
        .onChange(of: state.islandCleaningResource) { resource in
            if resource == nil, feedbackPinned {
                replayUsageRings()
                releaseFeedbackAfterDelay()
            }
        }
        .onDisappear {
            hoverDebounce?.cancel()
            resourceDebounce?.cancel()
            resourceHoverDebounce?.cancel()
            feedbackDismissal?.cancel()
            ringReplay?.cancel()
            ringReveal = 1
            moreHovered = false
            feedbackPinned = false
            islandHovered = false
            expanded = false
            selectedResource = nil
            hoveredResource = nil
            onExpandedChange(false)
        }
    }

    /// 展开态：指标行 + 可选资源详情，占满面板宽度。
    private var expandedPanel: some View {
        VStack(spacing: 0) {
            headerRow
            if selectedResource != nil {
                ZStack(alignment: .top) {
                    ForEach([IslandResource.cpu, .memory], id: \.self) { resource in
                        resourcePanel(resource)
                            .opacity(selectedResource == resource ? 1 : 0)
                            .offset(x: selectedResource == resource ? 0 : (resource == .cpu ? -10 : 10))
                            .allowsHitTesting(selectedResource == resource)
                            .accessibilityHidden(selectedResource != resource)
                    }
                }
                .frame(minHeight: 214, alignment: .top)
                .clipped()
                .contentShape(Rectangle())
                .onHover { hovering in
                    if hovering { resourceDebounce?.cancel() }
                    else { scheduleResourceDismissal() }
                }
                .transition(.opacity)
            }
        }
        .frame(width: IslandLayout.panelWidth)
    }

    /// 虚拟刘海本身就是可见玻璃，不需要下沿，收起高度与菜单栏齐平。
    private var collapsedHeight: CGFloat {
        safeTop + (hardwareNotch ? IslandLayout.notchLipHeight : 0)
    }

    private var collapsedHandle: some View {
        Button { setExpanded(true) } label: {
            Capsule()
                .fill(Color.islandHandleGrip)
                .frame(width: 18, height: 2)
                .padding(.bottom, 3)
                .frame(width: collapsedWidth, height: collapsedHeight, alignment: .bottom)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(l10n.t("settings.island"))
    }

    private var headerRow: some View {
        HStack(spacing: 6) {
            ForEach(AppState.IslandItem.allCases.filter { state.islandItems.contains($0) }, id: \.self) { item in
                metric(item).frame(maxWidth: .infinity)
            }
            VStack(spacing: 2) {
                ZStack {
                    Circle().stroke(.white.opacity(0.16), lineWidth: 4)
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 34, height: 34)
                .padding(6)
                .background(Circle().fill(Color.white.opacity(moreHovered ? 0.16 : 0.04)))
                Text(l10n.t("common.more"))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(height: 14)
            }
            .frame(maxWidth: .infinity)
            .frame(height: IslandLayout.metricsHeight)
            .contentShape(Rectangle())
            .brightness(morePressed ? 0.12 : 0)
            .scaleEffect(morePressed && !reduceMotion ? 0.96 : 1)
            .animation(reduceMotion ? nil : MoleMotion.press, value: morePressed)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .overlay {
                IslandActionTarget(label: l10n.t("island.advanced"),
                                   isEnabled: expanded,
                                   onPressChange: { morePressed = $0 }) {
                    hoverDebounce?.cancel()
                    resourceDebounce?.cancel()
                    resourceHoverDebounce?.cancel()
                    setExpanded(false)
                    onOpenMain()
                }
            }
            .frame(maxWidth: .infinity)
            .help(l10n.t("island.advanced"))
            .onHover {
                moreHovered = $0
                if $0 {
                    resourceDebounce?.cancel()
                    resourceHoverDebounce?.cancel()
                }
            }
        }
        .padding(.horizontal, 20)
        .frame(height: IslandLayout.metricsHeight)
    }

    @ViewBuilder
    private func metric(_ item: AppState.IslandItem) -> some View {
        if let resource = item.resource {
            Button { beginCleanup(resource) } label: { ring(item) }
                .buttonStyle(IslandResourceButtonStyle())
                .disabled(state.islandCleaningResource != nil)
                .focused($focusedResource, equals: resource)
                .help(l10n.t("island.clean.hint"))
                .accessibilityLabel(l10n.t(item.labelKey) + " · " + l10n.t("island.clean"))
                .accessibilityValue(valueText(item))
                .accessibilityAddTraits(selectedResource == resource ? .isSelected : [])
                .onHover { hovering in
                    resourceHoverDebounce?.cancel()
                    if hovering {
                        hoveredResource = resource
                        resourceDebounce?.cancel()
                        resourceHoverDebounce = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 160_000_000)
                            guard !Task.isCancelled else { return }
                            selectResource(resource)
                        }
                    } else {
                        if hoveredResource == resource { hoveredResource = nil }
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
        let selected = item.resource != nil && selectedResource == item.resource
        return VStack(spacing: 2) {
            ringIcon(item)
            Text(l10n.t(item.labelKey))
                .font(.system(size: 9, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? Color.accentText : Color.secondary)
                .lineLimit(1)
                .padding(.bottom, 4)
                .frame(height: 14)
                .overlay(alignment: .bottom) {
                    Capsule().fill(selected ? Color.accentText : .clear)
                        .frame(width: 16, height: 2)
                        .allowsHitTesting(false)
                }
        }
        .frame(width: 46)
        .contentShape(Rectangle())
    }

    private func ringIcon(_ item: AppState.IslandItem) -> some View {
        ZStack {
            Circle().stroke(.white.opacity(0.16), lineWidth: 4)
            Circle()
                .trim(from: 0, to: max(0, min(1, progress(item))) * ringReveal)
                .stroke(healthColor(item), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if let resource = item.resource, state.islandCleaningResource == resource {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: item.systemImage)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 34, height: 34)
        .padding(6)
        .background {
            if let resource = item.resource {
                Circle().fill(Color.white.opacity(
                    selectedResource == resource || hoveredResource == resource || focusedResource == resource ? 0.16 : 0.04))
            }
        }
        .overlay {
            if let resource = item.resource, selectedResource == resource {
                Circle().strokeBorder(Color.accentText.opacity(0.6), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Circle())
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
                    ProcessAppIcon(row: row, size: 19, fallbackSystemName: "app",
                                   fallbackTint: .secondary, validatesNativeStartIdentity: true)
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
                Text(status)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .contentShape(Rectangle())
    }

    private func selectResource(_ resource: IslandResource?) {
        guard state.islandCleaningResource == nil else { return }
        if feedbackPinned, resource == nil { return }
        resourceDebounce?.cancel()
        resourceHoverDebounce?.cancel()
        guard selectedResource != resource else { return }
        withAnimation(detailMotion) { selectedResource = resource }
        if resource != nil { state.refreshIslandProcesses() }
    }

    private func scheduleResourceDismissal() {
        resourceDebounce?.cancel()
        resourceDebounce = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, state.islandCleaningResource == nil,
                  state.islandClosingPIDs.isEmpty, hoveredResource == nil, !moreHovered, !feedbackPinned else { return }
            withAnimation(detailMotion) { selectedResource = nil }
        }
    }

    private func handleHover(_ hovering: Bool) {
        guard islandHovered != hovering else { return }
        islandHovered = hovering
        hoverDebounce?.cancel()
        hoverDebounce = Task { @MainActor in
            try? await Task.sleep(nanoseconds: hovering ? 220_000_000 : 400_000_000)
            guard !Task.isCancelled else { return }
            if !hovering, feedbackPinned || state.islandCleaningResource != nil { return }
            setExpanded(hovering)
        }
    }

    private func beginCleanup(_ resource: IslandResource) {
        guard state.islandCleaningResource == nil else { return }
        ringReplay?.cancel()
        resetRingReveal(to: 1)
        hoverDebounce?.cancel()
        resourceDebounce?.cancel()
        feedbackDismissal?.cancel()
        resourceHoverDebounce?.cancel()
        withAnimation(detailMotion) { selectedResource = resource }
        feedbackPinned = true
        state.cleanIslandResource(resource)
        // Busy rejection also needs visible feedback, although no job starts.
        if state.islandCleaningResource == nil { releaseFeedbackAfterDelay() }
    }

    private func resetRingReveal(to value: CGFloat) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { ringReveal = value }
    }

    private func replayUsageRings() {
        ringReplay?.cancel()
        guard expanded, !reduceMotion else {
            resetRingReveal(to: 1)
            return
        }
        // Reset only presentation, never the sampled metrics or accessibility values.
        resetRingReveal(to: 0)
        ringReplay = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else { return }
            if reduceMotion || !expanded {
                resetRingReveal(to: 1)
            } else {
                withAnimation(.easeOut(duration: 0.65)) { ringReveal = 1 }
            }
        }
    }

    private func releaseFeedbackAfterDelay() {
        feedbackDismissal?.cancel()
        feedbackDismissal = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            feedbackPinned = false
            if !islandHovered { setExpanded(false) }
        }
    }

    private func setExpanded(_ value: Bool) {
        guard expanded != value else { return }
        withAnimation(motion) {
            expanded = value
            if !value {
                ringReplay?.cancel()
                resetRingReveal(to: 1)
                resourceDebounce?.cancel()
                resourceHoverDebounce?.cancel()
                selectedResource = nil
                hoveredResource = nil
            }
        }
        if value { state.refreshMetrics(); state.refreshIslandProcesses(force: true) }
        onExpandedChange(value)
    }
}

private struct IslandResourceButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(configuration.isPressed ? 0.12 : 0)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct IslandExpandedHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = IslandLayout.metricsHeight
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
