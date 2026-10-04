import SwiftUI

struct DevEnvTabView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var l10n = L10n.shared
    @Namespace private var glassNamespace
    @AppStorage("devWorkspaceSectionID") private var selection = DeveloperWorkspaceSection.overview.rawValue
    @ObservedObject private var shellModel: DeveloperShellModel
    @ObservedObject private var networkModel: DeveloperNetworkModel
    @ObservedObject private var networkToolsModel: DeveloperNetworkToolsModel
    @ObservedObject private var cliModel: DeveloperCLIModel
    @ObservedObject private var sshModel: DeveloperSSHGitModel
    @ObservedObject private var workspace: DeveloperWorkspaceModel
    @State private var issues: [DeveloperEnvironmentIssue] = []
    @State private var operationNotice: TaskFeedbackNotice?
    private var section: DeveloperWorkspaceSection { DeveloperWorkspaceSection(rawValue: selection) ?? .overview }

    init(state: AppState) {
        self.state = state
        let session = state.developerWorkspaceSession
        shellModel = session.shell
        networkModel = session.network
        networkToolsModel = session.networkTools
        cliModel = session.cli
        sshModel = session.ssh
        workspace = session.workspace
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                DevSectionSidebar(selection: $selection, details: sidebarDetails)
                Spacer(minLength: 12)
                if isSearching {
                    HStack(spacing: 0) {
                        NoriStatusAnimation(mood: .working, size: 36, assetName: "nori-working")
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(l10n.t("dev.workspace.searching"))
                    .accessibilityIdentifier("dev-workspace-search-activity")
                }
            }
            .frame(width: 158).frame(maxHeight: .infinity, alignment: .topLeading)
            .padding(.leading, 14).padding(.top, 14).padding(.bottom, 8)
            ScrollView {
                LiquidGlassGroup {
                    VStack(alignment: .leading, spacing: 12) {
                        sectionContent
                        DeveloperCommandPanel(workspace: workspace)
                    }.frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.leading, 14).padding(.trailing, 20).padding(.vertical, 14)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(maxHeight: .infinity).environment(\.liquidNamespace, glassNamespace)
        .task(id: state.devWorkspaceRefreshToken) {
            workspace.attach(state: state)
            migrateSelection()
            await workspace.refresh()
            guard !Task.isCancelled else { return }
            await refreshPanels()
            state.runConfigAudits()
            updateIssues()
        }
        .onChange(of: workspace.refreshRevision) { _ in
            state.runConfigAudits(force: true)
            state.scanDevEnv(announce: false, presentingPermissionCenter: false, notifyingUser: false)
            state.scanGc(force: true)
            Task { await refreshPanels(); updateIssues() }
        }
        .onChange(of: workspace.operationError) { message in
            operationNotice = message.map { TaskFeedbackNotice(message: $0) }
        }
        .onReceive(state.$shellIssues) { _ in scheduleIssues() }
        .onReceive(state.$devEnvEntries) { _ in scheduleIssues() }
        .onReceive(networkModel.objectWillChange) { _ in scheduleIssues() }
        .onReceive(shellModel.objectWillChange) { _ in scheduleIssues() }
        .onReceive(networkToolsModel.objectWillChange) { _ in scheduleIssues() }
        .onReceive(l10n.objectWillChange) { _ in scheduleIssues() }
        .onReceive(workspace.$environmentIssues) { _ in scheduleIssues() }
        .onReceive(workspace.$packages) { _ in scheduleIssues() }
        .onReceive(workspace.$shellProfile) { _ in scheduleIssues() }
        .onReceive(sshModel.objectWillChange) { _ in scheduleIssues() }
        .sheet(isPresented: $state.showSimulatorDevices) {
            SimulatorDevicesView(store: state.simulatorInventory, canMutate: !state.isBusy)
                .taskFeedback(taskNoticeBinding, retry: state.retryTaskNotice)
        }
        .sheet(isPresented: $state.showDockerDetails) {
            DockerDetailsView(store: state.dockerInventory).taskFeedback(taskNoticeBinding, retry: state.retryTaskNotice)
        }
        .taskFeedback(Binding(get: { operationNotice }, set: { operationNotice = $0; if $0 == nil { workspace.operationError = nil } }))
    }

    @ViewBuilder private var sectionContent: some View {
        switch section {
        case .overview: DeveloperOverviewPanel(workspace: workspace, state: state, issues: issues) { selection = $0.rawValue }
        case .toolchains:
            DeveloperToolchainPanel(workspace: workspace, state: state, shell: shellModel)
            DeveloperCLIPanel(model: cliModel)
        case .packages: DeveloperPackagesPanel(workspace: workspace, state: state)
        case .network:
            DeveloperNetworkPanel(state: state, model: networkModel, workspace: workspace)
            DeveloperNetworkToolsPanel(state: state, workspace: workspace, network: networkModel, model: networkToolsModel)
        case .sshGit: DeveloperSSHGitPanel(workspace: workspace, state: state, model: sshModel).disabled(workspace.commandRunning || state.isDeveloperConfigurationWriting)
        case .shell:
            DeveloperShellPanel(model: shellModel).disabled(workspace.commandRunning || state.isDeveloperConfigurationWriting)
            DeveloperShellDiagnosticsPanel(workspace: workspace, state: state)
        case .cleanup:
            DeveloperRuntimePanel(state: state).disabled(workspace.commandRunning)
            DevLinkButton(title: l10n.t("dev.cleanup.projects"), symbol: "arrow.right") {
                if let index = state.visiblePages.firstIndex(of: .analyze) { state.selectedTab = index }
            }
        }
    }

    private var sidebarDetails: [DeveloperWorkspaceSection: String] {
        var result: [DeveloperWorkspaceSection: String] = [:]
        for item in DeveloperWorkspaceSection.allCases {
            let count = issues.filter { $0.section == item }.count
            if count > 0 { result[item] = l10n.tf(count == 1 ? "dev.overview.count.single" : "dev.overview.count", count) }
        }
        result[.overview] = issues.isEmpty ? "" : l10n.tf(issues.count == 1 ? "dev.overview.count.single" : "dev.overview.count", issues.count)
        if result[.shell] == nil { result[.shell] = shellModel.inventory?.kind == .bash ? (shellModel.inventory?.loginFile ?? ".bash_profile") : ".zshrc" }
        return result
    }
    private var isSearching: Bool {
        workspace.isRefreshing || cliModel.isChecking || shellModel.isRefreshing
            || networkModel.isLoading || networkToolsModel.isLoading || networkToolsModel.isTesting
            || sshModel.isRefreshing || workspace.isLoadingPackages
            || state.isScanningEnv || state.isRefreshingGc || state.devWorkspaceRefreshPending
    }
    private func refreshPanels() async {
        let token = state.devWorkspaceRefreshToken &+ workspace.refreshRevision &* 10_000
        cliModel.refresh(for: token, environment: workspace.terminal.environment)
        async let shell: Void = shellModel.refresh(for: token)
        async let network: Void = networkModel.refresh(for: token)
        async let ssh: Void = sshModel.refresh(environment: workspace.terminal.environment)
        async let tools: Void = networkToolsModel.refresh()
        _ = await (shell, network, ssh, tools)
    }
    private func scheduleIssues() { DispatchQueue.main.async { updateIssues() } }
    private func updateIssues() {
        var next = workspace.environmentIssues + sshModel.issues + networkToolsModel.environmentIssues
        func add(_ id: String, _ key: String, _ detail: String, _ section: DeveloperWorkspaceSection, _ severity: DeveloperEnvironmentIssue.Severity = .suggestion) {
            next.append(.init(id: id, titleKey: key, detail: DeveloperSecretRedactor.redact(detail), section: section, severity: severity))
        }
        for item in state.shellIssues where item.kind == "orphan" { add(item.id, "dev.issue.shell.orphan", item.location, .shell) }
        if !(networkModel.snapshot?.effectiveProxies.isEmpty ?? true), !networkModel.enabledCustomHostnames.isEmpty { add("hosts-proxy", "dev.issue.hosts", networkModel.enabledCustomHostnames.joined(separator: " · "), .network, .information) }
        if networkModel.pendingChanges > 0 { add("hosts-draft", "dev.issue.hostsDraft", "", .network, .information) }
        if shellModel.pendingChanges > 0 { add("shell-draft", "dev.issue.draft", "", .shell, .information) }
        let updates = workspace.packages.packages.filter { $0.available != nil }
        if !updates.isEmpty { add("packages", "dev.issue.packages", updates.map(\.name).joined(separator: " · "), .packages) }
        let failed = workspace.packages.services.filter { $0.status == "error" }
        if !failed.isEmpty { add("services", "dev.issue.services", failed.map(\.name).joined(separator: " · "), .packages, .attention) }
        let bytes = state.devEnvEntries.filter(DeveloperRuntimePolicy.canClean).reduce(UInt64(0)) { $0 &+ $1.bytes }
        if bytes > 10 * 1_024 * 1_024 * 1_024 { add("cleanup", "dev.issue.cleanup", ByteFormat.format(bytes), .cleanup, .information) }
        if let median = workspace.shellProfile?.median, median > 1 { add("shell-slow", "dev.shell.slow", l10n.tf("dev.shell.profile.median", median), .shell) }
        next.sort { $0.severity.rawValue < $1.severity.rawValue }
        if next != issues { issues = next }
    }
    private func migrateSelection() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "devWorkspaceSectionID") == nil else { return }
        if let old = defaults.object(forKey: "devWorkspaceSection") as? Int {
            let oldSections: [DeveloperWorkspaceSection] = [.shell, .network, .cleanup, .toolchains]
            selection = oldSections.indices.contains(old) ? oldSections[old].rawValue : DeveloperWorkspaceSection.overview.rawValue
        }
    }
    private var taskNoticeBinding: Binding<TaskFeedbackNotice?> { Binding(get: { state.taskNotice }, set: { _ in state.dismissTaskNotice() }) }
}

