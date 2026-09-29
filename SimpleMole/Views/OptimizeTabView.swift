import AppKit
import SwiftUI

/// 系统优化：先只读检查每项任务，再执行用户勾选的项，逐项显示结果。
struct OptimizeTabView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var l10n = L10n.shared
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(l10n.t("optimize.title"))
                        .font(.system(size: 13, weight: .semibold))
                    Text(l10n.t("optimize.subtitle"))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button {
                    state.requestScanAccess(.optimize)
                } label: {
                    Label(state.isOptimizing ? l10n.t("common.scanning")
                          : l10n.t(state.optimizeHasPreview ? "optimize.rerun" : "optimize.run"),
                          systemImage: "stethoscope")
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(state.isBusy)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            HStack(spacing: 6) {
                if let mood = operationMood {
                    NoriStatusAnimation(mood: mood, size: 76,
                                        assetName: state.isOptimizing ? "nori-typing" : nil)
                }
                Text(state.optimizeHasPreview || state.isOptimizing
                     ? state.optimizeStatus : l10n.t("optimize.empty.hint"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(sortedTasks) { task in
                        taskRow(task)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }

            if state.optimizeHasPreview {
                Divider()
                actions
            }
        }
    }

    /// 需要处理的排前面，其次需留意，再是无需处理/不可用；同档保持目录顺序。
    private var sortedTasks: [NativeCore.OptimizeTask] {
        guard state.optimizeHasPreview else { return state.optimizeTasks }
        func rank(_ task: NativeCore.OptimizeTask) -> Int {
            switch task.preview?.need {
            case .needed: return 0
            case .blocked: return 1
            case .clean: return 2
            default: return 3
            }
        }
        return state.optimizeTasks.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }

    private var operationMood: NoriMood? {
        if state.isOptimizing { return .working }
        let tasks = state.optimizeTasks
        guard tasks.contains(where: { $0.state != .pending }) else { return nil }
        if tasks.contains(where: { $0.state == .failed || $0.state == .unavailable }) {
            return .attention
        }
        return tasks.contains(where: { $0.state == .applied }) ? .success : .idle
    }

    private func taskRow(_ task: NativeCore.OptimizeTask) -> some View {
        let items = task.preview?.items ?? []
        let isExpanded = expanded.contains(task.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                if state.optimizeHasPreview {
                    Toggle("", isOn: Binding(
                        get: { task.selected },
                        set: { _ in state.toggleOptimizeTask(task.id) }))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .disabled(!task.selectable || state.isOptimizing)
                        .padding(.top, 2)
                }
                Image(systemName: icon(for: task.id))
                    .font(.system(size: 13))
                    .foregroundStyle(iconColor(task))
                    .frame(width: 20)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(localizedTitle(task))
                            .font(.system(size: 12, weight: .medium))
                        if task.kind == .admin { badge("optimize.badge.admin", systemImage: "lock.fill") }
                        if task.kind == .report { badge("optimize.badge.report", systemImage: "eye") }
                        if !task.defaultOn { badge("optimize.badge.history", systemImage: "clock.arrow.circlepath") }
                    }
                    Text(localizedDetail(task))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    if let preview = task.preview, task.state == .pending {
                        Text(preview.summary)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    if !task.message.isEmpty {
                        Text(task.message)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(statusLabel(task))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(statusColor(task))
                    if !items.isEmpty {
                        Button {
                            if isExpanded { expanded.remove(task.id) } else { expanded.insert(task.id) }
                        } label: {
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        }
                        .buttonStyle(MoleIconButtonStyle(size: 18))
                    }
                }
            }
            if isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(items.prefix(20).enumerated()), id: \.offset) { _, item in
                        Text(item)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if items.count > 20 {
                        Text("… +\(items.count - 20)")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.leading, state.optimizeHasPreview ? 56 : 30)
            }
            if task.id == "login-items", task.preview != nil {
                Button(l10n.t("optimize.openLoginItems")) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
                .padding(.leading, 56)
            }
            if task.id == "launch-agents", let plan = task.preview?.plan, !plan.isEmpty {
                Button(l10n.t("optimize.revealAgents")) {
                    NSWorkspace.shared.activateFileViewerSelecting(plan.map { URL(fileURLWithPath: $0) })
                }
                .buttonStyle(SecondaryButtonStyle())
                .padding(.leading, 56)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.surface1))
        .opacity(task.preview == nil || task.selectable || task.state != .pending
                 || task.preview?.need == .blocked ? 1 : 0.62)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button { state.selectRecommendedOptimize() } label: {
                Label(l10n.t("optimize.selectRecommended"), systemImage: "checkmark.shield")
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(state.isBusy)
            Button { state.clearOptimizeSelection() } label: {
                Label(l10n.t("optimize.clearSelection"), systemImage: "minus.circle")
            }
            .buttonStyle(SecondaryButtonStyle())
            .labelStyle(.iconOnly)
            .help(l10n.t("optimize.clearSelection"))
            .disabled(state.isBusy)
            Spacer()
            Button { state.applySelectedOptimize() } label: {
                Label(state.optimizeSelectedCount > 0
                      ? "\(l10n.t("optimize.runSelected")) (\(state.optimizeSelectedCount))"
                      : l10n.t("optimize.runSelected"),
                      systemImage: "wand.and.stars")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(state.optimizeSelectedCount == 0 || state.isBusy)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func badge(_ key: String, systemImage: String) -> some View {
        Label(l10n.t(key), systemImage: systemImage)
            .font(.system(size: 9, weight: .medium))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
            .foregroundStyle(.secondary)
    }

    private func localizedTitle(_ task: NativeCore.OptimizeTask) -> String {
        let key = "optimize.task.\(task.id).title"
        let value = l10n.t(key)
        return value == key ? task.title : value
    }

    private func localizedDetail(_ task: NativeCore.OptimizeTask) -> String {
        let key = "optimize.task.\(task.id).detail"
        let value = l10n.t(key)
        return value == key ? task.detail : value
    }

    private func statusLabel(_ task: NativeCore.OptimizeTask) -> String {
        if task.state == .pending, let need = task.preview?.need {
            return l10n.t("optimize.need.\(need.rawValue)")
        }
        let key = "optimize.state.\(task.state.rawValue)"
        let value = l10n.t(key)
        return value == key ? task.state.rawValue.capitalized : value
    }

    private func statusColor(_ task: NativeCore.OptimizeTask) -> Color {
        if task.state == .pending, let need = task.preview?.need {
            switch need {
            case .needed: return .moleAccentText
            case .blocked: return Color.warning
            case .clean, .unavailable: return .secondary
            }
        }
        switch task.state {
        case .applied: return Color.success
        case .failed: return Color.danger
        case .unavailable: return Color.warning
        case .unchanged: return .secondary
        case .pending: return .moleAccentText
        }
    }

    private func iconColor(_ task: NativeCore.OptimizeTask) -> Color {
        task.state == .pending && task.preview?.need == .clean ? .secondary : statusColor(task)
    }

    private func icon(for id: String) -> String {
        switch id {
        case "dns": return "network"
        case "quicklook": return "doc.richtext"
        case "iconservices": return "app.dashed"
        case "launchservices": return "square.grid.2x2"
        case "saved-state": return "clock.arrow.circlepath"
        case "broken-configs": return "wrench.and.screwdriver"
        case "shared-file-list": return "star.square.on.square"
        case "finder-dsstore": return "folder.badge.gearshape"
        case "legacy-overrides": return "slider.horizontal.3"
        case "network-stack": return "arrow.triangle.2.circlepath"
        case "sqlite-vacuum": return "cylinder.split.1x2"
        case "spotlight": return "magnifyingglass"
        case "spotlight-orphans": return "magnifyingglass.circle"
        case "periodic": return "calendar.badge.clock"
        case "disk-verify": return "externaldrive.badge.checkmark"
        case "quarantine": return "shield.lefthalf.filled"
        case "login-items": return "person.crop.circle.badge.checkmark"
        case "launch-agents": return "bolt.horizontal.circle"
        case "notifications": return "bell.badge"
        case "coreduet": return "chart.bar.xaxis"
        case "permissions": return "lock.shield"
        default: return "gearshape"
        }
    }
}
