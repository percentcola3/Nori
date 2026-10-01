import AppKit
import SwiftUI

/// 手动扫描后统一展示 Agent、全局 Skill 与 MCP 类目；关联项只解除关联。
struct AgentsTabView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var collapsed: Set<String> = []
    @State private var confirmation: AgentActionIntent?
    @Namespace private var glassNamespace

    private var presentationPhase: Int {
        if state.agentScanning || state.agentApplying { return 1 }
        return state.agentHasScanned ? 2 : 0
    }

    var body: some View {
        ZStack {
            NoriPageTransition(phase: presentationPhase) {
            VStack(spacing: 0) {
                if state.agentScanning || state.agentApplying {
                    NoriScanActivity(text: state.agentStatus,
                                     assetName: state.agentScanning ? "nori-agent" : "nori-tidying", quiet: true)
                } else if !state.agentHasScanned {
                    emptyState
                } else {
                    if state.agentOutcomeMood == .attention || !state.agentScanComplete { statusRow }
                    resourceList
                    Divider()
                    actions
                }
            }
            }
            .disabled(confirmation != nil)
            .accessibilityHidden(confirmation != nil)
            if let confirmation {
                Color.surface1.opacity(0.45).ignoresSafeArea()
                AgentActionConfirmation(intent: confirmation, cancel: { self.confirmation = nil }) {
                    self.confirmation = nil
                    switch confirmation {
                    case .cleanup: state.applyAgentCleanup()
                    case .uninstall(let plan): state.uninstallAgentAndClean(plan)
                    }
                }
                .liquidSurface("agent-confirmation")
                .padding(20)
                .transition(.opacity)
            }
        }
        .environment(\.liquidNamespace, glassNamespace)
        .onReceive(state.$agentHasScanned.removeDuplicates()) { hasScanned in
            if !hasScanned { collapsed.removeAll(); confirmation = nil }
        }
        .onExitCommand { confirmation = nil }
    }

    private var emptyState: some View {
        NoriPlaceholderStage { size in
            NoriIdlePlaceholder(state: state, size: size)
            Button { state.requestScanAccess(.aiScan) } label: {
                Label(l10n.t("agents.scan"), systemImage: "sparkle.magnifyingglass")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(state.isBusy)
            if state.agentOutcomeMood != nil {
                Text(state.agentStatus)
                    .font(.system(size: 11))
                    .foregroundStyle(state.agentOutcomeMood == .attention ? Color.warning : Color.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 420)
            }
        }
    }

    private var statusRow: some View {
        Label(state.agentStatus, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 11)).foregroundStyle(Color.warning)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.bottom, 6)
    }

    private var resourceList: some View {
        ScrollView {
            LiquidGlassGroup {
                LazyVStack(spacing: 12) {
                    Text(l10n.t("agents.notice.installed"))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    let groups = state.agentGroups.filter {
                        $0.id != "shared-mcp" && $0.id != "chrome-devtools-mcp"
                    }
                    if groups.isEmpty && state.agentMCPInstallations.isEmpty &&
                        !state.agentGroups.contains(where: { $0.id == "chrome-devtools-mcp" }) { emptyResult }
                    ForEach(groups) { group in
                        VStack(spacing: 8) {
                            groupHeader(group)
                            if !collapsed.contains(group.id) {
                                if group.id == "shared" {
                                    Text(l10n.t("agents.notice.skills"))
                                        .font(.system(size: 10)).foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                LazyVStack(spacing: 8) { groupContents(group) }
                                    .padding(.leading, 14)
                                    .transition(.molePanelReveal)
                            }
                        }
                        .clipped()

                    }
                    ForEach(state.agentGroups.filter { $0.id == "shared-mcp" || $0.id == "chrome-devtools-mcp" }) { group in
                        VStack(spacing: 8) {
                            groupHeader(group)
                            if !collapsed.contains(group.id) {
                                VStack(spacing: 8) {
                                    if group.id == "shared-mcp" {
                                        Text(l10n.t("agents.notice.mcp"))
                                            .font(.system(size: 10)).foregroundStyle(.secondary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        ForEach(state.agentMCPInstallations) { installation in
                                            installationRow(installation)
                                        }
                                    } else {
                                        groupContents(group)
                                    }
                                }.padding(.leading, 14)
                                .transition(.molePanelReveal)
                            }
                        }
                        .clipped()

                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 4)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var emptyResult: some View {
        Text(l10n.t("agents.status.emptySection"))
            .font(.system(size: 11)).foregroundStyle(.secondary).padding(24)
            .frame(maxWidth: .infinity)
    }

    private func groupHeader(_ group: AgentGroupSummary) -> some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(reduceMotion ? nil : MoleMotion.panel) {
                    if collapsed.contains(group.id) { collapsed.remove(group.id) } else { collapsed.insert(group.id) }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: group.id == "shared" ? "sparkles" :
                            (group.id == "shared-mcp" || group.id == "chrome-devtools-mcp" ? "server.rack" : "brain"))
                        .foregroundStyle(Color.moleAccentText)
                    Text(group.name).font(.system(size: 12, weight: .semibold))
                    if !group.documented { AgentRiskTag(text: l10n.t("agents.badge.review"), high: true) }
                    Spacer()
                    Text(l10n.tf("agents.group.reclaimable", ByteFormat.format(group.id == "shared-mcp"
                        ? AppState.uniqueAgentBytes(state.agentMCPInstallations.map { ($0.path, $0.bytes) })
                        : state.agentGroupBytes(group))))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(collapsed.contains(group.id) ? -90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(l10n.t(collapsed.contains(group.id) ? "agents.collapsed" : "agents.expanded"))
            if !state.agentCLIInstallations.filter({ $0.agentID == group.id }).isEmpty {
                Button { confirmation = .uninstall(state.agentRemovalPlan(for: group)) } label: {
                    Label(l10n.t("agents.cli.uninstallClean"), systemImage: "trash")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.danger)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain).disabled(state.isBusy)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .modifier(ListRowGlass())
    }

    @ViewBuilder private func groupContents(_ group: AgentGroupSummary) -> some View {
        ForEach(group.categoryIDs, id: \.self) { id in
            if let index = state.agentCategories.firstIndex(where: { $0.id == id }) {
                CategoryRowView(category: $state.agentCategories[index], selectionEnabled: !state.isBusy,
                                highlightsSensitiveData: true)
            }
        }
        let skills = state.agentSkills.filter { $0.agentID == group.id }
        if !skills.isEmpty {
            subsectionHeader(l10n.t("agents.subsection.skills"), count: skills.count)
            ForEach(skills) { skill in skillRow(skill) }
        }
        let servers = state.agentServers.filter { $0.agentID == group.id }
        if !servers.isEmpty {
            subsectionHeader(l10n.t("agents.subsection.mcp"), count: servers.count)
            ForEach(servers) { server in serverRow(server) }
        }
    }

    private func subsectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold))
            Text("\(count)").font(.system(size: 10).monospacedDigit())
            Spacer()
        }
        .foregroundStyle(.secondary).padding(.horizontal, 4).padding(.top, 2)
    }

    private func skillRow(_ skill: AgentSkill) -> some View {
        let selected = state.agentSelectedSkills.contains(skill.path)
        return HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: Binding(get: { selected }, set: { _ in state.toggleAgentSkill(skill) }))
                .toggleStyle(.checkbox).controlSize(.mini).labelsHidden().fixedSize()
                .disabled(skill.identity.isEmpty || state.isBusy)
                .accessibilityLabel(skill.name)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(skill.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    AgentRiskTag(text: l10n.t(skill.linked ? "agents.skills.unlink" : "agents.skills.deleteBody"),
                                 high: !skill.linked)
                }
                if !skill.summary.isEmpty {
                    Text(skill.summary).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                }
                Text(abbreviate(skill.path)).font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                if let target = skill.linkTarget {
                    Text("→ " + abbreviate(target)).font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
                if !skill.usedBy.isEmpty {
                    Text(l10n.tf("agents.resource.usedBy", skill.usedBy.joined(separator: "、")))
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if skill.bytes > 0 { SizeBadge(text: ByteFormat.format(skill.bytes), prominent: selected) }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .modifier(ListRowGlass(selected: selected))
    }

    private func serverRow(_ server: AgentMCPServer) -> some View {
        let selected = state.agentSelectedServers.contains(server.id)
        let unreadable = server.issues.contains(.unreadableConfig)
        let issues = server.issues.reduce(into: [AgentMCPServer.Issue]()) { result, issue in
            if !result.contains(issue) { result.append(issue) }
        }
        return HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: Binding(get: { selected }, set: { _ in state.toggleAgentServer(server) }))
                .toggleStyle(.checkbox).controlSize(.mini).labelsHidden().fixedSize().disabled(state.isBusy)
                .accessibilityLabel(server.name)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: server.remote ? "globe" : "terminal").foregroundStyle(.secondary)
                    Text(server.name).font(.system(size: 12, weight: .medium))
                    AgentRiskTag(text: l10n.t(unreadable ? "agents.mcp.deleteConfig" : "agents.mcp.unlink"), high: unreadable)
                    Text(server.agentName).font(.system(size: 9)).foregroundStyle(.secondary)
                    if server.disabled { Text(l10n.t("agents.mcp.disabled")).font(.system(size: 9)) }
                    Spacer()
                    Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: server.configPath)]) } label: {
                        Image(systemName: "folder").font(.system(size: 10))
                    }
                    .buttonStyle(MoleIconButtonStyle(size: 20))
                }
                if !server.endpoint.isEmpty {
                    Text(server.endpoint).font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                if let scope = server.scope {
                    Text(abbreviate(scope)).font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
                }
                ForEach(issues, id: \.self) { issue in
                    Label(issueText(issue), systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10)).foregroundStyle(Color.warning)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .modifier(ListRowGlass(selected: selected))
    }

    private func installationRow(_ installation: AgentMCPInstallation) -> some View {
        let selected = state.agentSelectedMCPInstallations.contains(installation.id)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(get: { selected }, set: { _ in state.toggleAgentMCPInstallation(installation) }))
                    .toggleStyle(.checkbox).controlSize(.mini).labelsHidden().fixedSize()
                    .disabled(state.isBusy || installation.identity.isEmpty)
                    .accessibilityLabel(installation.name)
                Text(installation.name).font(.system(size: 12, weight: .medium))
                AgentRiskTag(text: l10n.t("agents.mcp.deleteBody"), high: true)
                Spacer()
                SizeBadge(text: ByteFormat.format(installation.bytes), prominent: selected)
            }
            Text(abbreviate(installation.path)).font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            let agentIDs = Set(installation.serverIDs.compactMap { $0.split(separator: "|").first.map(String.init) })
            let names = AgentCatalog.definitions.filter { agentIDs.contains($0.id) }.map(\.name)
            Text(l10n.tf("agents.resource.usedBy", Array(Set(names)).sorted().joined(separator: "、")))
                .font(.system(size: 10)).foregroundStyle(.secondary)
            Text(l10n.t("agents.mcp.bodyImpact")).font(.system(size: 10)).foregroundStyle(Color.warning)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .modifier(ListRowGlass(selected: selected))
    }

    private func issueText(_ issue: AgentMCPServer.Issue) -> String {
        switch issue {
        case .commandMissing(let command): return l10n.tf("agents.mcp.issue.command", command)
        case .plaintextSecret(let key, let masked): return l10n.tf("agents.mcp.issue.secret", key, masked)
        case .unreadableConfig: return l10n.t("agents.mcp.issue.unreadable")
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Spacer()
            Button { confirmation = .cleanup(state.agentCleanupDetails) } label: {
                Label(state.agentSelectedCount > 0
                      ? l10n.tf("agents.apply.withCount", state.agentSelectedCount, ByteFormat.format(state.agentSelectedBytes))
                      : l10n.t("agents.apply"), systemImage: "trash.fill")
            }
            .buttonStyle(PrimaryButtonStyle()).disabled(state.agentSelectedCount == 0 || state.isBusy)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

private enum AgentActionIntent {
    case cleanup([String])
    case uninstall(AgentRemovalPlan)
}

private struct AgentActionConfirmation: View {
    let intent: AgentActionIntent
    let cancel: () -> Void
    let confirm: () -> Void
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(l10n.t("agents.confirm.title"), systemImage: "exclamationmark.triangle")
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.warning)
            Text(l10n.t(messageKey)).font(.system(size: 12))
            ScrollView {
                Text(details).font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }.frame(maxHeight: 260)
            HStack {
                Spacer()
                Button(l10n.t("common.cancel"), action: cancel).buttonStyle(SecondaryButtonStyle())
                Button(l10n.t("agents.confirm.proceed"), action: confirm).buttonStyle(DangerButtonStyle())
            }
        }
        .padding(24).frame(maxWidth: 580)
    }

    private var details: String {
        switch intent {
        case .cleanup(let lines): return lines.joined(separator: "\n\n")
        case .uninstall(let plan):
            return plan.details.joined(separator: "\n\n")
        }
    }

    private var messageKey: String {
        switch intent {
        case .cleanup: return "agents.confirm.message"
        case .uninstall: return "agents.cli.cleanNotice"
        }
    }
}

private struct AgentRiskTag: View {
    let text: String
    let high: Bool
    var safe = false
    var body: some View {
        Text(text).font(.system(size: 9, weight: .semibold))
            .foregroundStyle(safe ? Color.success : (high ? Color.danger : Color.warning))
            .padding(.horizontal, 5).padding(.vertical, 2)
    }
}
