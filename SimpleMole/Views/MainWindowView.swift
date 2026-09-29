import SwiftUI

/// 主窗口：标题与指标卡 → 胶囊导航 → 功能页。
/// 每个视图持有 L10n 引用，语言切换即时重绘。
struct MainWindowView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var dialogNamespace

    private var activeDialog: String? {
        if state.showPermissionCenter { return "permissions" }
        if state.showAutoCleanupSheet { return "autoCleanup" }
        if state.showWhitelistSheet { return "whitelist" }
        return nil
    }

    private var tabs: [String] {
        state.visiblePages.map { l10n.t($0.titleKey) }
    }

    var body: some View {
        LiquidGlassGroup {
            ZStack {
                VStack(spacing: 0) {
                    titleBarRow
                    metricBar
                    Divider()
                    PillPicker(items: tabs, selection: $state.selectedTab)
                        .padding(.top, 8)
                        .padding(.bottom, 6)
                    Divider()
                    AnimatedTabContent(state: state)
                        .frame(maxHeight: .infinity)
                }
                .disabled(activeDialog != nil)
                .accessibilityHidden(activeDialog != nil)

                if let activeDialog {
                    Color.black.opacity(0.20)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { dismissDialog() }
                        .transition(.opacity)
                    dialogContent(activeDialog)
                        .liquidSurface(activeDialog)
                        .padding(16)
                        .transition(.opacity)
                        .zIndex(2)
                }
            }
        }
        .environment(\.liquidNamespace, dialogNamespace)
        .environment(\.liquidDialogID, activeDialog)
        .frame(minWidth: 760, idealWidth: 940, minHeight: 620, idealHeight: 720)
        .background { GlassSurface().ignoresSafeArea() }
        .ignoresSafeArea(.container, edges: .top)
        .animation(reduceMotion ? nil : MoleMotion.panel, value: activeDialog)
        .onExitCommand { dismissDialog() }
        .alert(confirmationTitle,
               isPresented: confirmationBinding, presenting: state.confirmation) { accepted in
            Button(accepted.confirmLabel, role: .destructive) { state.runConfirmation(accepted) }
            Button(l10n.t("common.cancel"), role: .cancel) { state.confirmation = nil }
        } message: { accepted in
            Text(accepted.message)
        }
    }

    private var titleBarRow: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 66, height: 1)
            HeaderBrandIconView(size: 20, isSearching: state.isScanning,
                                searchSucceeded: state.cleanupScanComplete, isWorking: state.isBusy,
                                reactionID: state.headerReactionID,
                                reactionMood: state.headerReactionMood)
            Text(l10n.t("window.title"))
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button {
                NSApp.terminate(nil)
            } label: {
                Label(l10n.t("settings.quit"), systemImage: "power")
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.warning)
            .help(l10n.t("settings.quit.hint"))
        }
        .frame(height: 28)
        .padding(.horizontal, 10)
        .padding(.top, 2)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func dialogContent(_ id: String) -> some View {
        switch id {
        case "permissions": PermissionCenterView(state: state)
        case "autoCleanup": AutoCleanupRulesView(state: state)
        case "whitelist": WhitelistSheet(state: state)
        default: EmptyView()
        }
    }

    private func dismissDialog() {
        if state.showPermissionCenter { state.cancelPermissionCenter() }
        else if state.showAutoCleanupSheet { state.showAutoCleanupSheet = false }
        else { state.showWhitelistSheet = false }
    }

    private var metricBar: some View {
        MetricBar(items: [
            .init(title: l10n.t("metric.cleanable"), symbol: "trash",
                  value: state.selectedCount > 0 ? ByteFormat.format(state.selectedBytes) : l10n.t("metric.pending")),
            .init(title: l10n.t("metric.memory"), symbol: "memorychip",
                  value: String(format: "%.0f%%", state.metrics.memoryPercent),
                  progress: state.metrics.memoryPercent / 100),
            .init(title: l10n.t("metric.disk"), symbol: "internaldrive",
                  value: state.metrics.diskFreeBytes > 0 ? ByteFormat.format(state.metrics.diskFreeBytes) : "--",
                  progress: state.metrics.diskUsedPercent / 100),
            .init(title: l10n.t("metric.network"), symbol: "network",
                  value: String(format: "↓%.1f ↑%.1f", state.metrics.networkRxMBps, state.metrics.networkTxMBps),
                  sparkline: state.networkHistory),
        ])
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    // MARK: 弹窗绑定

    private var confirmationTitle: String { state.confirmation?.title ?? "" }
    private var confirmationBinding: Binding<Bool> {
        Binding(get: { state.confirmation != nil },
                set: { if !$0 { state.confirmation = nil } })
    }
}

/// 业务选择仍由 AppState 即时驱动；这里单独保存呈现中的页面，让导航玻璃先流动、
/// 内容随后按方向轻量过渡。连续点击会直接改向，不排队也不阻塞业务扫描。
private struct AnimatedTabContent: View {
    @ObservedObject private var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var presentedTab: Int
    @State private var direction: CGFloat = 1

    init(state: AppState) {
        _state = ObservedObject(wrappedValue: state)
        _presentedTab = State(initialValue: state.selectedTab)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            page(for: presentedTab)
                .id(presentedTab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(pageTransition)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .onChange(of: state.selectedTab) { next in
            present(next)
        }
    }

    @ViewBuilder
    private func page(for tab: Int) -> some View {
        if tab < state.visiblePages.count {
            switch state.visiblePages[tab] {
            case .cleanup: CleanupTabView(state: state)
            case .agents: AgentsTabView(state: state)
            case .analyze: AnalyzeTabView(state: state)
            case .uninstall: UninstallTabView(state: state)
            case .optimize: OptimizeTabView(state: state)
            case .devenv: DevEnvTabView(state: state)
            case .processes: ProcessesTabView(state: state)
            case .ports: PortsTabView(state: state)
            case .traffic: TrafficTabView(state: state)
            case .clipboard: ClipboardHistoryTabView(manager: state.clipboardManager)
            case .settings: SettingsTabView(state: state)
            }
        } else {
            EmptyView()
        }
    }

    private var pageTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }

        return .asymmetric(
            insertion: .modifier(
                active: TabPageMotion(x: direction * 28, opacity: 0),
                identity: TabPageMotion(x: 0, opacity: 1)
            ),
            removal: .modifier(
                active: TabPageMotion(x: -direction * 18, opacity: 0),
                identity: TabPageMotion(x: 0, opacity: 1)
            )
        )
    }

    private func present(_ next: Int) {
        guard next != presentedTab else { return }
        let nextDirection: CGFloat = next > presentedTab ? 1 : -1

        let animation: Animation = reduceMotion
            ? .easeOut(duration: 0.12)
            : .timingCurve(0.20, 0.78, 0.20, 1, duration: 0.40)
        withAnimation(animation) {
            direction = nextDirection
            presentedTab = next
        }
    }
}

private struct TabPageMotion: ViewModifier {
    let x: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content
            .offset(x: x)
            .opacity(opacity)
    }
}
