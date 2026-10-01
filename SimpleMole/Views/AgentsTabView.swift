import AppKit
import SwiftUI

/// Agent 专清：每个 Agent 一个分组，空间类目、Skills 与 MCP 服务器都挂在其下。
/// 与磁盘清理完全独立；勾选项直接永久删除，MCP 改写前自动备份配置。
struct AgentsTabView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var collapsed: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            if state.agentScanning || state.agentApplying {
                header
                NoriScanActivity(text: state.agentStatus, quiet: true)
                .transition(reduceMotion ? .opacity : .moleStateSwap)
            } else if !state.agentHasScanned {
                header
                emptyState
                .transition(reduceMotion ? .opacity : .moleStateSwap)
            } else {
                if showsAgentNotice { statusRow }
                header
                agentList
                Divider()
                actions
            }
        }
        // 扫描中 → 结果/空态的整块互换走弹簧过渡。
        .animation(reduceMotion ? nil : MoleMotion.panel, value: state.agentScanning)
        .animation(reduceMotion ? nil : MoleMotion.panel, value: state.agentApplying)
        .animation(reduceMotion ? nil : MoleMotion.panel, value: state.agentHasScanned)
    }

    // MARK: 头部

    private var scanButton: some View {
        Button { state.requestScanAccess(.aiScan) } label: {
            Label(state.agentHasScanned ? l10n.t("agents.rescan") : l10n.t("agents.scan"),
                  systemImage: "sparkle.magnifyingglass")
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(state.isBusy)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Spacer()
            scanButton
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            NoriStatusAnimation(mood: .idle, size: 120, assetName: "nori-coffee")
            Text(l10n.t("agents.empty.hint"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 成功之后直接进入结果列表。只有失败或未完成扫描才留一条说明。
    private var showsAgentNotice: Bool {
        state.agentOutcomeMood == .attention || !state.agentScanComplete
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            if state.agentOutcomeMood == .attention {
                NoriStatusAnimation(mood: .attention, size: 44)
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

    // MARK: 统一分组列表

    private var agentList: some View {
        Group {
            if state.agentGroups.isEmpty {
                Text(l10n.t("agents.status.empty"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        Label(l10n.t("agents.mcp.editable"), systemImage: "lock.open")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
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
                                        let groupSkills = skills(in: group)
                                        if !groupSkills.isEmpty {
                                            subsectionHeader(l10n.t("agents.subsection.skills"),
                                                             count: groupSkills.count)
                                            ForEach(groupSkills) { skill in
                                                skillRow(skill)
                                            }
                                        }
                                        let groupServers = servers(in: group)
                                        if !groupServers.isEmpty {
                                            subsectionHeader(l10n.t("agents.subsection.mcp"),
                                                             count: groupServers.count)
                                            ForEach(groupServers) { server in
                                                serverRow(server)
                                            }
                                        }
                                    }
                                    .padding(.leading, 14)
                                    .transition(.molePanelReveal)
                                }
                            }
                            .clipped()
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func skills(in group: AgentGroupSummary) -> [AgentSkill] {
        state.agentSkills.filter { $0.agentID == group.id }
    }

    private func servers(in group: AgentGroupSummary) -> [AgentMCPServer] {
        state.agentServers.filter { $0.agentID == group.id }
    }

    /// 组内小节标题（Skills / MCP），与全局分区标题同一套样式。
    private func subsectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
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
                Text(group.id == "shared" ? l10n.t("agents.group.shared") : group.name)
                    .font(.system(size: 12, weight: .semibold))
                if !group.documented {
                    Text(l10n.t(group.orphaned ? "agents.badge.leftover" : "agents.badge.showOnly"))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(group.orphaned ? Color.warning : .secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(group.orphaned
                            ? Color.warning.opacity(0.12) : Color.surface3))
                }
                Spacer(minLength: 8)
                Text(reclaimableText(group))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(ByteFormat.format(groupTotalBytes(group)))
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

    /// 可回收 = 空间类目可选部分 + 本组未链接的 Skills；总占用再叠加 Skills 体积。
    private func reclaimableText(_ group: AgentGroupSummary) -> String {
        let categories = state.agentCategories.filter { group.categoryIDs.contains($0.id) }
        let reclaimable = categories.filter(\.canSelect).reduce(UInt64(0)) { $0 &+ $1.bytes }
            &+ skills(in: group).filter { !$0.linked && !$0.identity.isEmpty }
                .reduce(UInt64(0)) { $0 &+ $1.bytes }
        return l10n.tf("agents.group.reclaimable", ByteFormat.format(reclaimable))
    }

    private func groupTotalBytes(_ group: AgentGroupSummary) -> UInt64 {
        group.bytes &+ skills(in: group).reduce(UInt64(0)) { $0 &+ $1.bytes }
    }

    // MARK: Skills

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

    private func serverRow(_ server: AgentMCPServer) -> some View {
        let selected = state.agentSelectedServers.contains(server.id)
        let uneditable = server.issues.contains(.unreadableConfig)
        return HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: Binding(
                get: { selected },
                set: { _ in state.toggleAgentServer(server) }))
                .toggleStyle(.checkbox)
                .controlSize(.mini)
                .labelsHidden()
                .fixedSize()
                .disabled(uneditable || state.isBusy)
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9).fill(
            selected ? Color.moleAccent.opacity(0.085) : Color.surface2))
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