struct DevSectionSidebar: View {
    @Binding var selection: String
    let details: [DeveloperWorkspaceSection: String]
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var namespace
    var body: some View {
        LiquidGlassGroup {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(DeveloperWorkspaceSection.allCases) { item in
                    Button { selection = item.rawValue } label: {
                        HStack(spacing: 8) {
                            Image(systemName: item.symbol).font(.system(size: 12, weight: .medium)).frame(width: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(l10n.t(item.titleKey)).font(.system(size: 12, weight: selection == item.rawValue ? .semibold : .medium))
                                if let detail = details[item], !detail.isEmpty { Text(detail).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1) }
                            }
                            Spacer(minLength: 0)
                        }.padding(.horizontal, 8).padding(.vertical, 9)
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(RoundedRectangle(cornerRadius: 10))
                        .modifier(SelectionLens(selected: selection == item.rawValue, namespace: namespace))
                    }.buttonStyle(MolePlainButtonStyle(pressedScale: 0.98))
                    .accessibilityIdentifier("dev-section-" + item.rawValue)
                    .accessibilityAddTraits(selection == item.rawValue ? .isSelected : [])
                }
            }
        }.animation(reduceMotion ? nil : MoleMotion.selection, value: selection).accessibilityIdentifier("dev-workspace-sections")
    }
    private struct SelectionLens: ViewModifier {
        let selected: Bool
        let namespace: Namespace.ID
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
        @Environment(\.controlActiveState) private var controlActiveState
        @ViewBuilder func body(content: Content) -> some View {
            if #available(macOS 26.0, *), !reduceTransparency, controlActiveState == .key {
                if selected {
                    content.glassEffect(.regular.interactive(!reduceMotion), in: RoundedRectangle(cornerRadius: 10))
                        .glassEffectID("dev-section-selection", in: namespace).glassEffectTransition(reduceMotion ? .identity : .matchedGeometry)
                } else { content }
            } else {
                content.background { if selected { GlassSurface(cornerRadius: 10, usesSystemGlass: false, highlighted: true) } }
            }
        }
    }
}

