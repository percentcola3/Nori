import AppKit
import SwiftUI

/// 手动扫描后统一展示 Agent、全局 Skill 与 MCP 类目；关联项只解除关联。
struct AgentsTabView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var collapsed: Set<String> = []
    @State private var expandedCLIInstallations: Set<String> = []

    private var presentationPhase: Int {
        if state.agentApplying { return 3 }
        if state.agentCelebrating { return 4 }
        if state.agentCleanupHasFeedback && state.agentOutcomeMood == .success { return 6 }
        if showsCleanupFailure { return 5 }
        if state.agentScanning { return 1 }
        return state.agentHasScanned ? 2 : 0
    }

    private var showsCleanupFailure: Bool {
        state.agentCleanupHasFeedback && state.agentOutcomeMood == .attention
    }

    var body: some View {
        NoriPageTransition(phase: presentationPhase) {
            VStack(spacing: 0) {
                if state.agentApplying {
                    NoriCleanupTaskStage(phase: .working,
                        progress: state.agentCleanupProgress, statusText: state.agentStatus,
                        feedbackID: state.agentFeedbackID)
                } else if state.agentCelebrating {
                    cleanupSuccess
                } else if state.agentCleanupHasFeedback && state.agentOutcomeMood == .success {
                    NoriPlaceholderStage { size in
                        NoriIdlePlaceholder(state: state, size: size)
                        scanButton
                    }
                } else if showsCleanupFailure {
                    cleanupFailure
                } else if state.agentScanning {
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
                    if !state.agentApplying && (state.agentOutcomeMood == .attention || !state.agentScanComplete) {
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

    private var cleanupSuccess: some View {
        let feedbackID = state.agentFeedbackID
        return NoriCleanupTaskStage(phase: .success,
            completedCount: state.agentCompletedCount, reclaimedBytes: state.agentReclaimedBytes,
            feedbackID: state.agentFeedbackID)
            .task(id: feedbackID) {
                do { try await Task.sleep(nanoseconds: UInt64(NoriMotion.successFeedbackDuration * 1_000_000_000)) }
                catch { return }
                state.finishAgentCelebration(feedbackID: feedbackID)
            }
    }

    private var cleanupFailure: some View {
        return NoriCleanupTaskStage(phase: .attention,
            statusText: state.agentStatus,
            details: TaskFeedbackDiagnostic.localized(state.agentOutcomeDetails),
            applications: state.agentFailureApplications,
            completedCount: state.agentCompletedCount, feedbackID: state.agentFeedbackID,
            scanSource: .agents, scanDisabled: state.isAgentTaskBusy,
            onScan: { state.requestScanAccess(.aiScan) })
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
        ScrollView {
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

    @ViewBuilder private func groupContents(_ group: AgentGroupSummary) -> some View {
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

    private func skillRow(_ skill: AgentSkill) -> some View {
        let selected = state.isAgentSkillSelected(skill)
        return HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: Binding(get: { selected }, set: { _ in state.toggleAgentSkill(skill) }))
                .toggleStyle(.checkbox).controlSize(.mini).labelsHidden().fixedSize()
                .disabled(skill.identity.isEmpty || state.isAgentTaskBusy || state.agentCLISelectedAgentIDs.contains(skill.agentID))
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
        .modifier(ListRowSurface(selected: selected))
    }

    private func serverRow(_ server: AgentMCPServer) -> some View {
        let selected = state.isAgentServerSelected(server)
        let unreadable = server.issues.contains(.unreadableConfig)
        let issues = server.issues.reduce(into: [AgentMCPServer.Issue]()) { result, issue in
            if !result.contains(issue) { result.append(issue) }
        }
        return HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: Binding(get: { selected }, set: { _ in state.toggleAgentServer(server) }))
                .toggleStyle(.checkbox).controlSize(.mini).labelsHidden().fixedSize()
                .disabled(state.isAgentTaskBusy || state.agentCLISelectedAgentIDs.contains(server.agentID))
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
        .modifier(ListRowSurface(selected: selected))
    }

    private func installationRow(_ installation: AgentMCPInstallation) -> some View {
        let selected = state.agentSelectedMCPInstallations.contains(installation.id)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(get: { selected }, set: { _ in state.toggleAgentMCPInstallation(installation) }))
                    .toggleStyle(.checkbox).controlSize(.mini).labelsHidden().fixedSize()
                    .disabled(state.isAgentTaskBusy || installation.identity.isEmpty)
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
        .modifier(ListRowSurface(selected: selected))
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
            if state.agentApplying {
                ProgressView().controlSize(.small)
                Text(state.agentStatus)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.updatesFrequently)
            } else {
                Button { state.requestScanAccess(.aiScan) } label: {
                    Label(l10n.t("agents.rescan"), systemImage: "arrow.clockwise")
                }
                    .buttonStyle(SecondaryButtonStyle()).disabled(state.isAgentTaskBusy)
            }
            Spacer()
            Button { state.applyAgentCleanup() } label: {
                Label(state.agentApplying ? l10n.t("agents.apply.working") : (state.agentSelectedCount > 0
                      ? l10n.tf("agents.apply.withCount", state.agentSelectedCount, ByteFormat.format(state.agentSelectedBytes))
                      : l10n.t("agents.apply")), systemImage: "sparkles")
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
