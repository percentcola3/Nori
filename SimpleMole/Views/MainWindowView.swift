import AppKit
import SwiftUI

/// 主窗口：标题与指标卡 → 胶囊导航 → 功能页。
/// 每个视图持有 L10n 引用，语言切换即时重绘。
struct MainWindowView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var dialogNamespace
    @State private var lastConfirmationID: UUID?
    @State private var lastActiveDialog: String?

    private var activeDialog: String? {
        if let notice = state.taskNotice { return "task-" + notice.id.uuidString }
        if let plan = state.uninstallDataReview { return "uninstall-data-" + plan.id.uuidString }
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
                    PillPicker(items: tabs, selection: $state.selectedTab,
                               helpTexts: state.visiblePages.map {
                                   let title = l10n.t($0.titleKey)
                                   if let shortcut = state.pageShortcut(for: $0) {
                                       return title + " (" + shortcut.displayLabel + ")"
                                   }
                                   return title
                               })
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
        // .secondary / .tertiary 改用实色层级，避免半透明白字被彩色玻璃吃掉。
        .foregroundStyle(Color.textPrimary, Color.textSecondary, Color.textTertiary)
        .frame(minWidth: 760, idealWidth: 940, minHeight: 620, idealHeight: 720)
        .background {
            ZStack {
                GlassSurface()
                AtmosphereVeil()
            }
            .ignoresSafeArea()
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .ignoresSafeArea(.container, edges: .top)
        .animation(reduceMotion ? nil : MoleMotion.panel, value: activeDialog)
        .onExitCommand {
            if state.confirmation != nil {
                traceConfirmation("ui.confirmation.escape", id: state.confirmation?.id)
                state.cancelCleanupConfirmation()
            } else { dismissDialog() }
        }
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
            Button(accepted.confirmLabel, role: .destructive) {
                traceConfirmation("ui.confirmation.accepted", id: accepted.id)
                state.runConfirmation(accepted)
            }
            Button(l10n.t("common.cancel"), role: .cancel) {
                traceConfirmation("ui.confirmation.cancelled", id: state.confirmation?.id)
                state.cancelCleanupConfirmation()
            }
        } message: { accepted in
            Text(accepted.message)
        }
        .background {
            CleanupNativeSheetProbe(confirmationID: state.confirmation?.id,
                requestID: state.cleanupTraceRequestID) { event, requestID, fields in
                    state.traceCleanupInteraction(event, requestID: requestID, fields: fields)
                }
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
        .onAppear {
            lastActiveDialog = activeDialog
            state.traceCleanupInteraction("ui.main_window.appear", fields: ["active_dialog": activeDialog ?? "none"])
            if let id = state.confirmation?.id { confirmationChanged(id) }
        }
        .onChange(of: state.confirmation?.id) { confirmationChanged($0) }
        .onChange(of: activeDialog) { next in
            state.traceCleanupInteraction("ui.active_dialog.changed", fields: [
                "previous": lastActiveDialog ?? "none", "current": next ?? "none"
            ])
            lastActiveDialog = next
        }
    }

    private func confirmationChanged(_ id: UUID?) {
        if let id {
            lastConfirmationID = id
            traceConfirmation("ui.confirmation.requested", id: id)
        } else { traceConfirmation("ui.confirmation.cleared", id: lastConfirmationID) }
    }

    private func traceConfirmation(_ event: String, id: UUID?) {
        state.traceCleanupInteraction(event, fields: [
            "confirmation_id": (id ?? lastConfirmationID)?.uuidString ?? "none",
            "active_dialog": activeDialog ?? "none"
        ])
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
        } else if let plan = state.uninstallDataReview {
            UninstallDataReviewView(state: state, plan: plan).id(plan.id)
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
        else if state.uninstallDataReview != nil { state.uninstallDataReview = nil }
        else if state.showPermissionCenter { state.cancelPermissionCenter() }
        else if state.showAutoCleanupSheet { state.showAutoCleanupSheet = false }
        else { state.showWhitelistSheet = false }
    }

    // MARK: 弹窗绑定

    private var confirmationTitle: String { state.confirmation?.title ?? "" }
    private var confirmationBinding: Binding<Bool> {
        let presentedID = state.confirmation?.id
        return Binding(get: { state.confirmation != nil },
                       set: { visible in
                           if !visible {
                               traceConfirmation("ui.confirmation.binding_hidden", id: presentedID)
                               DispatchQueue.main.async {
                                   guard let presentedID, state.confirmation?.id == presentedID else { return }
                                   state.cancelCleanupConfirmation()
                               }
                           }
                       })
    }
}

/// Observe only this hosting window. The zero-sized view never participates in
/// hit testing; all probes read scalar AppKit presentation state without IO.
private struct CleanupNativeSheetProbe: NSViewRepresentable {
    let confirmationID: UUID?
    let requestID: UUID?
    let trace: (String, UUID?, [String: String]) -> Void

    func makeNSView(context: Context) -> ProbeView { ProbeView() }
    func updateNSView(_ view: ProbeView, context: Context) {
        view.update(confirmationID: confirmationID, requestID: requestID, trace: trace)
    }

    final class ProbeView: NSView {
        private var confirmationID: UUID?
        private var lastConfirmationID: UUID?
        private var requestID: UUID?
        private var trace: ((String, UUID?, [String: String]) -> Void)?
        private weak var observedWindow: NSWindow?
        private var observers: [NSObjectProtocol] = []
        private var probeTask: Task<Void, Never>?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard observedWindow !== window else { return }
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            observedWindow = window
            guard let window else { return }
            for (name, event) in [(NSWindow.willBeginSheetNotification, "ui.sheet.will_begin"),
                                  (NSWindow.didEndSheetNotification, "ui.sheet.did_end")] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    DispatchQueue.main.async { self?.snapshot(event) }
                })
            }
        }

        func update(confirmationID: UUID?, requestID: UUID?,
                    trace: @escaping (String, UUID?, [String: String]) -> Void) {
            self.trace = trace
            self.requestID = requestID
            guard self.confirmationID != confirmationID else { return }
            self.confirmationID = confirmationID
            if let confirmationID { lastConfirmationID = confirmationID }
            probeTask?.cancel()
            guard let confirmationID else { return }
            probeTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
                guard let self, self.confirmationID == confirmationID else { return }
                self.snapshot("ui.confirmation.sheet_probe")
            }
        }

        private func snapshot(_ event: String) {
            let sheet = window?.attachedSheet
            trace?(event, requestID, [
                "confirmation_id": (confirmationID ?? lastConfirmationID)?.uuidString ?? "none",
                "window_attached": String(window != nil),
                "parent_visible": String(window?.isVisible ?? false),
                "parent_key": String(window?.isKeyWindow ?? false),
                "sheet_attached": String(sheet != nil),
                "sheet_visible": String(sheet?.isVisible ?? false),
                "sheet_key": String(sheet?.isKeyWindow ?? false),
                "window_number": String(window?.windowNumber ?? -1)
            ])
        }

        deinit {
            probeTask?.cancel()
            observers.forEach(NotificationCenter.default.removeObserver)
        }
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
