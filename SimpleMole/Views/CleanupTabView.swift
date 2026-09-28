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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 系统数据（root 拥有的日志/报告/缓存）从清理页下钻，不再占顶级 Tab。
    @State private var showSystemData = false

    private var collapsedGroups: Set<CleanupGroupBucket> {
        userCollapsed ?? defaultCollapsedGroups
    }

    private var defaultCollapsedGroups: Set<CleanupGroupBucket> {
        let groups = groupedCategories
        guard groups.count > 1 else { return [] }
        return Set(groups.dropFirst().map(\.kind))
    }

    private func toggleCollapsed(_ kind: CleanupGroupBucket) {
        withAnimation(MoleMotion.panel) {
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
            autoCleanIntent = AutoCleanupIntent(paths: category.paths, cacheVerified: true)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                Label(l10n.t("cleanup.safeOnly"), systemImage: "checkmark.shield.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    showSystemData = true
                } label: {
                    Label(l10n.t("cleanup.systemData.open"), systemImage: "shield.checkered")
                }
                .buttonStyle(SecondaryButtonStyle())
                .help(l10n.t("system.subtitle"))
                Button { state.requestScanAccess(.deepCleanupScan) } label: {
                    Text(l10n.t("cleanup.scan.deep"))
                }
                .buttonStyle(SecondaryButtonStyle())
                .help(l10n.t("cleanup.scan.deep.hint"))
                .disabled(state.isBusyExcludingUninstall || state.cleanupQueued)
                if state.isCleanupScanning || !state.categories.isEmpty {
                    quickCleanButton
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
            // 与 autoCleanIntent 的 sheet 分开挂节点，避免多 sheet 同节点失联。
            .sheet(isPresented: $showSystemData) {
                SystemDataView(state: state)
                    .frame(minWidth: 720, minHeight: 540)
            }

            if !state.isCleanupScanning && !state.cleanupDeferredPaths.isEmpty {
                Label(l10n.tf("cleanup.scan.deferred", state.cleanupDeferredPaths.count),
                      systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
                    .help(state.cleanupDeferredPaths.prefix(12).joined(separator: "\n"))
            }

            if !state.isCleanupScanning && !state.isApplying, let mood = state.cleanupOutcomeMood {
                HStack(spacing: 12) {
                    NoriStatusAnimation(mood: mood, size: 52)
                        .id(state.cleanupFeedbackID)
                    Text(state.statusText)
                        .font(.system(size: 12, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }

            if state.isApplying {
                VStack(spacing: 12) {
                    NoriStatusAnimation(mood: .working, size: 84)
                    Text(state.statusText).font(.system(size: 12))
                    ProgressView().controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if state.isCleanupScanning {
                CleanupScanProgressView(state: state)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if state.categories.isEmpty {
                VStack(spacing: 12) {
                    if state.cleanupOutcomeMood == nil { NoriStatusAnimation(mood: .idle, size: 76) }
                    quickCleanButton
                    Text(l10n.t("cleanup.empty.subtitle"))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
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
                                                    onAutoClean: autoCleanAction(
                                                        for: state.categories[index]))
                                            }
                                        }
                                    }
                                    .padding(.leading, 14)
                                    .transition(.molePanelReveal)
                                }
                            }
                            .transition(.molePanelReveal)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                    // 扫描结果入场/移除的液态流动：按 id 变化触发，勾选操作不参与。
                    .animation(reduceMotion ? nil : MoleMotion.panel,
                               value: state.categories.map(\.id))
                }
            }

            if !state.isCleanupScanning, let installers = state.installerCandidates {
                VStack(alignment: .leading, spacing: 6) {
                    Text(l10n.t("cleanup.installers.review")).font(.caption).foregroundStyle(.secondary)
                    CategoryRowView(category: Binding(
                        get: { state.installerCandidates ?? installers },
                        set: { state.installerCandidates = $0 }), selectionEnabled: !state.isBusy)
                    Button(l10n.t("confirm.cleanupPermanent.ok")) { state.applyInstallers() }
                        .disabled(state.isBusy || state.installerCandidates?.selectedSubset == nil)
                }.padding(.horizontal, 16).padding(.vertical, 8)
            }

            if !state.isCleanupScanning && !state.categories.isEmpty {
                Divider()
                cleanupActions
            }
        }
        .sheet(item: $autoCleanIntent) { intent in
            AutoCleanupIntentSheet(state: state, intent: intent) {
                autoCleanIntent = nil
            }
        }
    }

    private var quickCleanButton: some View {
        Button {
            state.requestScanAccess(.quickOptimize)
        } label: {
            Label(state.isCleanupScanning ? l10n.t("common.scanning") : l10n.t("cleanup.quickClean"),
                  systemImage: "sparkles")
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(state.isBusyExcludingUninstall || state.cleanupQueued)
    }

    private var cleanupActions: some View {
        HStack(spacing: 8) {
            Button {
                for index in state.categories.indices {
                    state.categories[index].selected = state.categories[index].canSelect
                }
            } label: {
                Label(l10n.t("common.selectAll"), systemImage: "checkmark.circle")
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(state.categories.isEmpty || !state.cleanupScanComplete
                || state.isApplying)
            .labelStyle(.iconOnly)
            .help(l10n.t("common.selectAll"))
            Button {
                for index in state.categories.indices { state.categories[index].selected = false }
            } label: {
                Label(l10n.t("common.deselectAll"), systemImage: "minus.circle")
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(state.categories.isEmpty || state.isApplying)
            .labelStyle(.iconOnly)
            .help(l10n.t("common.deselectAll"))
            if state.cleanupScanComplete && !state.categories.isEmpty {
                HStack(spacing: 5) {
                    RiskBadge(risk: .safe)
                    Text("\(state.quickCleanCount) · \(ByteFormat.format(state.quickCleanBytes))")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                    if state.reviewCount > 0 {
                        Divider().frame(height: 14)
                        RiskBadge(risk: .warning)
                        Text("\(state.reviewCount)")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Button { state.applyCleanup() } label: {
                Label(applyLabel, systemImage: "trash.fill")
            }
            .buttonStyle(PrimaryButtonStyle())
            .help(applyLabel)
            .disabled(state.selectedCount == 0 || state.isBusyExcludingUninstall || state.cleanupQueued || !state.cleanupScanComplete)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var applyLabel: String {
        if state.cleanupQueued { return l10n.t("cleanup.queued") }
        if state.isApplying { return l10n.t("cleanup.apply.busy") }
        if state.selectedCount > 0 {
            return l10n.tf("cleanup.delete.withCount", state.selectedCount,
                           ByteFormat.format(state.selectedBytes))
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
                    Text(groupSelectionCount(group))
                        .font(.system(size: 9, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.surface3))
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
            .help(collapsedGroups.contains(group.kind) ? l10n.t("cleanup.expand")
                  : l10n.t("cleanup.collapse"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(collapsedGroups.contains(group.kind) ? Color.surface1 : Color.surface2)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.hairline, lineWidth: 1)
        }
    }

    private func groupSelection(_ group: CleanupPresentationGroup) -> Binding<Bool> {
        Binding(
            get: {
                let categories = state.categories.filter { group.categoryIDs.contains($0.id) }
                return !categories.isEmpty && categories.allSatisfy(\.allSelected)
            },
            set: { selected in
                for index in state.categories.indices
                    where group.categoryIDs.contains(state.categories[index].id) {
                    state.categories[index].selected = selected
                }
            }
        )
    }

    private func groupSelectionCount(_ group: CleanupPresentationGroup) -> String {
        let categories = state.categories.filter { group.categoryIDs.contains($0.id) }
        let selected = categories.reduce(0) { $0 + $1.selectedPathCount }
        let total = categories.reduce(0) { $0 + $1.paths.count }
        return selected == total ? "\(total)" : "\(selected)/\(total)"
    }
}

/// 扫描尚未产生结果时的进度面板。路径使用横向滚动条，长路径不会把
/// 窗口撑宽；底层只回传目录级事件，不会因 UI 更新拖慢文件遍历。
private struct CleanupScanProgressView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var l10n = L10n.shared

    private var progress: CleanupScanProgress { state.cleanupProgress }

    var body: some View {
        VStack(spacing: 10) {
            NoriStatusAnimation(mood: .working, size: 156)
                .padding(.bottom, 8)
            HStack(spacing: 7) {
                Text(l10n.t(state.cleanupScanMode.titleKey))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                if let fraction = progress.fraction {
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Color.moleAccentText)
                }
            }

            Text(l10n.t(state.cleanupScanMode.hintKey))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let fraction = progress.fraction {
                ProgressView(value: fraction)
                    .tint(Color.moleAccent)
            } else {
                ProgressView()
                    .tint(Color.moleAccent)
            }

            HStack(spacing: 6) {
                if progress.detailTotal > 0 {
                    Text(l10n.tf("cleanup.progress.detail",
                                progress.detailCompleted, progress.detailTotal))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                } else if progress.total > 0 {
                    Text(l10n.tf("cleanup.progress.items",
                                progress.completed, progress.total))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            ScanPathTicker(path: l10n.tf(
                "cleanup.progress.path",
                progress.currentPath.isEmpty ? NSHomeDirectory() : progress.currentPath))

            Button { state.cancelCleanupScan() } label: {
                Label(l10n.t("cleanup.cancelScan"), systemImage: "xmark.circle")
            }
            .buttonStyle(SecondaryButtonStyle())
            .controlSize(.small)
        }
        .frame(maxWidth: 540)
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

private struct ScanPathTicker: View {
    let path: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                Text(path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .id(path)
                    .frame(minWidth: 260, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onAppear {
                proxy.scrollTo(path, anchor: .trailing)
            }
            .onChange(of: path) { nextPath in
                withAnimation(.linear(duration: 0.3)) {
                    proxy.scrollTo(nextPath, anchor: .trailing)
                }
            }
        }
        .frame(height: 16)
        .clipped()
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
        case .ai: return "brain"
        case .leftovers: return "app.badge.checkmark"
        }
    }
    var sortOrder: Int {
        switch self {
        case .cache: return 0
        case .leftovers: return 1
        case .trash: return 2
        case .developer: return 3
        case .ai: return 4
        }
    }
}

struct CategoryRowView: View {
    @Binding var category: CleanupCategory
    let selectionEnabled: Bool
    var onAutoClean: (() -> Void)? = nil
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

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
                        Text(category.name)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(selectionCountText)
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.secondary)
                        RiskBadge(risk: category.risk)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(MolePlainButtonStyle(pressedScale: 0.99))
                Spacer()
                SizeBadge(text: ByteFormat.format(category.bytes), prominent: category.selected)
                if let onAutoClean {
                    Button(action: onAutoClean) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(MoleIconButtonStyle(size: 22))
                    .help(l10n.t("auto.entry.create"))
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
                    ForEach(category.pathsByDescendingSize, id: \.self) { path in
                        HStack(spacing: 7) {
                            Toggle("", isOn: childSelection(for: path))
                                .toggleStyle(.checkbox)
                                .controlSize(.mini)
                                .labelsHidden()
                                .fixedSize()
                                .disabled(!category.canSelect || !selectionEnabled)
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
            }
        }
        .clipped()
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(cardHighlight)
                .shadow(color: category.selected
                            ? Color.moleAccent.opacity(hovered ? 0.12 : 0.07)
                            : .clear,
                        radius: hovered ? 9 : 6,
                        y: 1)
        )
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : MoleMotion.hover) {
                hovered = hovering
            }
        }
        .animation(reduceMotion ? nil : MoleMotion.selection, value: category.selected)
        .opacity(category.risk == .protected ? 0.72 : 1)
    }

    private var cardHighlight: Color {
        if category.selected {
            return Color.moleAccent.opacity(hovered ? 0.12 : 0.085)
        }
        return hovered ? Color.surface3 : Color.surface2
    }

    private func toggleExpanded() {
        withAnimation(reduceMotion ? nil : MoleMotion.panel) { category.expanded.toggle() }
    }

    private var selectionCountText: String {
        guard category.partiallySelected else { return "\(category.paths.count)" }
        return "\(category.selectedPathCount)/\(category.paths.count)"
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
