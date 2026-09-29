import AppKit
import SwiftUI

/// Agent 专清：按工具分组呈现可清理空间、Skills 与 MCP 配置体检。
/// 与磁盘清理完全独立；勾选项直接永久删除，MCP 配置只读。
struct AgentsTabView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var section = 0
    @State private var collapsed: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            if state.agentScanning || state.agentApplying {
                VStack(spacing: 12) {
                    NoriStatusAnimation(mood: .working, size: 96)
                    Text(state.agentStatus).font(.system(size: 12))
                    ProgressView().controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !state.agentHasScanned {
                emptyState
            } else {
                statusRow
                PillPicker(items: [l10n.t("agents.section.space"),
                                   l10n.tf("agents.section.skills", state.agentSkills.count),
                                   l10n.tf("agents.section.mcp", state.agentServers.count)],
                           selection: $section)
                    .padding(.bottom, 6)
                switch section {
                case 1: skillsList
                case 2: mcpList
                default: spaceList
                }
                if section != 2 {
                    Divider()
                    actions
                }
            }
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(l10n.t("agents.title"))
                    .font(.system(size: 13, weight: .semibold))
                Text(l10n.t("agents.subtitle"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button { state.requestScanAccess(.aiScan) } label: {
                Label(state.agentHasScanned ? l10n.t("agents.rescan") : l10n.t("agents.scan"),
                      systemImage: "sparkle.magnifyingglass")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(state.isBusy)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            NoriStatusAnimation(mood: .idle, size: 76)
            Text(l10n.t("agents.empty.hint"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            if let mood = state.agentOutcomeMood {
                NoriStatusAnimation(mood: mood, size: 44)
            }
            Text(state.agentStatus)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if !state.agentScanComplete {
                Label(l10n.t("agents.status.partial"), systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.warning)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    // MARK: 空间

    private var spaceList: some View {
        Group {
            if state.agentGroups.isEmpty {
                Text(l10n.t("agents.status.empty"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(state.agentGroups) { group in
                            VStack(spacing: 8) {
                                groupHeader(group)
                                if !collapsed.contains(group.id) {
                                    LazyVStack(spacing: 8) {
                                        ForEach(group.categoryIDs, id: \.self) { id in
                                            if let index = state.agentCategories.firstIndex(where: { $0.id == id }) {
                                                CategoryRowView(category: $state.agentCategories[index],
                                                                selectionEnabled: !state.isBusy)
                                            }
                                        }
                                    }
                                    .padding(.leading, 14)
                                    .transition(.molePanelReveal)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func groupHeader(_ group: AgentGroupSummary) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : MoleMotion.panel) {
                if collapsed.contains(group.id) { collapsed.remove(group.id) } else { collapsed.insert(group.id) }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "brain")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.moleAccentText)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.accent.opacity(0.14)))
                Text(group.name)
                    .font(.system(size: 12, weight: .semibold))
                if !group.documented {
                    Text(l10n.t("agents.badge.showOnly"))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.surface3))
                }
                Spacer(minLength: 8)
                Text(reclaimableText(group))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(ByteFormat.format(group.bytes))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color.moleAccentText)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(collapsed.contains(group.id) ? -90 : 0))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.surface2))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.surface2))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.hairline, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(MolePlainButtonStyle(pressedScale: 0.995))
    }

    private func reclaimableText(_ group: AgentGroupSummary) -> String {
        let categories = state.agentCategories.filter { group.categoryIDs.contains($0.id) }
        let reclaimable = categories.filter(\.canSelect).reduce(UInt64(0)) { $0 &+ $1.bytes }
        return l10n.tf("agents.group.reclaimable", ByteFormat.format(reclaimable))
    }

    // MARK: Skills

    private var skillsList: some View {
        let directories = Dictionary(grouping: state.agentSkills, by: \.directory)
        let order = state.agentSkills.map(\.directory).reduce(into: [String]()) {
            if !$0.contains($1) { $0.append($1) }
        }
        return Group {
            if state.agentSkills.isEmpty {
                Text(l10n.t("agents.skills.empty"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        Label(l10n.t("agents.skills.hint"), systemImage: "info.circle")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        ForEach(order, id: \.self) { directory in
                            let skills = directories[directory] ?? []
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) {
                                    Text(abbreviate(directory))
                                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    Text(skills.first?.usedBy.isEmpty == false
                                         ? skills.first!.usedBy.joined(separator: " · ")
                                         : l10n.t("agents.skills.shared"))
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text("\(skills.count)")
                                        .font(.system(size: 10).monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                ForEach(skills) { skill in skillRow(skill) }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func skillRow(_ skill: AgentSkill) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: Binding(
                get: { state.agentSelectedSkills.contains(skill.path) },
                set: { _ in state.toggleAgentSkill(skill) }))
                .toggleStyle(.checkbox)
                .controlSize(.mini)
                .labelsHidden()
                .fixedSize()
                .disabled(skill.linked || skill.identity.isEmpty || state.isBusy)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(skill.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    if skill.linked {
                        Text(l10n.t("agents.skills.linked"))
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.surface3))
                    }
                }
                if !skill.summary.isEmpty {
                    Text(skill.summary)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let target = skill.linkTarget {
                    Text("→ " + abbreviate(target))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if skill.bytes > 0 {
                SizeBadge(text: ByteFormat.format(skill.bytes),
                          prominent: state.agentSelectedSkills.contains(skill.path))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9).fill(
            state.agentSelectedSkills.contains(skill.path)
                ? Color.moleAccent.opacity(0.085) : Color.surface2))
    }

    // MARK: MCP

    private var mcpList: some View {
        let byAgent = Dictionary(grouping: state.agentServers, by: \.agentName)
        let order = state.agentServers.map(\.agentName).reduce(into: [String]()) {
            if !$0.contains($1) { $0.append($1) }
        }
        let issues = state.agentServers.reduce(0) { $0 + $1.issues.count }
        return Group {
            if state.agentServers.isEmpty {
                Text(l10n.t("agents.mcp.empty"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        Label(issues > 0 ? l10n.tf("agents.mcp.issueCount", issues) : l10n.t("agents.mcp.healthy"),
                              systemImage: issues > 0 ? "exclamationmark.triangle.fill" : "checkmark.shield.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(issues > 0 ? Color.warning : Color.success)
                        Label(l10n.t("agents.mcp.readOnly"), systemImage: "lock.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        ForEach(order, id: \.self) { agent in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(agent).font(.system(size: 11, weight: .semibold))
                                ForEach(byAgent[agent] ?? []) { server in serverRow(server) }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func serverRow(_ server: AgentMCPServer) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: server.remote ? "globe" : "terminal")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(server.name).font(.system(size: 12, weight: .medium))
                if server.disabled {
                    Text(l10n.t("agents.mcp.disabled"))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.surface3))
                }
                if let scope = server.scope {
                    Text(abbreviate(scope))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: server.configPath)])
                } label: {
                    Image(systemName: "folder").font(.system(size: 10))
                }
                .buttonStyle(MoleIconButtonStyle(size: 20))
                .help(abbreviate(server.configPath))
            }
            if !server.endpoint.isEmpty {
                Text(server.endpoint)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            ForEach(Array(server.issues.enumerated()), id: \.offset) { _, issue in
                Label(issueText(issue), systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.warning)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.surface2))
    }

    private func issueText(_ issue: AgentMCPServer.Issue) -> String {
        switch issue {
        case .commandMissing(let command): return l10n.tf("agents.mcp.issue.command", command)
        case .plaintextSecret(let key, let masked): return l10n.tf("agents.mcp.issue.secret", key, masked)
        case .unreadableConfig: return l10n.t("agents.mcp.issue.unreadable")
        }
    }

    // MARK: 底部操作

    private var actions: some View {
        HStack(spacing: 8) {
            Button { state.selectSafeAgentItems() } label: {
                Label(l10n.t("agents.selectSafe"), systemImage: "checkmark.shield")
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(state.isBusy)
            Button { state.clearAgentSelection() } label: {
                Label(l10n.t("common.deselectAll"), systemImage: "minus.circle")
            }
            .buttonStyle(SecondaryButtonStyle())
            .labelStyle(.iconOnly)
            .help(l10n.t("common.deselectAll"))
            .disabled(state.isBusy)
            Spacer()
            Button { state.applyAgentCleanup() } label: {
                Label(state.agentSelectedCount > 0
                      ? l10n.tf("agents.apply.withCount", state.agentSelectedCount,
                                ByteFormat.format(state.agentSelectedBytes))
                      : l10n.t("agents.apply"),
                      systemImage: "trash.fill")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(state.agentSelectedCount == 0 || state.isBusy)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
