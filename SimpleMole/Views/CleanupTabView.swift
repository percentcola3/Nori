import SwiftUI

/// 硬盘清理只呈现可确认、可直接删除的垃圾。
/// 需要判断的大文件、应用与受保护内容统一交给“磁盘分析”。
struct CleanupTabView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var l10n = L10n.shared
    /// nil 表示用户还没折叠/展开过：此时除最大分组外全部折叠，长列表首屏
    /// 先看到最重要的内容。一旦用户操作过就完全尊重用户的选择。
    @State private var userCollapsed: Set<CleanupGroupBucket>?
    /// 从可再生缓存行发起的自动清理规则创建。
    @State private var autoCleanIntent: AutoCleanupIntent?
    @State private var showsOutcomeDetails = false
    @State private var confirmingAppData = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var selectedAppData: [CleanupCategory] {
        state.categories.filter { $0.isAppDataReview && $0.selected }
    }

    private var collapsedGroups: Set<CleanupGroupBucket> {
        userCollapsed ?? defaultCollapsedGroups
    }

    private var defaultCollapsedGroups: Set<CleanupGroupBucket> {
        let groups = groupedCategories
        guard groups.count > 1 else { return [] }
        return Set(groups.dropFirst().map(\.kind))
    }

    private func toggleCollapsed(_ kind: CleanupGroupBucket) {
        withAnimation(reduceMotion ? nil : MoleMotion.panel) {
            var next = collapsedGroups
            if next.contains(kind) { next.remove(kind) } else { next.insert(kind) }
            userCollapsed = next
        }
    }

    /// 只有“可再生缓存”类目提供自动清理入口：Safe 风险 + 走永久删除路由
    /// 的缓存/日志项。需要确认的 Warning 项不进入自动化。
    private func autoCleanAction(for category: CleanupCategory) -> (() -> Void)? {
        guard category.risk == .safe,
              category.disposal == .permanentDelete,
              !category.paths.isEmpty else { return nil }
        return {
            autoCleanIntent = AutoCleanupIntent(paths: category.paths, cacheVerified: true,
                                               sourceName: L10nLocalizationAuditTables.categoryName(category.name, isAppLeftover: category.source == .appLeftover))
        }
    }

    /// 类目下已被自动清理规则管理的路径：类目行显示“已定时”徽标，
    /// 展开列表逐路径打标。
    private func coveredAutoCleanPaths(for category: CleanupCategory) -> Set<String> {
        Set(category.paths.filter {
            state.autoCleanupRuleCovering(directory: $0) != nil
        })
    }

    /// 系统数据库只展示体检确认有可执行维护任务的项目。
    private var hasAuxiliaryCleanupContent: Bool {
        !state.systemMaintenanceRows.isEmpty
            || state.isSystemMaintenanceRunning
    }

    private var hasAnyCleanupContent: Bool {
        !state.categories.isEmpty || hasAuxiliaryCleanupContent
    }

    private var showsCleanupResults: Bool {
        if state.cleanupCelebrating { return false }
        if state.cleanupOutcomeMood == .attention { return false }
        return hasAnyCleanupContent && state.cleanupOutcomeMood != .success
    }

    private var presentationPhase: Int {
        if state.isApplying || state.isCleanupScanning { return 1 }
        if state.cleanupOutcomeMood == .success { return state.cleanupCelebrating ? 3 : 5 }
        if state.cleanupOutcomeMood == .attention { return 4 }
        return showsCleanupResults ? 2 : 0
    }

    var body: some View {
        NoriPageTransition(phase: presentationPhase) {
        VStack(spacing: 0) {
            if showsCleanupResults && !state.isCleanupScanning && !state.isApplying && !state.cleanupDeferredPaths.isEmpty {
                Label(l10n.tf("cleanup.scan.deferred", state.cleanupDeferredPaths.count),
                      systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }

            if state.isApplying {
                NoriCleanupTaskStage(phase: .working,
                                     progress: state.cleanupTaskProgress,
                                     statusText: state.statusText)
            } else if state.isCleanupScanning {
                CleanupScanProgressView(state: state)
            } else if state.cleanupOutcomeMood == .success && !state.cleanupCelebrating {
                NoriPlaceholderStage { size in
                    NoriIdlePlaceholder(state: state, size: size)
                    scanButton
                }
            } else if state.cleanupOutcomeMood == .success {
                let feedbackID = state.cleanupFeedbackID
                NoriCleanupTaskStage(phase: .success,
                                     completedCount: state.cleanupCompletedCount,
                                     reclaimedBytes: state.cleanupReclaimedBytes,
                                     feedbackID: feedbackID)
                    // 约三秒后回闲置 SVG，并隐藏成功摘要。
                    .task(id: feedbackID) {
                        do {
                            try await Task.sleep(nanoseconds: UInt64(NoriMotion.successFeedbackDuration * 1_000_000_000))
                        } catch { return }
                        state.finishCleanupCelebration(feedbackID: feedbackID)
                    }
            } else if state.cleanupOutcomeMood == .attention {
                NoriCleanupTaskStage(phase: .attention,
                                     statusText: state.statusText,
                                     details: state.cleanupOutcomeDetails,
                                     applications: state.cleanupFailureApplications,
                                     feedbackID: state.cleanupFeedbackID,
                                     scanDisabled: state.isBusyExcludingUninstall || state.cleanupQueued,
                                     onScan: { state.requestScanAccess(.quickOptimize) })
            } else if !showsCleanupResults {
                NoriPlaceholderStage { size in
                    NoriIdlePlaceholder(state: state, size: size)
                    scanButton
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        cleanupOutcomeDetails
                        ForEach(groupedCategories) { group in
                            VStack(spacing: 8) {
                                cleanupGroupHeader(group)
                                if !collapsedGroups.contains(group.kind) {
                                    LazyVStack(spacing: 8) {
                                        ForEach(group.categoryIDs, id: \.self) { categoryID in
                                            if let index = state.categories.firstIndex(where: {
                                                $0.id == categoryID
                                            }) {
                                                CategoryRowView(
                                                    category: $state.categories[index],
                                                    selectionEnabled: state.cleanupScanComplete
                                                        && !state.isApplying,
                                                    coveredPaths: coveredAutoCleanPaths(
                                                        for: state.categories[index]),
                                                    onAutoClean: autoCleanAction(
                                                        for: state.categories[index]))
                                            }
                                        }
                                    }
                                    .padding(.leading, 14)
                                    .transition(.molePanelReveal)
                                }
                            }
                            .clipped()
                            .transition(.molePanelReveal)
                        }

                        systemMaintenanceSection
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                    // 扫描结果入场/移除的液态流动：按 id 变化触发，勾选操作不参与。
                    .animation(reduceMotion ? nil : MoleMotion.panel,
                               value: state.categories.map(\.id))
                }
            }

            if !state.isCleanupScanning && !state.isApplying && showsCleanupResults {
                Divider()
                cleanupActions
            }
        }
        }
        .sheet(item: $autoCleanIntent) { intent in
            AutoCleanupIntentSheet(state: state, intent: intent) {
                autoCleanIntent = nil
            }
        }
        // 扫描完成后体检系统数据库（原系统优化页分流能力，DR-11）。
        .onChange(of: state.cleanupScanComplete) { done in
            if done { state.scanSystemMaintenance() }
        }
        .onChange(of: state.cleanupFeedbackID) { _ in
            showsOutcomeDetails = false
        }
        // 扫描中 → 结果/空态 的整块互换走弹簧过渡，而不是硬切。
    }

    // MARK: 系统数据库维护

    @ViewBuilder
    private var systemMaintenanceSection: some View {
        if !state.isCleanupScanning, !state.systemMaintenanceRows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                systemMaintenanceHeader
                ForEach(state.systemMaintenanceRows) { row in
                    systemMaintenanceRow(row)
                }
            }
        }
    }

    private var scanButton: some View {
        Button {
            state.requestScanAccess(.quickOptimize)
        } label: {
            Label(l10n.t("cleanup.scan"), systemImage: "magnifyingglass")
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(state.isBusyExcludingUninstall || state.cleanupQueued)
    }

    // MARK: 系统数据库维护（原系统优化页分流）

    private var systemMaintenanceHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "internaldrive")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.moleAccentText)
            Text(l10n.t("sysmaint.title"))
                .font(.system(size: 12, weight: .semibold))
            if state.isSystemMaintenanceRunning {
                ProgressView().controlSize(.mini)
            }
            Spacer(minLength: 8)
        }
    }

    /// 维护行与类目行一致：整行点击勾选，统一“清理”时逐项执行。
    private func systemMaintenanceRow(_ row: SystemMaintenanceRow) -> some View {
        let isSelected = state.systemMaintenanceSelection.contains(row.id)
        return Button {
            state.toggleSystemMaintenance(row.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? Color.moleAccentText : Color.secondary)
                    .frame(width: 18)
                Image(systemName: "cylinder.split.1x2")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.moleAccentText)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(l10n.t(row.item.titleKey))
                        .font(.system(size: 12, weight: .medium))
                    Text(row.preview.summary)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(MolePlainButtonStyle())
        .modifier(ListRowSurface(selected: isSelected))
        .disabled(state.isBusy)
    }

    private var cleanupActions: some View {
        HStack(spacing: 8) {
            Button { state.startCleanupScan() } label: {
                Label(l10n.t("common.rescan"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(state.isBusyExcludingUninstall || state.cleanupQueued || state.isSystemMaintenanceRunning)
            // 全选/取消全选由各分组头的开关承担：底部只保留唯一的执行入口，
            // 系统维护项的勾选也由它统一分发。
            Spacer()
            Button {
                if selectedAppData.isEmpty { state.applyCleanup() } else { confirmingAppData = true }
            } label: {
                Label(applyLabel, systemImage: "trash.fill")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!state.hasCleanupSelection || state.isBusyExcludingUninstall || state.cleanupQueued
                      || state.isSystemMaintenanceRunning || !state.cleanupScanComplete)
            .alert(l10n.tf("cleanup.appData.confirm.title", selectedAppData.count),
                   isPresented: $confirmingAppData) {
                Button(l10n.t("common.cancel"), role: .cancel) {}
                Button(l10n.t("cleanup.appData.confirm.action"), role: .destructive) { state.applyCleanup() }
            } message: {
                Text(l10n.tf("cleanup.appData.confirm.message",
                             selectedAppData.prefix(6).map {
                                 L10nLocalizationAuditTables.categoryName($0.name, isAppLeftover: $0.source == .appLeftover)
                             }.joined(separator: "、")))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var cleanupOutcomeDetails: some View {
        if state.cleanupOutcomeMood == .attention {
            VStack(alignment: .leading, spacing: 6) {
                Text(l10n.t("cleanup.execution.review"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if !state.cleanupOutcomeDetails.isEmpty {
                    DisclosureGroup(l10n.t("cleanup.execution.details"), isExpanded: $showsOutcomeDetails) {
                        Text(state.cleanupOutcomeDetails.joined(separator: "\n\n"))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 11))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .modifier(ListRowSurface())
        }
    }

    private var applyLabel: String {
        if state.cleanupQueued { return l10n.t("cleanup.queued") }
        if state.isApplying { return l10n.t("cleanup.apply.busy") }
        if state.hasCleanupSelection {
            let installerBytes = state.installerCandidates?.selectedSubset?.bytes ?? 0
            return l10n.tf("cleanup.delete.withCount",
                           ByteFormat.format(state.selectedBytes + installerBytes))
        }
        return l10n.t("cleanup.delete")
    }

    private var groupedCategories: [CleanupPresentationGroup] {
        let buckets = Dictionary(grouping: state.categories) {
            CleanupGroupBucket(category: $0)
        }
        return buckets.map { kind, categories in
            CleanupPresentationGroup(
                kind: kind,
                categoryIDs: categories.sorted(by: CleanupCategory.sizeDescending).map(\.id),
                bytes: categories.reduce(0) { $0 &+ $1.bytes })
        }
        .sorted {
            if $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
            return $0.kind.sortOrder < $1.kind.sortOrder
        }
    }

    @ViewBuilder
    private func cleanupGroupHeader(_ group: CleanupPresentationGroup) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: groupSelection(group))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!state.cleanupScanComplete || state.isApplying)
            // 整个标题区可点击折叠，比小箭头按钮更容易命中。
            Button { toggleCollapsed(group.kind) } label: {
                HStack(spacing: 8) {
                    Image(systemName: group.kind.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.moleAccentText)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.accent.opacity(0.14)))
                    Text(l10n.t(group.kind.titleKey))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    Text(ByteFormat.format(group.bytes))
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Color.moleAccentText)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(collapsedGroups.contains(group.kind) ? -90 : 0))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.surface2))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(MolePlainButtonStyle(pressedScale: 0.995))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .modifier(ListRowSurface(emphasis: .header))
    }

    private func groupSelection(_ group: CleanupPresentationGroup) -> Binding<Bool> {
        Binding(
            get: {
                let categories = state.categories.filter {
                    group.categoryIDs.contains($0.id) && (!$0.isAppDataReview || group.kind == .appData)
                }
                return !categories.isEmpty && categories.allSatisfy(\.allSelected)
            },
            set: { selected in
                for index in state.categories.indices
                    where group.categoryIDs.contains(state.categories[index].id)
                        && (!selected || !state.categories[index].isAppDataReview) {
                    state.categories[index].selected = selected
                }
            }
        )
    }

}

/// 展示真实目录进度；轻量的进度子视图和吉祥物分别更新。
private struct CleanupScanProgressView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        NoriPlaceholderStage { size in
            NoriStatusAnimation(mood: .working, size: size)
            NoriCurrentFileView(path: state.cleanupProgress.currentPath)
            Button { state.cancelCleanupScan() } label: {
                Label(l10n.t("cleanup.cancelScan"), systemImage: "xmark.circle")
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }
}

private struct CleanupPresentationGroup: Identifiable {
    let kind: CleanupGroupBucket
    let categoryIDs: [UUID]
    let bytes: UInt64
    var id: String { kind.rawValue }
}

extension CleanupGroupBucket {
    var titleKey: String { "cleanup.group.\(rawValue)" }
    var symbol: String {
        switch self {
        case .cache: return "sparkles"
        case .trash: return "trash.fill"
        case .developer: return "hammer.fill"
        case .system: return "gearshape.2.fill"
        case .leftovers: return "app.badge.checkmark"
        case .appData: return "externaldrive.badge.questionmark"
        }
    }
    var sortOrder: Int {
        switch self {
        case .cache: return 0
        case .system: return 1
        case .leftovers: return 2
        case .appData: return 3
        case .trash: return 4
        case .developer: return 5
        }
    }
}

struct CategoryRowView: View {
    @Binding var category: CleanupCategory
    let selectionEnabled: Bool
    var highlightsSensitiveData = false
    var coveredPaths: Set<String> = []
    var onAutoClean: (() -> Void)? = nil
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 展开时的路径顺序只在路径集合变化时重排，滚动和勾选不再触发全量排序。
    @State private var sortedPaths: [String] = []

    /// 类目下的路径是否全部已设置定时清理（决定徽标文案）。
    private var fullyScheduled: Bool {
        !coveredPaths.isEmpty && coveredPaths.count == category.paths.count
    }

    private var scheduledBadgeText: String {
        fullyScheduled
            ? l10n.t("auto.mark.covered")
            : l10n.tf("auto.mark.coveredPartial", coveredPaths.count, category.paths.count)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Toggle("", isOn: categorySelection)
                    .toggleStyle(.checkbox)
                    .controlSize(.mini)
                    .labelsHidden()
                    .fixedSize()
                    .disabled(!category.canSelect || !selectionEnabled)
                Button(action: toggleExpanded) {
                    HStack(spacing: 6) {
                        Text(L10nLocalizationAuditTables.categoryName(category.name, isAppLeftover: category.source == .appLeftover))
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if sensitive {
                            Text(l10n.t("agents.risk.high"))
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Color.danger)
                        } else { RiskBadge(risk: category.risk) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(MolePlainButtonStyle(pressedScale: 0.99))
                Spacer()
                SizeBadge(text: ByteFormat.format(category.partiallySelected ? category.selectedPathBytes : category.bytes),
                          prominent: category.selected)
                if !coveredPaths.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "clock.fill")
                            .font(.system(size: 8, weight: .semibold))
                        Text(scheduledBadgeText)
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(Color.moleAccentText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.moleAccent.opacity(0.12)))
                    .help(l10n.t("auto.mark.covered"))
                    .accessibilityLabel(l10n.t("auto.mark.covered"))
                }
                if let onAutoClean {
                    Button(action: onAutoClean) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(MoleIconButtonStyle(size: 22))
                    .disabled(!selectionEnabled)
                }
                Button {
                    toggleExpanded()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(category.expanded ? 180 : 0))
                }
                .buttonStyle(MoleIconButtonStyle(size: 22))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            if category.expanded {
                LazyVStack(alignment: .leading, spacing: 3) {
                    Label(l10n.t(category.reasonKey), systemImage: riskSymbol)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(riskColor)
                        .padding(.bottom, 2)
                    ForEach(sortedPaths, id: \.self) { path in
                        HStack(spacing: 7) {
                            Toggle("", isOn: childSelection(for: path))
                                .toggleStyle(.checkbox)
                                .controlSize(.mini)
                                .labelsHidden()
                                .fixedSize()
                                .disabled(!category.canSelect || !selectionEnabled)
                            if coveredPaths.contains(path) {
                                Image(systemName: "clock.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(Color.moleAccentText)
                                    .help(l10n.t("auto.mark.covered"))
                            }
                            Text(path)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            if let bytes = category.pathBytes[path], bytes > 0 {
                                Text(ByteFormat.format(bytes))
                                    .font(.system(size: 9).monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 40)
                .padding(.bottom, 10)
                .transition(.molePanelReveal)
                .task(id: pathOrderKey) { sortedPaths = category.pathsByDescendingSize }
            }
        }
        .clipped()
        .modifier(ListRowSurface(selected: category.selected))
        .animation(reduceMotion ? nil : MoleMotion.selection, value: category.selected)
        .opacity(category.risk == .protected ? 0.72 : 1)
    }

    /// 路径数与总字节一起变化才重排；只勾选不会改变这两个值。
    private var pathOrderKey: String { "\(category.paths.count):\(category.bytes)" }

    private var sensitive: Bool {
        highlightsSensitiveData && (category.reasonKey == "agents.reason.showOnly"
            || category.reasonKey == "agents.reason.undocumented")
    }

    private func toggleExpanded() {
        withAnimation(reduceMotion ? nil : MoleMotion.panel) { category.expanded.toggle() }
    }

    private func childSelection(for path: String) -> Binding<Bool> {
        Binding(
            get: { category.isPathSelected(path) },
            set: { category.setPathSelected(path, selected: $0) }
        )
    }

    private var categorySelection: Binding<Bool> {
        Binding(
            get: { category.allSelected },
            set: { category.selected = $0 }
        )
    }

    private var riskColor: Color {
        if sensitive { return .danger }
        switch category.risk {
        case .safe: return Color.success
        case .warning: return Color.warning
        case .protected: return .secondary
        }
    }

    private var riskSymbol: String {
        switch category.risk {
        case .safe: return "checkmark.shield.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .protected: return "lock.fill"
        }
    }
}

private struct RiskBadge: View {
    let risk: CleanupRisk
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        Text(l10n.t("cleanup.risk.\(risk.rawValue)"))
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.13)))
    }

    private var color: Color {
        switch risk {
        case .safe: return Color.success
        case .warning: return Color.warning
        case .protected: return .secondary
        }
    }
}
