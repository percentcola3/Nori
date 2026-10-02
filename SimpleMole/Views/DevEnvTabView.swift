import SwiftUI

/// A developer workspace with automatic read-only refresh and explicit management actions.
struct DevEnvTabView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var l10n = L10n.shared
    @Namespace private var glassNamespace
    @State private var panelSearchStates: [DeveloperWorkspaceSearchSource: DeveloperWorkspaceSearchState] = [:]

    private var isSearching: Bool {
        state.isScanningEnv || state.isRefreshingGc || state.devWorkspaceRefreshPending
            || DeveloperWorkspaceSearchSource.allCases.contains { source in
                guard let search = panelSearchStates[source] else { return true }
                return search.refreshToken != state.devWorkspaceRefreshToken || search.isSearching
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LiquidGlassGroup {
                    VStack(alignment: .leading, spacing: 16) {
                        DeveloperWorkspaceSection(id: "shell", symbol: "slider.horizontal.3",
                                                  title: DevWorkspaceText.choose("环境与 Shell", "Environment & Shell")) { isExpanded in
                            DeveloperShellPanel(state: state, refreshToken: state.devWorkspaceRefreshToken, isExpanded: isExpanded)
                        }
                        DeveloperWorkspaceSection(id: "network", symbol: "network",
                                                  title: DevWorkspaceText.choose("网络与 hosts", "Network & hosts")) { isExpanded in
                            DeveloperNetworkPanel(state: state, refreshToken: state.devWorkspaceRefreshToken, isExpanded: isExpanded)
                        }
                        DeveloperWorkspaceSection(id: "runtime", symbol: "shippingbox",
                                                  title: DevWorkspaceText.choose("运行时清理", "Runtime cleanup")) { isExpanded in
                            DeveloperRuntimePanel(state: state, isExpanded: isExpanded)
                        }
                        DeveloperWorkspaceSection(id: "cli", symbol: "terminal",
                                                  title: DevWorkspaceText.choose("CLI 工具", "CLI tools")) { isExpanded in
                            DeveloperCLIPanel(refreshToken: state.devWorkspaceRefreshToken, isExpanded: isExpanded)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .padding(.bottom, 20)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if isSearching {
                HStack(spacing: 8) {
                    NoriStatusAnimation(mood: .working, size: 36, assetName: "nori-working")
                    Text(DevWorkspaceText.choose("检索中", "Searching"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(DevWorkspaceText.choose("检索中", "Searching"))
                .accessibilityIdentifier("dev-workspace-search-activity")
            }
        }
        .environment(\.liquidNamespace, glassNamespace)
        .onPreferenceChange(DeveloperWorkspaceSearchKey.self) { searches in
            panelSearchStates = searches
        }
        .sheet(isPresented: $state.showSimulatorDevices) {
            SimulatorDevicesView(store: state.simulatorInventory, canMutate: !state.isBusy)
                .taskFeedback(taskNoticeBinding, retry: state.retryTaskNotice)
        }
        .sheet(isPresented: $state.showDockerDetails) {
            DockerDetailsView(store: state.dockerInventory)
                .taskFeedback(taskNoticeBinding, retry: state.retryTaskNotice)
        }
    }

    private var taskNoticeBinding: Binding<TaskFeedbackNotice?> {
        Binding(get: { state.taskNotice }, set: { _ in state.dismissTaskNotice() })
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
