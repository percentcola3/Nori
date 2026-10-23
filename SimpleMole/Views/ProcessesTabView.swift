import SwiftUI

/// 进程管理：默认应用级视图（libproc 采样、按 .app 聚合、搜索 / 排序 / 趋势），
/// 高级模式独立展示每个 PID，异常自动处理由用户显式启用。
struct ProcessesTabView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded: Set<String> = []
    @State private var childLimits: [String: Int] = [:]

    private var searchQuery: String {
        state.processSearch.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 6)

            HStack(spacing: 6) {
                // 数量统计已移除：仅在存在有意义的状态（操作反馈/加载/异常）时展示。
                if !state.processActionStatus.isEmpty {
                    Text(state.processActionStatus)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if !state.processStatus.isEmpty {
                    Text(state.processStatus)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            if !state.advancedProcesses, !state.processAlerts.isEmpty {
                alertBanner
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            if state.advancedProcesses {
                advancedList
            } else {
                groupedList
            }
        }
    }

    // MARK: 工具条

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    TextField(l10n.t("proc.search.placeholder"), text: $state.processSearch)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                    if !state.processSearch.isEmpty {
                        Button {
                            state.processSearch = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.surface2))
                .frame(maxWidth: 260)

                MoleMenuPicker(title: l10n.t("proc.sort"),
                               value: l10n.t(state.processSort.l10nKey),
                               selection: $state.processSort) {
                    ForEach(ProcessSort.allCases, id: \.self) { sort in
                        Text(l10n.t(sort.l10nKey)).tag(sort)
                    }
                }
                .labelsHidden()
                .frame(width: 112)
                Spacer()
                Toggle(l10n.t("proc.advanced"), isOn: $state.advancedProcesses)
                    .toggleStyle(MoleSwitchToggleStyle())
                    .controlSize(.small)
                    .font(.system(size: 11))
            }
            if state.advancedProcesses {
                Toggle(l10n.t("proc.autoCleanup"), isOn: $state.automaticProcessCleanup)
                    .toggleStyle(MoleSwitchToggleStyle())
                    .controlSize(.small)
                    .font(.system(size: 11))
            }
        }
    }

    // MARK: 高占用提示

    private var alertBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(state.processAlerts.prefix(3)) { alert in
                HStack(spacing: 8) {
                    Image(systemName: alert.reason == .cpu ? "flame.fill" : "memorychip.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.warning)
                    Text(l10n.tf(alert.reason == .cpu ? "proc.alert.cpu" : "proc.alert.mem", alert.name))
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                    Spacer()
                    if let group = state.processGroups.first(where: { $0.id == alert.pid }) {
                        quitButton(group.app)
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.warning.opacity(0.10)))
    }

    // MARK: 应用分组列表

    @ViewBuilder
    private var groupedList: some View {
        let groups = state.visibleProcessGroups
        if groups.isEmpty {
            EmptyStateView(symbol: "cpu",
                           title: searchQuery.isEmpty
                             ? l10n.t("proc.status.none") : l10n.t("proc.search.empty"),
                           subtitle: searchQuery.isEmpty ? l10n.t("proc.status.systemHint") : nil)
        } else {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(groups, id: \.app.signalToken) { group in
                        groupCard(group)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
        }
    }

    private func groupCard(_ group: ProcessGroup) -> some View {
        let token = group.app.signalToken
        let matchingChildren = searchQuery.isEmpty ? [] : group.children.filter { $0.matchesProcessQuery(searchQuery) }
        let filtersChildren = !searchQuery.isEmpty
        let children = filtersChildren ? matchingChildren : group.children
        let childLimit = filtersChildren ? children.count : childLimits[token, default: 30]
        let isExpanded = filtersChildren ? !children.isEmpty : expanded.contains(token)
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    if isExpanded { expanded.remove(token) } else { expanded.insert(token) }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(children.isEmpty ? Color.clear : Color.textSecondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 14, height: 26)
                }
                .buttonStyle(.plain)
                .disabled(children.isEmpty || filtersChildren)

                ProcessAppIcon(row: group.app,
                               size: 26,
                               fallbackSystemName: "app.fill",
                               fallbackTint: Color.moleAccentText,
                               validatesNativeStartIdentity: true,
                               bundlePath: group.bundlePath)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(group.app.name)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if !group.children.isEmpty {
                            Text(l10n.tf("proc.children", group.children.count))
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .frame(height: 17)
                                .background(Capsule().fill(Color.surface3))
                        }
                        if group.isBackgroundOnly {
                            Text(l10n.t("proc.background"))
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(Color.warning)
                        }
                        if group.app.lifecycle != .normal {
                            ProcessLifecycleBadge(lifecycle: group.app.lifecycle)
                        }
                    }
                    Text(group.app.detail)
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                    if let feedback = state.processQuitFeedback[group.app.signalToken], feedback == .waiting {
                        Text(l10n.t(feedbackKey(feedback)))
                            .font(.system(size: 10))
                            .foregroundStyle(feedback == .waiting ? Color.accentText : Color.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                ProcessSparkline(values: state.processCPUHistory(group.id),
                                 tint: group.totalCPU >= 50 ? Color.warning : Color.accent)
                    .frame(width: 64, height: 20)
                ProcessMetric(label: "CPU",
                              value: String(format: "%.1f%%", group.totalCPU),
                              isElevated: group.totalCPU >= 50)
                ProcessMetric(label: l10n.t("proc.memory"),
                              value: group.totalBytes > 0 ? ByteFormat.short(group.totalBytes) : "--",
                              isElevated: group.app.mem >= 20)
                quitButton(group.app)
                Menu {
                    Button(l10n.t("proc.endGroup"), role: .destructive) { state.endProcessGroup(group) }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 24)
                .disabled(state.processQuitFeedback[group.app.signalToken] == .waiting)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            if isExpanded, !children.isEmpty {
                Divider().padding(.horizontal, 10)
                VStack(spacing: 0) {
                    ForEach(children.prefix(childLimit), id: \.signalToken) { child in
                        childRow(child)
                    }
                    if children.count > childLimit {
                        Button(l10n.tf("proc.children.more", min(30, children.count - childLimit))) {
                            childLimits[token] = childLimit + 30
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.accentText)
                        .padding(.vertical, 6)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .clipped()
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.surface2))
        .animation(reduceMotion ? nil : MoleMotion.panel, value: isExpanded)
    }

    private func feedbackKey(_ feedback: AppState.ProcessQuitFeedback) -> String {
        switch feedback {
        case .waiting: return "proc.quit.waiting"
        case .refused: return "proc.quit.refused"
        case .stillRunning: return "proc.quit.stillRunning"
        case .stale: return "proc.refusal.identity"
        }
    }

    private func quitButton(_ row: ProcessRow) -> some View {
        let feedback = state.processQuitFeedback[row.signalToken]
        let waiting = feedback == .waiting
        let needsForce = feedback == .refused || feedback == .stillRunning
        return Button {
            if needsForce { state.terminateProcess(row) }
            else { state.quitApplication(row) }
        } label: {
            HStack(spacing: 5) {
                if waiting { ProgressView().controlSize(.mini) }
                Text(l10n.t(waiting ? "proc.quit.pending" : (needsForce ? "proc.forceQuit" : "proc.quit")))
            }
        }
        .buttonStyle(SecondaryButtonStyle(tint: needsForce ? .danger : .accentText))
        .disabled(waiting)
        .help(l10n.t("proc.exit.help"))
    }

    private func childRow(_ child: ProcessRow) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(child.name)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if child.lifecycle != .normal {
                        ProcessLifecycleBadge(lifecycle: child.lifecycle)
                    }
                }
                Text(child.detail)
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.tertiary)
                locationDetails(child)
            }
            Spacer()
            ProcessMetric(label: "CPU", value: String(format: "%.1f%%", child.cpu), isElevated: child.cpu >= 50)
            ProcessMetric(label: l10n.t("proc.memory"),
                          value: child.memBytes > 0 ? ByteFormat.short(child.memBytes) : "--",
                          isElevated: child.mem >= 20)
            Button(l10n.t("proc.kill")) { state.terminateChildProcess(child) }
                .buttonStyle(DangerButtonStyle())
        }
        .padding(.leading, 34)
        .padding(.trailing, 10)
        .padding(.vertical, 5)
    }

    // MARK: 高级模式（独立 PID）

    @ViewBuilder
    private var advancedList: some View {
        let rows = state.visiblePIDRows
        if rows.isEmpty {
            EmptyStateView(symbol: "cpu",
                           title: searchQuery.isEmpty ? state.processStatus : l10n.t("proc.search.empty"),
                           subtitle: nil)
        } else {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(rows, id: \.signalToken) { row in
                        advancedRow(row)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
        }
    }

    private func advancedRow(_ row: ProcessRow) -> some View {
        HStack(spacing: 8) {
            if row.bundlePath != nil {
                ProcessAppIcon(row: row,
                               size: 26,
                               fallbackSystemName: "app.fill",
                               fallbackTint: Color.moleAccentText,
                               validatesNativeStartIdentity: true,
                               bundlePath: row.bundlePath)
            } else {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if row.lifecycle != .normal {
                        ProcessLifecycleBadge(lifecycle: row.lifecycle)
                    }
                }
                Text(row.detail)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                locationDetails(row)
            }
            Spacer()
            ProcessMetric(label: "CPU",
                          value: String(format: "%.1f%%", row.cpu),
                          isElevated: row.cpu >= 50)
            ProcessMetric(label: l10n.t("proc.memory"),
                          value: row.memBytes > 0 ? ByteFormat.short(row.memBytes) : "--",
                          isElevated: row.mem >= 20)
            Button(row.lifecycle == .normal
                   ? l10n.t("proc.kill")
                   : l10n.t("proc.cleanupStale")) {
                state.terminateProcess(row)
            }
            .buttonStyle(DangerButtonStyle())
            .disabled(state.runtimeInFlight || !state.canControlPIDRow(row))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.surface2))
    }

    @ViewBuilder
    private func locationDetails(_ row: ProcessRow) -> some View {
        if let path = row.executablePath, !path.isEmpty {
            Text(path)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(path)
        }
        if let directory = row.workingDirectory, !directory.isEmpty {
            Text(l10n.tf("proc.directory", directory))
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(directory)
        }
    }
}

