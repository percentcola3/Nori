import AppKit
import SwiftUI

/// 手动扫描后统一展示 Agent、全局 Skill 与 MCP 类目；关联项只解除关联。
struct AgentInventoryView: View {
    @ObservedObject var state: AppState
    var onManageSkills: () -> Void = {}
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var collapsed: Set<String> = []
    @State private var expandedCLIInstallations: Set<String> = []

    private var presentationPhase: Int {
        if state.agentScanning { return 1 }
        return state.agentHasScanned ? 2 : 0
    }

    private var showsCleanupFailure: Bool {
        state.agentCleanupHasFeedback && state.agentOutcomeMood == .attention
    }

    var body: some View {
        NoriPageTransition(phase: presentationPhase) {
            VStack(spacing: 0) {
                if state.agentScanning {
                    NoriPlaceholderStage { size in
                        NoriStatusAnimation(mood: .working, size: size, assetName: "nori-agent")
                        NoriCurrentFileView(path: state.agentScanCurrentPath)
                        Button(action: state.cancelAgentScan) {
                            Label(l10n.t("cleanup.cancelScan"), systemImage: "xmark.circle")
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .accessibilityIdentifier("agents-scan-cancel")
                    }
                } else if !state.agentHasScanned {
                    emptyState
                } else {
                    if !state.isAgentTaskBusy && (showsCleanupFailure || !state.agentScanComplete || state.agentRetryAvailable || !state.agentOutcomeDetails.isEmpty) {
                        statusRow
                    }
                    resourceList
                    Divider()
                    actions
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onReceive(state.$agentHasScanned.removeDuplicates()) { hasScanned in
            if !hasScanned {
                collapsed.removeAll()
                expandedCLIInstallations.removeAll()
            }
        }
    }

    private var scanButton: some View {
        Button { state.requestScanAccess(.aiScan) } label: {
            Label(l10n.t("agents.scan"), systemImage: "sparkle.magnifyingglass")
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(state.isAgentTaskBusy)
    }

    private var emptyState: some View {
        NoriPlaceholderStage { size in
            NoriIdlePlaceholder(state: state, size: size)
            scanButton
            if state.agentOutcomeMood != nil {
                Text(state.agentStatus)
                    .font(.system(size: 11))
                    .foregroundStyle(state.agentOutcomeMood == .attention ? Color.warning : Color.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 420)
            }
        }
    }

    private var statusRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(state.agentStatus, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.warning)
            if !state.agentFailureApplications.isEmpty {
                Text(state.agentFailureApplications.joined(separator: "、"))
                    .foregroundStyle(.secondary)
            }
            if !state.agentOutcomeDetails.isEmpty {
                DisclosureGroup(l10n.t("agents.result.details")) {
                    ScrollView {
                        Text(TaskFeedbackDiagnostic.localized(state.agentOutcomeDetails).joined(separator: "\n\n"))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                }
                .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.bottom, 6)
    }

    private var resourceList: some View {
        let skills = AgentResourceCatalog.skills(state.agentSkills)
        return ScrollView {
            LazyVStack(spacing: 12) {
                let snapshots = state.agentGroups.compactMap { state.agentStorageFootprints[$0.id] }
                if !snapshots.isEmpty {
                    HStack {
                        Text(l10n.t("agents.storage.summary")).font(.system(size: 11, weight: .medium))
                        Spacer()
                        AgentStorageSummaryView(storage: AgentStorageFootprint.totals(snapshots))
                    }
                    .padding(10).modifier(ListRowSurface(emphasis: .header))
                }
                Text(l10n.t("agents.notice.installed"))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                let groups = state.agentGroups.filter {
                    $0.id != "shared" && $0.id != "shared-mcp" && $0.id != "chrome-devtools-mcp"
                }
                if groups.isEmpty && state.agentMCPInstallations.isEmpty &&
                    !state.agentGroups.contains(where: { $0.id == "chrome-devtools-mcp" }) { emptyResult }
                ForEach(groups) { group in
                    VStack(spacing: 8) {
                        groupHeader(group)
                        if !collapsed.contains(group.id) {
                            LazyVStack(spacing: 8) { groupContents(group, resources: skills) }
                                .padding(.leading, 14)
                                .transition(.molePanelReveal)
                        }
                    }
                    .clipped()

                }
                ForEach(state.agentGroups.filter { $0.id == "chrome-devtools-mcp" }) { group in
                    VStack(spacing: 8) {
                        groupHeader(group)
                        if !collapsed.contains(group.id) {
                            VStack(spacing: 8) {
                                groupContents(group, resources: skills)
                            }.padding(.leading, 14)
                            .transition(.molePanelReveal)
                        }
                    }
                    .clipped()

                }
            }
            .padding(.horizontal, 16).padding(.vertical, 4)
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
                guard !state.agentApplying else { return }
                withAnimation(reduceMotion ? nil : MoleMotion.panel) {
                    if collapsed.contains(group.id) { collapsed.remove(group.id) } else { collapsed.insert(group.id) }
                }
            } label: {
                HStack(spacing: 8) {
                    if group.id == "shared" || group.id == "shared-mcp" {
                        Image(systemName: group.id == "shared" ? "sparkles" : "server.rack")
                            .foregroundStyle(Color.moleAccentText)
                            .frame(width: 24, height: 24)
                    } else {
                        AgentIconView(agentID: group.id, size: 24)
                    }
                    Text(group.name).font(.system(size: 12, weight: .semibold))
                    if !group.documented { AgentRiskTag(text: l10n.t("agents.badge.review"), high: true) }
                    Spacer()
                    if let footprint = state.agentStorageFootprints[group.id] {
                        AgentStorageSummaryView(storage: AgentStorageFootprint.totals([footprint]))
                    } else {
                        Text(l10n.tf("agents.storage.resource", ByteFormat.format(group.id == "shared-mcp"
                            ? AppState.uniqueAgentBytes(state.agentMCPInstallations.map { ($0.path, $0.bytes) })
                            : state.agentGroupBytes(group))))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(collapsed.contains(group.id) ? -90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(state.agentApplying)
            .accessibilityValue(l10n.t(collapsed.contains(group.id) ? "agents.collapsed" : "agents.expanded"))
            if group.orphaned {
                Button { state.offerAgentAssociatedDataCleanup(agentIDs: [group.id]) } label: {
                    Label(l10n.t("agents.program.residuals"), systemImage: "sparkles")
                }
                .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
                .disabled(state.isAgentTaskBusy || state.isUninstallMutationBlocked || state.uninstallQueue.activeJob != nil)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .modifier(ListRowSurface(emphasis: .header))
    }

    @ViewBuilder private func groupContents(_ group: AgentGroupSummary, resources: [AgentResourceCatalog.Skill]) -> some View {
        ForEach(state.agentApplications[group.id] ?? []) { app in
            HStack(spacing: 8) {
                Image(systemName: "app").foregroundStyle(Color.moleAccentText)
                VStack(alignment: .leading, spacing: 2) {
                    Text(l10n.tf("agents.program.desktop", app.name)).font(.system(size: 12, weight: .medium))
                    Text(abbreviate(app.path)).font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Text(l10n.tf("agents.program.body", app.size)).font(.system(size: 10)).foregroundStyle(.secondary)
                Button { state.uninstallAgentApplication(app) } label: {
                    Label(l10n.t("uninstall.action"), systemImage: "trash")
                }
                .buttonStyle(DangerButtonStyle()).controlSize(.small)
                .disabled(state.isAgentTaskBusy || state.isUninstallMutationBlocked || state.uninstallQueue.activeJob != nil)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .modifier(ListRowSurface())
        }
        let cliInstallations = state.agentCLIInstallations.filter { $0.agentID == group.id }
        if !cliInstallations.isEmpty {
            ForEach(cliInstallations) { installation in
                cliInstallationRow(installation)
            }
        }
        ForEach(group.categoryIDs, id: \.self) { id in
            if let category = state.agentCategories.first(where: { $0.id == id }) {
                CategoryRowView(category: categoryBinding(for: category),
                    selectionEnabled: !state.isAgentTaskBusy && !state.agentCLISelectedAgentIDs.contains(group.id),
                    highlightsSensitiveData: true, selectsOnRowClick: true)
            }
        }
        let skills = resources.filter { $0.bindings.contains { $0.agentIDs.contains(group.id) } }
        if !skills.isEmpty {
            subsectionHeader(l10n.t("agents.subsection.skills"), count: skills.count)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 135, maximum: 190), spacing: 8)], spacing: 8) {
                ForEach(skills) { skill in
                    let bindings = skill.bindings.filter { $0.agentIDs.contains(group.id) }
                    let removable = bindings.filter(\.removable)
                    AgentCompactResourceCard(title: skill.name,
                        subtitle: removable.isEmpty ? l10n.t("agents.manage.implicit") : l10n.t("agents.skills.unlink"),
                        symbol: "sparkles", selected: !removable.isEmpty && removable.allSatisfy(state.isAgentSkillBindingSelected),
                        enabled: !state.isAgentTaskBusy, action: {
                            if removable.isEmpty { onManageSkills() } else { state.toggleAgentSkillBindings(removable) }
                        }).help(skill.id)
                }
            }
        }
        let servers = state.agentServers.filter { $0.agentID == group.id }
        if !servers.isEmpty {
            subsectionHeader(l10n.t("agents.subsection.mcp"), count: servers.count)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 135, maximum: 190), spacing: 8)], spacing: 8) {
                ForEach(servers) { server in
                    AgentCompactResourceCard(title: server.name, subtitle: l10n.t("agents.mcp.unlink"), symbol: "server.rack",
                        selected: state.isAgentServerSelected(server),
                        enabled: !state.isAgentTaskBusy && !server.issues.contains(.unreadableConfig),
                        action: { state.toggleAgentServer(server) }).help(server.endpoint)
                }
            }
        }
    }

    private func categoryBinding(for snapshot: CleanupCategory) -> Binding<CleanupCategory> {
        Binding(get: {
            let category = state.agentCategories.first(where: { $0.id == snapshot.id }) ?? snapshot
            return state.isAgentCategoryIncludedByCLI(category)
                ? category.selectingPaths(category.paths) : category
        }, set: { update in
            guard let index = state.agentCategories.firstIndex(where: { $0.id == snapshot.id }) else { return }
            var category = state.agentCategories[index]
            let includedByCLI = state.isAgentCategoryIncludedByCLI(category)
            // Expanding an implicitly selected row must not turn its derived
            // checkmarks into explicit data selections when the CLI is undone.
            if !includedByCLI && !state.isAgentTaskBusy {
                category = category.selectingPaths(update.selectedPaths)
            }
            category.expanded = update.expanded
            state.agentCategories[index] = category
        })
    }

    private func cliInstallationRow(_ installation: AgentCLIInstallation) -> some View {
        let expanded = expandedCLIInstallations.contains(installation.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button { state.uninstallAgentCLI(installation) } label: {
                    Label(l10n.t("uninstall.action"), systemImage: "trash")
                }
                .buttonStyle(DangerButtonStyle()).controlSize(.small)
                .disabled(state.isAgentTaskBusy || state.isUninstallMutationBlocked || state.uninstallQueue.activeJob != nil)
                .accessibilityLabel(l10n.tf("agents.cli.select", installation.name))
                Button {
                    withAnimation(reduceMotion ? nil : MoleMotion.panel) {
                        if expanded { expandedCLIInstallations.remove(installation.id) }
                        else { expandedCLIInstallations.insert(installation.id) }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "terminal").foregroundStyle(Color.moleAccentText)
                        Text(l10n.t("agents.cli.installation"))
                            .font(.system(size: 12, weight: .medium))
                        Text(installation.manager.rawValue)
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        if let size = state.agentCLIBodySizes[installation.id] {
                            Text(l10n.tf("agents.program.body", size.complete ? ByteFormat.format(size.bytes) : "—"))
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(MolePlainButtonStyle())
                .accessibilityValue(l10n.t(expanded ? "agents.expanded" : "agents.collapsed"))
            }
            Text(abbreviate(installation.managedPaths.first ?? installation.executablePaths.first ?? ""))
                .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            if expanded {
                Text(installation.detail)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 25)
                ForEach(installation.managedPaths, id: \.self) { path in
                    Text(abbreviate(path))
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).help(path)
                        .padding(.leading, 25)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .modifier(ListRowSurface())
    }

    private func subsectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold))
            Text("\(count)").font(.system(size: 10).monospacedDigit())
            Spacer()
        }
        .foregroundStyle(.secondary).padding(.horizontal, 4).padding(.top, 2)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if state.isAgentTaskBusy {
                NoriStatusAnimation(mood: .working, size: 32)
                Text(state.agentApplying ? state.agentStatus : l10n.t("agents.apply.working"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityAddTraits(.updatesFrequently)
            } else {
                Button { state.requestScanAccess(.aiScan) } label: {
                    Label(l10n.t("agents.rescan"), systemImage: "arrow.clockwise")
                }
                    .buttonStyle(SecondaryButtonStyle()).disabled(state.isAgentTaskBusy)
                if state.agentCleanupHasFeedback && state.agentOutcomeMood == .success {
                    Text(state.agentStatus).font(.system(size: 11)).foregroundStyle(Color.success).lineLimit(1)
                }
                if state.agentRetryAvailable {
                    Button(action: state.retryFailedAgentCleanup) {
                        Label(l10n.t("cleanup.task.retry"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(SecondaryButtonStyle()).disabled(state.isAgentTaskBusy)
                }
            }
            Spacer()
            let unbindings = state.selectedAgentUnbindings
            if unbindings.count > 0 {
                Button { state.requestAgentResourceChanges(unbindings) } label: {
                    Text(l10n.t("agents.manage.unlink") + " (\(unbindings.count))")
                }.buttonStyle(PrimaryButtonStyle()).disabled(state.isAgentTaskBusy)
            }
            Button { state.applyAgentCleanup() } label: {
                Label(state.agentApplying ? l10n.t("agents.apply.working") : (state.agentSelectedCount > 0
                      ? l10n.tf("agents.apply.withCount", state.agentSelectedCount, ByteFormat.format(state.agentSelectedBytes))
                      : l10n.t("agents.manage.cleanData")), systemImage: "sparkles")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(state.agentSelectedCount == 0 || state.isAgentTaskBusy
                || state.isUninstallMutationBlocked || state.uninstallQueue.activeJob != nil)
            .help(l10n.t("agents.storage.selectedImpact"))
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
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
