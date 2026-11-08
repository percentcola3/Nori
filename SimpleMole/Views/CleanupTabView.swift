import SwiftUI

/// 可再生垃圾默认推荐；卸载数据需要手动勾选并确认移入废纸篓。
struct CleanupTabView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var l10n = L10n.shared
    /// nil 表示用户还没折叠/展开过：此时除最大分组外全部折叠，长列表首屏
    /// 先看到最重要的内容。一旦用户操作过就完全尊重用户的选择。
    @State private var userCollapsed: Set<CleanupGroupBucket>?
    /// 从可再生缓存行发起的自动清理规则创建。
    @State private var autoCleanIntent: AutoCleanupIntent?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func toggleCollapsed(_ kind: CleanupGroupBucket,
                                 in collapsedGroups: Set<CleanupGroupBucket>) {
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
        state.cleanupPresentation.coveredPaths[category.id] ?? []
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
            } else if !showsCleanupResults {
                NoriPlaceholderStage { size in
                    NoriIdlePlaceholder(state: state, size: size)
                    scanButton
                }
            } else {
                // Classification and scheduled-path membership are produced
                // off the main actor only when inventory or rule roots change.
                let groups = state.cleanupPresentation.groups
                let collapsedGroups = userCollapsed ?? Set(groups.dropFirst().map(\.kind))
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(groups) { group in
                            VStack(spacing: 8) {
                                cleanupGroupHeader(group, collapsedGroups: collapsedGroups)
                                if !collapsedGroups.contains(group.kind) {
                                    LazyVStack(spacing: 8) {
                                        ForEach(group.categoryIDs, id: \.self) { categoryID in
                                            if let index = state.cleanupPresentation.categoryIndices[categoryID],
                                               state.categories.indices.contains(index),
                                               state.categories[index].id == categoryID {
                                                CategoryRowView(
                                                    category: $state.categories[index],
                                                    selectionEnabled: state.cleanupScanComplete
                                                        && !state.isApplying,
                                                    coveredPaths: coveredAutoCleanPaths(
                                                        for: state.categories[index]),
                                                    usesSelectionSnapshot: true,
                                                    selectedBytes: state.cleanupSelectedBytes(for: categoryID),
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
                               value: state.cleanupPresentation.categoryIDs)
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
        .disabled(state.isCleanupTaskBusy || state.cleanupQueued)
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
                    .foregroundStyle(isSelected ? Color.moleAccentText : Color.textSecondary)
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
                if row.preview.bytes > 0 {
                    SizeBadge(text: ByteFormat.format(row.preview.bytes), prominent: isSelected)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(MolePlainButtonStyle())
        .modifier(ListRowSurface(selected: isSelected))
        .disabled(state.isCleanupTaskBusy)
    }

    private var cleanupActions: some View {
        HStack(spacing: 8) {
            Button { state.startCleanupScan() } label: {
                Label(l10n.t("common.rescan"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(state.isCleanupTaskBusy || state.cleanupQueued || state.isSystemMaintenanceRunning)
            // 全选/取消全选由各分组头的开关承担：底部只保留唯一的执行入口，
            // 系统维护项的勾选也由它统一分发。
            Spacer()
            Button { state.requestCleanupFromPage() } label: {
                Label(applyLabel, systemImage: "trash.fill")
                    .padding(.horizontal, 20)
                    .frame(minHeight: 36)
                    .contentShape(Capsule())
            }
            .buttonStyle(CleanupApplyButtonStyle())
            .accessibilityIdentifier("cleanup-apply")
            .disabled(state.cleanupButtonBlockReason != nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .onAppear { traceCleanupGate("ui.footer.appear") }
        .onChange(of: state.cleanupGateSignature) { _ in traceCleanupGate("ui.footer.gate_changed") }
        .onDisappear { traceCleanupGate("ui.footer.disappear") }
    }

    private func traceCleanupGate(_ event: String) {
        state.traceCleanupInteraction(event, fields: [
            "gate": state.cleanupButtonBlockReason ?? "enabled",
            "signature": state.cleanupGateSignature,
            "phase": String(presentationPhase)
        ])
    }

    private var applyLabel: String {
        if state.cleanupQueued { return l10n.t("cleanup.queued") }
        if state.isApplying { return l10n.t("cleanup.apply.busy") }
        if state.hasCleanupSelection, let selectedBytes = state.selectedBytes {
            return l10n.tf("cleanup.delete.withCount", ByteFormat.format(selectedBytes))
        }
        return l10n.t("cleanup.delete")
    }

    @ViewBuilder
    private func cleanupGroupHeader(_ group: CleanupPresentationGroup,
                                    collapsedGroups: Set<CleanupGroupBucket>) -> some View {
        HStack(spacing: 0) {
            Toggle(isOn: groupSelection(group)) {
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
                }
            }
            .toggleStyle(MoleRowSelectionToggleStyle(
                partiallySelected: groupPartiallySelected(group), horizontalPadding: 10))
            .disabled(!state.cleanupScanComplete || state.isApplying)
            .accessibilityIdentifier("cleanup-group-select-" + group.kind.rawValue)
            Button { toggleCollapsed(group.kind, in: collapsedGroups) } label: {
                Image(systemName: "chevron.down")
                    .rotationEffect(.degrees(collapsedGroups.contains(group.kind) ? -90 : 0))
            }
            .buttonStyle(MoleIconButtonStyle(size: 30))
            .accessibilityLabel(l10n.t(collapsedGroups.contains(group.kind) ? "cleanup.expand" : "cleanup.collapse") + ": " + l10n.t(group.kind.titleKey))
            .accessibilityIdentifier("cleanup-group-expand-" + group.kind.rawValue)
            .padding(.trailing, 8)
        }
        .modifier(ListRowSurface(emphasis: .header))
    }

    private func groupPartiallySelected(_ group: CleanupPresentationGroup) -> Bool {
        let categories = state.categories.filter {
            group.categoryIDs.contains($0.id)
                && (!$0.isAppDataReview || group.kind == .appData || group.kind == .leftovers)
        }
        return categories.contains(where: \.selected) && !categories.allSatisfy(\.allSelected)
    }

    private func groupSelection(_ group: CleanupPresentationGroup) -> Binding<Bool> {
        Binding(
            get: {
                let categories = state.categories.filter {
                    group.categoryIDs.contains($0.id)
                        && (!$0.isAppDataReview || group.kind == .appData || group.kind == .leftovers)
                }
                return !categories.isEmpty && categories.allSatisfy(\.allSelected)
            },
            set: { selected in
                for index in state.categories.indices
                    where group.categoryIDs.contains(state.categories[index].id)
                        && (!selected || !state.categories[index].isAppDataReview || group.kind == .leftovers) {
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

extension CleanupGroupBucket {
    var titleKey: String { "cleanup.group.\(rawValue)" }
    var symbol: String {
        switch self {
        case .cache: return "sparkles"
        case .messenger: return "bubble.left.and.bubble.right.fill"
        case .trash: return "trash.fill"
        case .developer: return "hammer.fill"
        case .system: return "gearshape.2.fill"
        case .leftovers: return "app.badge.checkmark"
        case .appData: return "externaldrive.badge.questionmark"
        }
    }
}

/// The page's label owns its complete padded hit shape. Keep the shared glass
/// and pressed feedback without adding PrimaryButtonStyle's padding twice.
private struct CleanupApplyButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(isEnabled ? Color.textPrimary : Color.textSecondary)
            .modifier(ActionGlassChrome())
            .opacity(isEnabled ? 1 : 0.5)
            .modifier(MoleButtonFeedbackModifier(isPressed: configuration.isPressed))
    }
}

struct CategoryRowView: View {
    @Binding var category: CleanupCategory
    let selectionEnabled: Bool
    var highlightsSensitiveData = false
    var coveredPaths: Set<String> = []
    var usesSelectionSnapshot = false
    var selectedBytes: UInt64? = nil
    var onAutoClean: (() -> Void)? = nil
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 展开时的路径顺序只在路径集合变化时重排，滚动和勾选不再触发全量排序。
    @State private var sortedPaths: [String] = []
    @State private var localSelectionBytes: UInt64?
    @State private var localSelectionVersion: CleanupSelectionKey?

    private var selectionKey: CleanupSelectionKey { CleanupSelectionKey(category) }

    private var categorySizeText: String {
        guard category.partiallySelected else { return ByteFormat.format(category.bytes) }
        let bytes = usesSelectionSnapshot ? selectedBytes
            : (localSelectionVersion == selectionKey ? localSelectionBytes : nil)
        return bytes.map { ByteFormat.format($0) } ?? "…"
    }

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
            HStack(spacing: 4) {
                if category.canSelect {
                    Toggle(isOn: categorySelection) { categoryLabel }
                        .toggleStyle(MoleRowSelectionToggleStyle(partiallySelected: category.partiallySelected))
                        .disabled(!selectionEnabled)
                        .accessibilityIdentifier("cleanup-category-select-" + category.id.uuidString)
                } else {
                    Button { toggleExpanded() } label: {
                        readOnlyContent(horizontalPadding: 12, minHeight: 36) { categoryLabel }
                    }
                    .buttonStyle(MolePlainButtonStyle(pressedScale: 0.995))
                    .help(l10n.t(category.reasonKey))
                    .accessibilityLabel(L10nLocalizationAuditTables.categoryName(category.name,
                        isAppLeftover: category.source == .appLeftover) + " · " + l10n.t("agents.badge.showOnly"))
                    .accessibilityValue(l10n.t(category.expanded ? "agents.expanded" : "agents.collapsed"))
                    .accessibilityIdentifier("cleanup-category-readonly-" + category.id.uuidString)
                }
                if let onAutoClean {
                    Button(action: onAutoClean) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(MoleIconButtonStyle(size: 30))
                    .disabled(!selectionEnabled)
                    .help(l10n.t("auto.title"))
                    .accessibilityLabel(l10n.t("auto.title"))
                    .accessibilityIdentifier("cleanup-category-schedule-" + category.id.uuidString)
                }
                Button {
                    toggleExpanded()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(category.expanded ? 180 : 0))
                }
                .buttonStyle(MoleIconButtonStyle(size: 30))
                .accessibilityLabel(l10n.t(category.expanded ? "cleanup.collapse" : "cleanup.expand"))
                .accessibilityIdentifier("cleanup-category-expand-" + category.id.uuidString)
                .padding(.trailing, 8)
            }
            if category.expanded {
                LazyVStack(alignment: .leading, spacing: 3) {
                    Label(l10n.t(category.reasonKey), systemImage: riskSymbol)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(riskColor)
                        .padding(.bottom, 2)
                    ForEach(sortedPaths, id: \.self) { path in
                        Group {
                            if category.canSelect {
                                Toggle(isOn: childSelection(for: path)) { pathLabel(for: path) }
                                    .toggleStyle(MoleRowSelectionToggleStyle(horizontalPadding: 8, minHeight: 28))
                                    .disabled(!selectionEnabled)
                                    .accessibilityLabel(path)
                                    .accessibilityIdentifier("cleanup-path-select-" + path)
                            } else {
                                readOnlyContent(horizontalPadding: 8, minHeight: 28) { pathLabel(for: path) }
                                    .accessibilityElement(children: .combine)
                                    .accessibilityLabel(path + " · " + l10n.t("agents.badge.showOnly"))
                                    .accessibilityIdentifier("cleanup-path-readonly-" + path)
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(category.isPathSelected(path) ? Color.selectionFill : Color.surface1))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 32)
                .padding(.trailing, 12)
                .padding(.bottom, 10)
                .transition(.molePanelReveal)
                .task(id: category.pathOrderToken) {
                    let token = category.pathOrderToken
                    let paths = category.paths
                    let sizes = category.pathBytes
                    sortedPaths = []
                    let work = Task.detached(priority: .userInitiated) {
                        CleanupCategory.sortedPaths(paths, pathBytes: sizes)
                    }
                    let ordered = await withTaskCancellationHandler {
                        await work.value
                    } onCancel: { work.cancel() }
                    guard !Task.isCancelled, category.pathOrderToken == token else { return }
                    sortedPaths = ordered
                }
            }
        }
        .clipped()
        .modifier(ListRowSurface(selected: category.selected))
        .animation(reduceMotion ? nil : MoleMotion.selection, value: category.selected)
        .opacity(category.risk == .protected ? 0.72 : 1)
        .task(id: usesSelectionSnapshot ? nil : selectionKey) {
            // CleanupTab supplies its shared projection. Other row consumers
            // use the same detached computation, with no synchronous fallback.
            guard !usesSelectionSnapshot, category.partiallySelected else { return }
            let version = selectionKey
            let input = CleanupSelectionPresentation.Input(category)
            let work = Task.detached(priority: .userInitiated) {
                CleanupSelectionPresentation.build([input], isCancelled: { Task.isCancelled })
            }
            let result = await withTaskCancellationHandler {
                await work.value
            } onCancel: { work.cancel() }
            guard !Task.isCancelled, selectionKey == version, let result else { return }
            localSelectionBytes = result.bytesByCategory[category.id]
            localSelectionVersion = version
        }
    }

    private var categoryLabel: some View {
        HStack(spacing: 8) {
            Text(L10nLocalizationAuditTables.categoryName(category.name, isAppLeftover: category.source == .appLeftover))
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
            if !category.canSelect {
                Text(l10n.t("agents.badge.showOnly"))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            } else if sensitive {
                Text(l10n.t("agents.risk.high"))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.danger)
            } else { RiskBadge(risk: category.risk) }
            Spacer(minLength: 8)
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
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.moleAccent.opacity(0.12)))
                .help(l10n.t("auto.mark.covered"))
                .accessibilityLabel(l10n.t("auto.mark.covered"))
            }
        }
    }

    private func pathLabel(for path: String) -> some View {
        HStack(spacing: 7) {
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
            if let note = category.pathNotes[path] {
                Text(note)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            if let bytes = category.pathBytes[path], bytes > 0 {
                Text(ByteFormat.format(bytes))
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func readOnlyContent<Content: View>(horizontalPadding: CGFloat, minHeight: CGFloat,
                                               @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            content()
        }
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
        .padding(.horizontal, horizontalPadding)
        .contentShape(Rectangle())
    }

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
