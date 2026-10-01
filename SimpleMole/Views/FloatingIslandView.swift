import AppKit
import SwiftUI

enum IslandLayout {
    /// 窗口预留全部指标及无刘海屏 Nori 所需的最大宽度。
    static let panelWidth: CGFloat = 468
    static let minimumPanelWidth: CGFloat = 344
    static let metricWidth: CGFloat = 84
    static let networkWidth: CGFloat = 112
    static let mascotWidth: CGFloat = 32
    static let moreWidth: CGFloat = 28
    static let metricSpacing: CGFloat = 4

    static func expandedWidth(items: Set<AppState.IslandItem>, hardwareNotch: Bool) -> CGFloat {
        let metricTotal = items.reduce(CGFloat.zero) { width, item in
            width + (item == .network ? networkWidth : metricWidth)
        }
        let accessoryCount = hardwareNotch ? 1 : 2
        let spacingCount = max(0, items.count + accessoryCount - 1)
        return max(minimumPanelWidth,
                   metricTotal + moreWidth + (hardwareNotch ? 0 : mascotWidth)
                   + CGFloat(spacingCount) * metricSpacing + contentInset * 2)
    }
    static let contentInset: CGFloat = 12
    static let tileHeight: CGFloat = 62
    /// 无刘海屏的虚拟刘海宽度，与 MacBook 硬件刘海（约 185pt）加 8pt 边一致。
    static let virtualNotchWidth: CGFloat = 193
    /// 硬件刘海是实黑遮挡，玻璃必须在刘海下沿再露出这一截才看得见手柄。
    static let notchLipHeight: CGFloat = 8
    static let notchBottomRadius: CGFloat = 9
    /// 无刘海屏折叠时只挂一个顶边句柄，不再画整块菜单栏高度的虚拟刘海。
    static let handleWidth: CGFloat = 64
    static let handleHeight: CGFloat = 12
    static let handleBottomRadius: CGFloat = 6
    /// 展开后是一排对齐的核心指标，加右下角入口。窗口按它预留高度。
    static let metricsHeight: CGFloat = 118
    static let detailBudget: CGFloat = 340
    /// 无刘海屏展开态的顶部内边距：没有硬件刘海需要避让，只保留一个
    /// 折叠手柄高度的呼吸空间，避免展开后顶部出现菜单栏高度的空白带。
    static let nonNotchExpandedTopInset: CGFloat = 12
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
    @State private var idleScene = 0

    /// Idle scenes rotate on each expansion; a running task shows its own animation.
    private var mascotAsset: String {
        if let task = state.headerTask { return task.tidying ? "nori-tidying" : "nori-working" }
        return NoriStatusAnimation.idleScenes[idleScene % NoriStatusAnimation.idleScenes.count]
    }

    private func mascot(size: CGFloat) -> some View {
        NoriStatusAnimation(mood: .idle, size: size, assetName: mascotAsset, ignoresAppActivity: true)
            .id(mascotAsset)
    }

    /// 刘海屏内容必须避开硬件刘海（safeTop 原值）；无刘海屏的菜单栏高度
    /// 没有实际遮挡，展开内容只留一个手柄高度的顶部空间。
    private var expandedTopInset: CGFloat {
        hardwareNotch ? safeTop : IslandLayout.nonNotchExpandedTopInset
    }

    private var expandedPanelWidth: CGFloat {
        IslandLayout.expandedWidth(items: state.islandItems, hardwareNotch: hardwareNotch)
    }