/// 白名单管理：直接维护 Mole 引擎共用的 `~/.config/mole/whitelist`。
struct WhitelistSheet: View {
    @ObservedObject var state: AppState
    @ObservedObject private var l10n = L10n.shared
    @State private var newPath = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(l10n.t("wl.title"))
                        .font(.system(size: 14, weight: .semibold))
                    Text(l10n.t("wl.subtitle"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(l10n.t("common.done")) { state.showWhitelistSheet = false }
                    .buttonStyle(PrimaryButtonStyle())
                Button {
                    state.showWhitelistSheet = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            .padding(16)

            ScrollView {
                LazyVStack(spacing: 4) {
                    if state.whitelistEntries.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "shield")
                                .font(.system(size: 22, weight: .light))
                                .foregroundStyle(.tertiary)
                            Text(l10n.t("wl.empty.title"))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Text(l10n.t("wl.empty.subtitle"))
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 24)
                    }
                    ForEach(state.whitelistEntries, id: \.self) { entry in
                        HStack(spacing: 8) {
                            Image(systemName: "shield.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.moleAccentText)
                            Text(entry)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button {
                                state.removeWhitelistEntry(entry)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Color.danger.opacity(0.7))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.surface2))
                    }
                }
                .padding(.horizontal, 16)
            }

            Divider()
            HStack(spacing: 8) {
                TextField(l10n.t("wl.add.placeholder"), text: $newPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                Button {
                    state.addWhitelistEntry(newPath)
                    newPath = ""
                } label: {
                    Label(l10n.t("wl.add"), systemImage: "plus")
                }
                .buttonStyle(SecondaryButtonStyle())
                .labelStyle(.iconOnly)
                .disabled(!newPath.trimmingCharacters(in: .whitespaces).hasPrefix("/"))
            }
            .padding(16)
        }
        .frame(width: 520, height: 420)
        .onAppear { state.loadWhitelist() }
    }
}
