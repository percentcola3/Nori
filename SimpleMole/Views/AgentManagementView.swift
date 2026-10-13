import AppKit
import SwiftUI

private enum AgentManagementSection: String, CaseIterable, Identifiable {
    case agents = "Agent", history = "History", skills = "Skill", mcp = "MCP"
    var id: String { rawValue }
    var symbol: String { self == .agents ? "cpu" : self == .history ? "clock.arrow.circlepath" : self == .skills ? "sparkles" : "server.rack" }
}

struct AgentsTabView: View {
    @ObservedObject var state: AppState
    @State private var section = AgentManagementSection.agents
    @StateObject private var historyStore = AgentHistoryStore()
    @ObservedObject private var l10n = L10n.shared
    @Namespace private var namespace

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            LiquidGlassGroup {
                VStack(spacing: 3) {
                    ForEach(AgentManagementSection.allCases) { item in
                        Button { section = item } label: {
                            Label(item == .history ? l10n.t("agents.section.history") : item.rawValue, systemImage: item.symbol)
                                .font(.system(size: 12, weight: section == item ? .semibold : .medium))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8).padding(.vertical, 10)
                                .contentShape(Rectangle())
                                .modifier(SidebarSelectionLens(selected: section == item,
                                    id: "agent-management", namespace: namespace))
                        }
                        .buttonStyle(.plain).accessibilityAddTraits(section == item ? .isSelected : [])
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(width: 108).padding(.leading, 10).padding(.top, 14)
            Group {
                switch section {
                case .agents: AgentInventoryView(state: state, onManageSkills: { section = .skills })
                case .history: AgentHistoryView(state: state, store: historyStore)
                case .skills: AgentResourceManagementView(state: state, skills: true)
                case .mcp: AgentResourceManagementView(state: state, skills: false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).contentPanel()
            .padding(EdgeInsets(top: 12, leading: 10, bottom: 12, trailing: 12))
        }
    }
}

struct AgentCompactResourceCard: View {
    let title: String
    let subtitle: String
    let symbol: String
    let selected: Bool
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: selected ? "checkmark.circle.fill" : symbol)
                    .foregroundStyle(selected ? Color.moleAccentText : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    Text(subtitle).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .padding(8).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!enabled)
        .modifier(ListRowSurface(selected: selected))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct AgentResourceManagementView: View {
    @ObservedObject var state: AppState
    let skills: Bool
    @ObservedObject private var l10n = L10n.shared
    @State private var search = ""
    @State private var selectedSources = Set<String>()
    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 250), spacing: 8)]
    private var mutationBlocked: Bool {
        state.isAgentTaskBusy || state.isUninstallMutationBlocked || state.uninstallQueue.activeJob != nil
    }
    private var skillResources: [AgentResourceCatalog.Skill] {
        AgentResourceCatalog.skills(state.agentSkills).filter {
            matches([$0.name, $0.id] + $0.bindings.flatMap(\.names))
        }
    }
    private var mcpResources: [AgentResourceCatalog.MCP] {
        AgentResourceCatalog.mcps(servers: state.agentServers, installations: state.agentMCPInstallations).filter {
            matches([$0.name, $0.installation?.path ?? ""] + $0.servers.flatMap { [$0.agentName, $0.endpoint, $0.configPath] })
        }
    }
    private var unbindings: AgentResourceChanges {
        let all = state.selectedAgentUnbindings
        return skills ? .init(skills: all.skills, registrations: all.registrations) : .init(servers: all.servers)
    }
    private var deletion: AgentResourceChanges {
        if skills {
            return .init(skills: AgentResourceCatalog.skills(state.agentSkills)
                .filter { selectedSources.contains($0.id) && $0.canDelete }.compactMap(\.body))
        }
        return .init(installations: AgentResourceCatalog.mcps(servers: state.agentServers,
            installations: state.agentMCPInstallations).filter { selectedSources.contains($0.id) && $0.canDelete }
            .compactMap(\.installation))
    }

    var body: some View {
        VStack(spacing: 0) {
            if !state.agentHasScanned {
                if state.agentScanning {
                    NoriScanActivity(text: state.agentStatus, assetName: "nori-agent")
                    Button(action: state.cancelAgentScan) { Text(l10n.t("cleanup.cancelScan")) }
                        .buttonStyle(SecondaryButtonStyle()).padding(.bottom, 12)
                } else {
                    NoriPlaceholderStage { size in
                        NoriIdlePlaceholder(state: state, size: size)
                        Button { state.requestScanAccess(.aiScan) } label: {
                            Label(l10n.t("agents.scan"), systemImage: "sparkle.magnifyingglass")
                        }.buttonStyle(PrimaryButtonStyle()).disabled(state.isAgentTaskBusy)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    TextField(l10n.t("agents.manage.search"), text: $search).textFieldStyle(.roundedBorder)
                    Button(action: selectBindings) { Text(l10n.t("agents.manage.selectBindings")) }
                        .buttonStyle(SecondaryButtonStyle()).disabled(state.isAgentTaskBusy)
                    Button(action: selectSources) { Text(l10n.t("agents.manage.selectSources")) }
                        .buttonStyle(SecondaryButtonStyle()).disabled(state.isAgentTaskBusy)
                }.padding(12)
                if !state.isAgentTaskBusy && (state.agentCleanupHasFeedback || !state.agentScanComplete) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(state.agentStatus).foregroundStyle(state.agentOutcomeMood == .attention ? Color.warning : Color.success)
                        if !state.agentOutcomeDetails.isEmpty {
                            DisclosureGroup(l10n.t("agents.result.details")) {
                                ScrollView {
                                    Text(TaskFeedbackDiagnostic.localized(state.agentOutcomeDetails).joined(separator: "\n"))
                                        .textSelection(.enabled).foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }.frame(maxHeight: 120)
                            }
                        }
                    }.font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12)
                }
                ScrollView {
                    LazyVStack(spacing: 10) {
                        if skills {
                            ForEach(skillResources) { resource in skillCard(resource) }
                            if skillResources.isEmpty { Text(l10n.t("agents.manage.empty")).foregroundStyle(.secondary).padding(24) }
                        } else {
                            ForEach(mcpResources) { resource in mcpCard(resource) }
                            if mcpResources.isEmpty { Text(l10n.t("agents.manage.empty")).foregroundStyle(.secondary).padding(24) }
                        }
                    }.padding(12)
                }
                Divider()
                footer
            }
        }
        .onReceive(state.$agentFeedbackID.removeDuplicates()) { _ in
            let ids = skills ? Set(AgentResourceCatalog.skills(state.agentSkills).map(\.id))
                : Set(AgentResourceCatalog.mcps(servers: state.agentServers, installations: state.agentMCPInstallations).map(\.id))
            selectedSources.formIntersection(ids)
        }
    }

    private func skillCard(_ resource: AgentResourceCatalog.Skill) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sourceHeader(id: resource.id, name: resource.name, path: resource.id,
                         count: resource.bindings.count, canDelete: resource.canDelete)
            if !resource.summary.isEmpty { Text(resource.summary).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2) }
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(resource.bindings) { binding in
                    AgentCompactResourceCard(title: binding.names.isEmpty ? "Skill" : binding.names.joined(separator: " / "),
                        subtitle: l10n.t(binding.link != nil ? "agents.manage.linkBinding"
                            : binding.registration != nil ? "agents.manage.configBinding" : "agents.manage.implicit"),
                        symbol: "link", selected: state.isAgentSkillBindingSelected(binding),
                        enabled: binding.removable && !state.isAgentTaskBusy,
                        action: { state.toggleAgentSkillBinding(binding) })
                        .help(binding.removable ? (binding.link?.path ?? binding.registration?.configPath ?? "")
                            : l10n.t("agents.manage.implicitReason"))
                }
            }
            if resource.bindings.contains(where: { !$0.removable }) {
                Text(l10n.t("agents.manage.implicitReason")).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if !resource.canDelete { Text(l10n.t("agents.manage.readOnly")).font(.system(size: 10)).foregroundStyle(.secondary) }
        }.padding(10).modifier(ListRowSurface())
    }

    private func mcpCard(_ resource: AgentResourceCatalog.MCP) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sourceHeader(id: resource.id, name: resource.name,
                path: resource.installation?.path ?? resource.servers.first?.endpoint ?? "", count: resource.servers.count,
                canDelete: resource.canDelete)
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(resource.servers) { server in
                    AgentCompactResourceCard(title: server.agentName,
                        subtitle: server.scope.map { l10n.tf("agents.manage.scope", $0) } ?? server.name,
                        symbol: "link", selected: state.agentSelectedServers.contains(server.id),
                        enabled: !state.isAgentTaskBusy && !server.issues.contains(.unreadableConfig),
                        action: { state.toggleAgentServer(server) }).help(server.configPath)
                }
            }
            ForEach(resource.servers.filter { $0.issues.contains(.unreadableConfig) }) { server in
                Label(server.agentName + " · " + l10n.t("agents.mcp.issue.unreadable"), systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10)).foregroundStyle(Color.warning)
            }
            if !resource.canDelete { Text(l10n.t("agents.manage.readOnly")).font(.system(size: 10)).foregroundStyle(.secondary) }
        }.padding(10).modifier(ListRowSurface())
    }

    private func sourceHeader(id: String, name: String, path: String, count: Int, canDelete: Bool) -> some View {
        HStack(spacing: 8) {
            Button { if !selectedSources.insert(id).inserted { selectedSources.remove(id) } } label: {
                HStack(spacing: 8) {
                    Image(systemName: selectedSources.contains(id) ? "checkmark.square.fill" : "square")
                        .foregroundStyle(selectedSources.contains(id) ? Color.moleAccentText : .secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(name).font(.system(size: 12, weight: .semibold))
                        Text(path).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Text(l10n.tf("agents.manage.bindings", count)).font(.system(size: 10)).foregroundStyle(.secondary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(!canDelete || state.isAgentTaskBusy)
            if path.hasPrefix("/") {
                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } label: {
                    Image(systemName: "folder")
                }.buttonStyle(MoleIconButtonStyle(size: 22)).help(l10n.t("agents.manage.open"))
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if state.isAgentTaskBusy {
                NoriStatusAnimation(mood: .working, size: 32)
                Text(state.agentStatus).font(.system(size: 11)).lineLimit(1).foregroundStyle(.secondary)
            } else {
                Button { state.requestScanAccess(.aiScan) } label: {
                    Image(systemName: "arrow.clockwise")
                }.buttonStyle(SecondaryButtonStyle())
                Button(action: clearSelection) { Image(systemName: "xmark.circle") }.buttonStyle(SecondaryButtonStyle())
                    .help(l10n.t("agents.manage.clear")).accessibilityLabel(l10n.t("agents.manage.clear"))
            }
            Spacer(minLength: 8)
            Button { state.requestAgentResourceChanges(unbindings) } label: {
                Text(l10n.t("agents.manage.unlink") + " (\(unbindings.count))")
            }.buttonStyle(PrimaryButtonStyle()).disabled(unbindings.count == 0 || mutationBlocked)
            Button { state.requestAgentResourceChanges(deletion) } label: {
                Text(l10n.t("agents.manage.delete") + " (\(deletion.count))")
            }.buttonStyle(DangerButtonStyle()).disabled(deletion.count == 0 || mutationBlocked)
        }.padding(12)
    }

    private func matches(_ values: [String]) -> Bool {
        search.isEmpty || values.contains { $0.localizedCaseInsensitiveContains(search) }
    }
    private func selectSources() {
        selectedSources.formUnion(skills ? skillResources.filter(\.canDelete).map(\.id) : mcpResources.filter(\.canDelete).map(\.id))
    }
    private func selectBindings() {
        if skills {
            for binding in skillResources.flatMap(\.bindings) where binding.removable && !state.isAgentSkillBindingSelected(binding) {
                state.toggleAgentSkillBinding(binding)
            }
        } else {
            for server in mcpResources.flatMap(\.servers) where !server.issues.contains(.unreadableConfig)
                && !state.agentSelectedServers.contains(server.id) { state.toggleAgentServer(server) }
        }
    }
    private func clearSelection() {
        selectedSources = []
        if skills { state.agentSelectedSkills = []; state.agentSelectedSkillRegistrations = [] }
        else { state.agentSelectedServers = [] }
    }
}