    private var motion: Animation? {
        reduceMotion ? nil : .spring(response: 0.52, dampingFraction: 0.8)
    }
    /// 详情展开/收起也走弹簧：表面高度跟随生长的“液态”手感来自轻微过冲，
    /// easeInOut 的匀速段落会让生长显得机械。
    private var detailMotion: Animation? {
        reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.82)
    }
    private var visibleShape: NotchShape {
        if expanded { return NotchShape(bottomRadius: 20, shoulderRadius: 10) }
        return NotchShape(bottomRadius: hardwareNotch ? IslandLayout.notchBottomRadius
                                                      : IslandLayout.handleBottomRadius,
                          shoulderRadius: 4)
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
                    .padding(.top, expandedTopInset)
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
                // 刘海屏把 Nori 放在刘海左侧的肩位，不额外占高度。
                if expanded && hardwareNotch {
                    mascot(size: min(30, safeTop))
                        .padding(.leading, 20)
                        .frame(width: expandedPanelWidth, height: safeTop, alignment: .leading)
                        .transition(.opacity)
                }
                collapsedHandle
                    .opacity(expanded ? 0 : 1)
                    .allowsHitTesting(!expanded)
                    .accessibilityHidden(expanded)
            }
            .frame(width: expanded ? expandedPanelWidth : collapsedSurfaceWidth,
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
                Rectangle()
                    .fill(Color.hairline)
                    .frame(height: 1)
                    .padding(.horizontal, IslandLayout.contentInset + 10)
                    .transition(.opacity)
                ZStack(alignment: .top) {
                    ForEach([IslandResource.cpu, .memory], id: \.self) { resource in
                        resourcePanel(resource)
                            .opacity(selectedResource == resource ? 1 : 0)
                            .offset(x: selectedResource == resource ? 0 : (resource == .cpu ? -10 : 10))
                            .allowsHitTesting(selectedResource == resource)
                            .accessibilityHidden(selectedResource != resource)
                    }
                }
                .frame(minHeight: 150, alignment: .top)
                .clipped()
                .contentShape(Rectangle())
                .onHover { hovering in
                    if hovering { resourceDebounce?.cancel() }
                    else { scheduleResourceDismissal() }
                }
                .transition(.opacity)
            }
        }
        .frame(width: expandedPanelWidth)
    }

    /// 刘海屏：玻璃包住硬件刘海并在下沿露出一截；无刘海屏：只有顶边句柄。
    private var collapsedHeight: CGFloat {
        hardwareNotch ? safeTop + IslandLayout.notchLipHeight : IslandLayout.handleHeight
    }

    private var collapsedSurfaceWidth: CGFloat {
        hardwareNotch ? collapsedWidth : IslandLayout.handleWidth
    }

    private var collapsedHandle: some View {
        Button { setExpanded(true) } label: {
            Capsule()
                .fill(Color.islandHandleGrip)
                .frame(width: 18, height: 2)
                .padding(.bottom, 3)
                .frame(width: collapsedSurfaceWidth, height: collapsedHeight, alignment: .bottom)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(l10n.t("settings.island"))
    }

    /// 指标块同高同排版：标题、数值、底部进度。悬停只改标题颜色，不画底框。
    /// 「更多」是行尾的箭头图标入口，不再单独占一行。
    private var headerRow: some View {
        HStack(alignment: .center, spacing: IslandLayout.metricSpacing) {
            if !hardwareNotch && expanded {
                mascot(size: IslandLayout.mascotWidth)
            }
            ForEach(AppState.IslandItem.allCases.filter { state.islandItems.contains($0) }, id: \.self) { item in
                metric(item)
                    .frame(minWidth: item == .network ? IslandLayout.networkWidth : IslandLayout.metricWidth,
                           maxWidth: .infinity,
                           alignment: .leading)
            }
            moreControl
        }
        .padding(.horizontal, IslandLayout.contentInset)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    private var moreControl: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 15, weight: .semibold))
            .offset(x: moreHovered && !reduceMotion ? 2 : 0)
            .foregroundStyle(moreHovered ? Color.accentText : Color.secondary)
            .frame(width: IslandLayout.moreWidth, height: 36)
            .contentShape(Rectangle())
        .animation(reduceMotion ? nil : MoleMotion.press, value: moreHovered)
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
        .onHover {
            moreHovered = $0
            if $0 {
                resourceDebounce?.cancel()
                resourceHoverDebounce?.cancel()
            }
        }
    }

    @ViewBuilder
    private func metric(_ item: AppState.IslandItem) -> some View {
        if item == .network {
            networkMeter
        } else if let resource = item.resource {
            Button { beginCleanup(resource) } label: { ring(item) }
                .buttonStyle(IslandResourceButtonStyle())
                .disabled(state.islandCleaningResource != nil)
                .focused($focusedResource, equals: resource)
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
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(l10n.t(item.labelKey))
                .accessibilityValue(valueText(item))
                .onHover { if $0 { selectResource(nil) } }
        }
    }

    private func ring(_ item: AppState.IslandItem) -> some View {
        let selected = item.resource != nil && selectedResource == item.resource
        let active = item.resource != nil && (
            selected || hoveredResource == item.resource || focusedResource == item.resource)
        return VStack(alignment: .leading, spacing: 0) {
            tileLabel(item, highlighted: active)
            Spacer(minLength: 4)
            if let resource = item.resource, state.islandCleaningResource == resource {
                ProgressView()
                    .controlSize(.small)
                    .frame(height: 24, alignment: .leading)
            } else {
                Text(primaryValue(item))
                    .font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(healthColor(item))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(height: 24, alignment: .leading)
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 6)
            Capsule()
                .fill(Color.hairline)
                .frame(height: 3)
                .overlay(alignment: .leading) {
                    GeometryReader { geo in
                        Capsule()
                            .fill(healthColor(item))
                            .frame(width: max(3, geo.size.width * min(1, max(0, progress(item))) * ringReveal))
                    }
                }
        }
        .modifier(IslandTileFrame())
        .contentShape(Rectangle())
    }

    private func tileLabel(_ item: AppState.IslandItem, highlighted: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: item.systemImage)
                .font(.system(size: 9, weight: .semibold))
            Text(l10n.t(item.labelKey))
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(highlighted ? Color.accentText : Color.secondary)
        .frame(height: 14, alignment: .leading)
    }

    private func progress(_ item: AppState.IslandItem) -> Double {
        switch item {
        case .cpu: return state.metrics.cpuPercent / 100
        case .memory: return state.metrics.memoryPercent / 100
        case .disk: return state.metrics.diskUsedPercent / 100
        case .network: return 0
        }
    }

    /// 吞吐没有 0–100% 的上限，不用占用环表示。下行用成功色，上行用次要色。
    private var networkMeter: some View {
        VStack(alignment: .leading, spacing: 0) {
            tileLabel(.network, highlighted: false)
            Spacer(minLength: 3)
            VStack(alignment: .leading, spacing: 1) {
                rateLine(symbol: "arrow.down",
                         text: ByteFormat.megabytesPerSecond(state.metrics.networkRxMBps),
                         tint: Color.success)
                rateLine(symbol: "arrow.up",
                         text: ByteFormat.megabytesPerSecond(state.metrics.networkTxMBps),
                         tint: Color.secondary)
            }
            Spacer(minLength: 3)
            IslandSparkline(primary: state.networkHistory, secondary: state.networkUploadHistory)
                .frame(height: 10)
        }
        .modifier(IslandTileFrame())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(l10n.t("island.item.network"))
        .accessibilityValue(networkValue)
        .onHover { if $0 { selectResource(nil) } }
    }

    private func rateLine(symbol: String, text: String, tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .bold))
            Text(text)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .foregroundStyle(tint)
    }

    private var networkValue: String {
        "↓" + ByteFormat.megabytesPerSecond(state.metrics.networkRxMBps)
            + " ↑" + ByteFormat.megabytesPerSecond(state.metrics.networkTxMBps)
    }

    private func healthColor(_ item: AppState.IslandItem) -> Color {
        // 流量高低不是健康程度；网络保留活动色，不把下载高峰误报为异常。
        guard item != .network else { return Color.success }
        switch IslandResourcePolicy.health(percent: progress(item) * 100) {
        case .healthy: return Color.success
        case .elevated: return Color.warning
        case .high: return Color.danger
        }
    }

    private func primaryValue(_ item: AppState.IslandItem) -> String {
        switch item {
        case .cpu: return String(format: "%.0f%%", state.metrics.cpuPercent)
        case .memory: return String(format: "%.0f%%", state.metrics.memoryPercent)
        case .disk: return ByteFormat.memoryShort(state.metrics.diskFreeBytes)
        case .network: return ""
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
        return VStack(spacing: 2) {
            HStack {
                Text(l10n.t(resource == .cpu ? "island.top.cpu" : "island.top.memory"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(resource == .cpu ? "% CPU" : l10n.t("island.item.memory"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .padding(.trailing, 34)
            }
            .frame(height: 22)
            if rows.isEmpty {
                Text(l10n.t("island.process.loading"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
            }
            ForEach(rows) { row in
                HStack(spacing: 10) {
                    ProcessAppIcon(row: row, size: 20, fallbackSystemName: "app",
                                   fallbackTint: .secondary, validatesNativeStartIdentity: true)
                    Text(row.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(resource == .cpu ? String(format: "%.1f%%", row.cpu) : ByteFormat.memoryShort(row.memBytes))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                    IslandQuitButton(closing: state.islandClosingPIDs.contains(row.pid)) {
                        state.closeIslandApp(row, resource: resource)
                    }
                    .disabled(!state.canCloseIslandApp(row) || state.islandClosingPIDs.contains(row.pid)
                              || state.islandCleaningResource != nil)
                    .accessibilityLabel(l10n.tf("island.quit", row.name))
                }
                .frame(height: 30)
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
        .padding(.leading, IslandLayout.contentInset + 10)
        .padding(.trailing, IslandLayout.contentInset + 4)
        .padding(.top, 6)
        .padding(.bottom, 12)
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
        if value {
            idleScene += 1
            state.refreshMetrics()
            state.refreshIslandProcesses(force: true)
        }
        onExpandedChange(value)
    }
}

private struct IslandSparkline: View {
    var primary: [Double]
    var secondary: [Double]

    var body: some View {
        Canvas { context, size in
            let peak = max(primary.max() ?? 0, secondary.max() ?? 0, 0.05)
            Self.stroke(&context, values: secondary, in: size, peak: peak, color: Color.primary.opacity(0.40))
            Self.stroke(&context, values: primary, in: size, peak: peak, color: Color.success)
        }
        .accessibilityHidden(true)
    }

    private static func stroke(_ context: inout GraphicsContext, values: [Double], in size: CGSize,
                        peak: Double, color: Color) {
        guard values.count >= 2, size.width > 0, size.height > 0 else { return }
        var path = Path()
        for (index, value) in values.enumerated() {
            let x = size.width * CGFloat(index) / CGFloat(values.count - 1)
            let y = size.height * (1 - CGFloat(min(max(value, 0) / peak, 1)))
            if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        context.stroke(path, with: .color(color),
                       style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
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

private struct IslandTileFrame: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(height: IslandLayout.tileHeight + 16, alignment: .topLeading)
    }
}

private struct IslandQuitButton: View {
    var closing: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Group {
                if closing {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(hovered && isEnabled ? Color.danger : Color.secondary)
                }
            }
            .frame(width: 24, height: 24)
            .contentShape(Circle())
        }
        .buttonStyle(IslandResourceButtonStyle())
        .opacity(isEnabled || closing ? 1 : 0.35)
        .onHover { hovered = $0 }
    }
}

private struct IslandExpandedHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = IslandLayout.metricsHeight
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