/// 迷你趋势线：最近 N 次采样的 CPU 占用（Components.Sparkline 是通用版）。
struct ProcessSparkline: View {
    let values: [Double]
    var tint: Color = .accent

    var body: some View {
        Canvas { context, size in
            guard values.count >= 2 else { return }
            let peak = max(10, values.max() ?? 0)
            let step = size.width / CGFloat(values.count - 1)
            var path = Path()
            for (index, value) in values.enumerated() {
                let point = CGPoint(x: CGFloat(index) * step,
                                    y: size.height - CGFloat(min(1, value / peak)) * (size.height - 2) - 1)
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            context.stroke(path, with: .color(tint),
                           style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            var fill = path
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()
            context.fill(fill, with: .color(tint.opacity(0.14)))
        }
        .accessibilityHidden(true)
    }
}

private struct ProcessLifecycleBadge: View {
    let lifecycle: ProcessLifecycle
    @ObservedObject private var l10n = L10n.shared

    private var label: String {
        switch lifecycle {
        case .zombie: return l10n.t("proc.badge.zombie")
        case .exiting: return l10n.t("proc.badge.exiting")
        case .normal: return ""
        }
    }

    private var tint: Color {
        switch lifecycle {
        case .zombie: return Color.danger
        case .exiting: return Color.warning
        case .normal: return .secondary
        }
    }

    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .frame(height: 17)
            .background(Capsule().fill(tint.opacity(0.12)))
            .fixedSize()
    }
}

private struct ProcessMetric: View {
    let label: String
    let value: String
    let isElevated: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(label)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(isElevated ? Color.warning : Color.textSecondary)
                .lineLimit(1)
        }
        .frame(width: 62, alignment: .trailing)
    }
}

/// 端口清理：lsof 监听列表 + 关闭对应进程。
struct PortsTabView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        VStack(spacing: 0) {
            if state.portRows.isEmpty {
                if state.runtimeInFlight {
                    NoriScanActivity(text: l10n.t("ports.status.reading"), quiet: true)
                } else {
                    EmptyStateView(symbol: "network", title: l10n.t("ports.status.none"), subtitle: nil)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(state.portRows) { row in
                            HStack(spacing: 8) {
                                Image(systemName: "dot.radiowaves.left.and.right")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.moleAccentText)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(l10n.tf("ports.row", row.port, row.command))
                                        .font(.system(size: 12, weight: .medium))
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    Text("\(row.endpoint) · PID \(row.pid)")
                                        .font(.system(size: 10).monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                                Button(l10n.t("ports.close")) { state.closePort(row) }
                                    .buttonStyle(DangerButtonStyle())
                                    .disabled(state.confirmation != nil)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 9).fill(Color.surface2))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 4)
                }
                HStack(spacing: 8) {
                    if state.runtimeInFlight {
                        NoriStatusAnimation(mood: .working, size: 28, assetName: "nori-working")
                    }
                    Text(state.portStatus)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                }
                .frame(height: 32)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
    }
}
