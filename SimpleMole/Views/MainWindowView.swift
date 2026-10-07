import SwiftUI

/// 主窗口：标题与指标卡 → 胶囊导航 → 功能页。
/// 每个视图持有 L10n 引用，语言切换即时重绘。
struct MainWindowView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var dialogNamespace

    private var activeDialog: String? {
        if let notice = state.taskNotice { return "task-" + notice.id.uuidString }
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
                    PillPicker(items: tabs, selection: $state.selectedTab)
                        .disabled(state.agentApplying)
                        .padding(.top, 10)
                        .padding(.bottom, 8)
                    AnimatedTabContent(state: state)
                        .frame(maxHeight: .infinity)
                }
                .disabled(activeDialog != nil)
                .accessibilityHidden(activeDialog != nil)

                if let activeDialog {
                    Color.surface1.opacity(0.45)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { if state.taskNotice == nil { dismissDialog() } }
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
        .frame(minWidth: 760, idealWidth: 940, minHeight: 620, idealHeight: 720)
        .background { GlassSurface().ignoresSafeArea() }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .ignoresSafeArea(.container, edges: .top)
        .animation(reduceMotion ? nil : MoleMotion.panel, value: activeDialog)
        .onExitCommand { dismissDialog() }
        .alert(l10n.t("cleanup.admin.title"), isPresented: Binding(
            get: { state.administratorCleanupPrompt != nil },
            set: { visible in
                if !visible {
                    DispatchQueue.main.async { state.resolveAdministratorCleanup(nil) }
                }
            })) {
                Button(l10n.t("cleanup.admin.include")) { state.resolveAdministratorCleanup(true) }
                Button(l10n.t("cleanup.admin.skip")) { state.resolveAdministratorCleanup(false) }
                Button(l10n.t("common.cancel"), role: .cancel) { state.resolveAdministratorCleanup(nil) }
            } message: {
                Text(state.administratorCleanupPrompt ?? "")
            }
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
            MainWindowControls().frame(width: 66, height: 28)
            HeaderBrandIconView(size: 20, isSearching: state.isScanning,
                                searchSucceeded: state.cleanupScanComplete, isWorking: state.isBusy,
                                reactionID: state.headerReactionID,
                                reactionMood: state.headerReactionMood,
                                isTidying: state.headerTask?.tidying == true)
            Text(l10n.t("window.title"))
                .font(.system(size: 13, weight: .semibold))
            MainWindowDragArea().frame(maxWidth: .infinity, maxHeight: .infinity)
            Button {
                NSApp.terminate(nil)
            } label: {
                Label(l10n.t("settings.quit"), systemImage: "power")
            }
            .buttonStyle(DangerButtonStyle())
            // 距顶边与距右边统一为 10pt：顶部对齐后下移 8pt，底部恰好
            // 落进原标题栏的下内边距，行高与整体布局保持不变。
            .frame(maxHeight: .infinity, alignment: .top)
            .offset(y: 8)
        }
        .frame(height: 28)
        .padding(.horizontal, 10)
        .padding(.top, 2)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func dialogContent(_ id: String) -> some View {
        if let notice = state.taskNotice {
            TaskFeedbackView(notice: notice, dismiss: { state.dismissTaskNotice() }, retry: {
                state.retryTaskNotice(notice)
            })
        } else {
            switch id {
            case "permissions": PermissionCenterView(state: state)
            case "autoCleanup": AutoCleanupRulesView(state: state)
            case "whitelist": WhitelistSheet(state: state)
            default: EmptyView()
            }
        }
    }

    private func dismissDialog() {
        if state.taskNotice != nil { state.dismissTaskNotice() }
        else if state.showPermissionCenter { state.cancelPermissionCenter() }
        else if state.showAutoCleanupSheet { state.showAutoCleanupSheet = false }
        else { state.showWhitelistSheet = false }
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
            case .directory: DirectoryTabView(model: state.directoryBrowser)
            case .uninstall: UninstallTabView(state: state)
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
                active: TabPageMotion(x: direction * 34, opacity: 0, scale: 0.985),
                identity: TabPageMotion(x: 0, opacity: 1, scale: 1)
            ),
            removal: .modifier(
                active: TabPageMotion(x: -direction * 22, opacity: 0, scale: 0.99),
                identity: TabPageMotion(x: 0, opacity: 1, scale: 1)
            )
        )
    }

    private func present(_ next: Int) {
        guard next != presentedTab else { return }
        let nextDirection: CGFloat = next > presentedTab ? 1 : -1

        // 与 MoleMotion.panel 同族的弹簧：高阻尼只留极轻的收尾回弹，
        // timingCurve 的匀减速段在这种全页位移上会显得机械。
        let animation: Animation = reduceMotion
            ? .easeOut(duration: 0.12)
            : .spring(response: 0.40, dampingFraction: 0.86, blendDuration: 0.10)
        withAnimation(animation) {
            direction = nextDirection
            presentedTab = next
        }
    }
}

private struct TabPageMotion: ViewModifier {
    let x: CGFloat
    let opacity: Double
    let scale: CGFloat

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .offset(x: x)
            .opacity(opacity)
    }
}
