import SwiftUI

/// 从当前目录逐层浏览实际磁盘占用。
struct AnalyzeTabView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var savedLocations: SavedScanLocationStore
    @ObservedObject private var l10n = L10n.shared
    /// 从分析结果目录发起的自动清理规则创建。
    @State private var autoCleanIntent: AutoCleanupIntent?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(state: AppState) {
        self.state = state
        self.savedLocations = state.savedScanLocations
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                if state.analyzePath != "/" {
                    Button { state.analyzeGoUp() } label: {
                        Label(l10n.t("analyze.up"), systemImage: "chevron.left")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .labelStyle(.iconOnly)
                    .help(l10n.t("analyze.up"))
                    .disabled(state.isBusy)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(scopeTitle)
                        .font(.system(size: 13, weight: .semibold))
                    Text(state.analyzePath)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button { state.chooseAnalyzeFolder() } label: {
                    Label(l10n.t("analyze.pick"), systemImage: "folder")
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(state.isBusy)
                Menu {
                    Button { state.scanQuickAnalysis(force: true) } label: {
                        Label(l10n.t("analyze.scope.quick"), systemImage: "bolt.horizontal")
                    }
                    Button { state.scanDiskOverview(force: true) } label: {
                        Label(l10n.t("analyze.scope.full"), systemImage: "macbook.and.iphone")
                    }
                    Button { state.chooseAnalyzeFolder() } label: {
                        Label(l10n.t("analyze.pick"), systemImage: "folder.badge.plus")
                    }
                    Divider()
                    Button { state.addSavedScanLocation() } label: {
                        Label(l10n.t("analyze.savedScope.add"), systemImage: "bookmark")
                    }
                    ForEach(savedLocations.locations) { location in
                        Button {
                            state.scanAnalyze(location.path)
                        } label: {
                            Label(location.displayName, systemImage: "bookmark.fill")
                        }
                        .disabled(location.availability != .available)
                    }
                    Divider()
                    Button { state.openProjectRadar() } label: {
                        Label(l10n.t("analyze.projectRadar"), systemImage: "scope")
                    }
                } label: {
                    Label(l10n.t("analyze.advanced"), systemImage: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(state.isBusy)
                Button {
                    if state.isAnalyzing { state.cancelAnalyze() } else { refreshCurrentScope() }
                } label: {
                    Label(state.isAnalyzing ? l10n.t("common.cancel") : l10n.t("analyze.scan"),
                          systemImage: "arrow.clockwise")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(state.isBusy && !state.isAnalyzing)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 6)
            .sheet(isPresented: $state.showProjectRadar) {
                ProjectRadarView(
                    store: state.projectRadar,
                    locations: savedLocations.locations,
                    hibernation: state.projectHibernation,
                    fullDiskAccessGranted: state.permissionCenter.fullDiskAccessGranted,
                    canMutate: !state.isBusy,
                    onAddLocation: state.addSavedScanLocation)
            }
            .onAppear {
                if state.permissionCenter.fullDiskAccessGranted {
                    _ = savedLocations.refreshAvailability(persist: false)
                }
                // 默认第一层：快速分析只测个人目录、既知缓存和保存位置；
                // 全盘深度分析从范围菜单主动启动。
                state.scanQuickAnalysis()
            }

            HStack(spacing: 6) {
                if state.isAnalyzing { ProgressView().controlSize(.mini) }
                Text(state.analyzeStatus)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                if state.isScanningDups {
                    ProgressView().controlSize(.mini)
                    Text(l10n.t("common.scanning"))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                } else if !state.analyzeLargeFiles.isEmpty {
                    Button { state.scanDuplicates() } label: {
                        Label(l10n.t("analyze.dupScan"), systemImage: "square.on.square.dashed")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .labelStyle(.iconOnly)
                    .help(l10n.t("analyze.dupScan"))
                    .controlSize(.small)
                }
                Text(l10n.t("analyze.directory.hint"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            if state.isAnalyzing && state.analyzeEntries.isEmpty && state.analyzeAIItems.isEmpty {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.large)
                    Text(l10n.t("analyze.scanning"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if state.analyzeEntries.isEmpty && state.analyzeAIItems.isEmpty {
                EmptyStateView(symbol: "chart.bar.doc.horizontal",
                               title: l10n.t("analyze.status.empty"),
                               subtitle: l10n.t("analyze.empty.subtitle"))
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(state.analyzeEntries) { entry in
                            AnalyzeRowView(
                                entry: entry,
                                isSelected: state.analyzeSelection.contains(entry.path),
                                canSelect: entry.canCleanDirectly
                            ) {
                                state.toggleAnalyzeSelection(entry)
                            } onOpen: {
                                state.openAnalyzeEntry(entry)
                            }
                            .contextMenu {
                                if entry.isDir {
                                    Button {
                                        autoCleanIntent = AutoCleanupIntent(
                                            paths: [entry.path], cacheVerified: false)
                                    } label: {
                                        Label(l10n.t("auto.entry.create"),
                                              systemImage: "clock.arrow.circlepath")
                                    }
                                }
                            }
                            .disabled(state.isBusy)
                            .transition(.molePanelReveal)
                        }
                        if !state.dupGroups.isEmpty {
                            duplicatesSection
                        }
                        if state.snapshotsScanned {
                            snapshotsSection
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    // 分析结果增量到达/排序变化时的液态流动：按路径集合触发。
                    .animation(reduceMotion ? nil : MoleMotion.panel,
                               value: state.analyzeEntries.map(\.path))
                }
            }

            if !state.analyzeEntries.isEmpty || !state.analyzeAIItems.isEmpty {
                Divider()
                HStack {
                    Text(footerText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !state.dupSelection.isEmpty {
                        Button { state.deleteDuplicates() } label: {
                            Label(l10n.t("analyze.dupDelete"),
                                  systemImage: "trash.fill")
                        }
                        .buttonStyle(DangerButtonStyle())
                        .labelStyle(.iconOnly)
                        .help(l10n.t("analyze.dupDelete"))
                        .disabled(state.isBusy)
                    }
                    Button { state.applyAnalyzeCleanup() } label: {
                        Label(l10n.t("analyze.apply"), systemImage: "trash.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled((state.analyzeSelection.isEmpty && state.analyzeAISelection.isEmpty)
                              || state.isBusy)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
        .sheet(item: $autoCleanIntent) { intent in
            AutoCleanupIntentSheet(state: state, intent: intent) {
                autoCleanIntent = nil
            }
        }
    }

    private var scopeTitle: String {
        if state.analyzePath == "/" { return "/" }
        let name = URL(fileURLWithPath: state.analyzePath).lastPathComponent
        return name.isEmpty ? state.analyzePath : name
    }

    private func refreshCurrentScope() {
        if state.analyzeIsOverview {
            state.scanDiskOverview(force: true)
        } else {
            state.scanAnalyze(force: true)
        }
    }

    private var snapshotsSection: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 11))
                .foregroundStyle(Color.moleAccentText)
            VStack(alignment: .leading, spacing: 1) {
                Text(l10n.t("analyze.snapshots"))
                    .font(.system(size: 11, weight: .semibold))
                Text(l10n.tf("analyze.snapshotCount", state.localSnapshots.count))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Text(state.purgeableBytes > 0 ? ByteFormat.format(state.purgeableBytes) : "--")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
            if state.isThinning {
                ProgressView().controlSize(.mini)
            } else if !state.localSnapshots.isEmpty {
                Button { state.thinSnapshots() } label: {
                    Label(l10n.t("analyze.thin"), systemImage: "arrow.down.circle")
                }
                .buttonStyle(SecondaryButtonStyle())
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.surface2))
    }

    private var footerText: String {
        if !state.dupSelection.isEmpty {
            return l10n.tf("analyze.dup.selected", state.dupSelection.count)
        }
        if state.analyzeSelection.isEmpty {
            if state.analyzeAISelection.isEmpty { return l10n.t("analyze.hint") }
        }
        return l10n.tf("analyze.selected", state.analyzeCombinedSelectedCount,
                       ByteFormat.format(state.analyzeCombinedSelectedBytes))
    }

    /// 重复文件分组区：每组一张卡片，成员行可勾选删除。
    private var duplicatesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(l10n.t("analyze.dup.hint"))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 10)
            ForEach(state.dupGroups.indices, id: \.self) { groupIndex in
                let members = state.dupGroups[groupIndex]
                VStack(alignment: .leading, spacing: 4) {
                    Text(l10n.tf("analyze.dup.group", members.count,
                                 ByteFormat.format(members.first?.size ?? 0)))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    ForEach(members) { member in
                        let isSelected = state.dupSelection.contains(member.path)
                        Button { state.toggleDupSelection(member) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: isSelected
                                      ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 13))
                                    .foregroundStyle(isSelected
                                        ? AnyShapeStyle(Color.moleAccentText) : AnyShapeStyle(.tertiary))
                                    .frame(width: 18)
                                Text(member.path)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Text(ByteFormat.format(member.size))
                                    .font(.system(size: 10).monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(MoleSelectableRowButtonStyle(
                            isSelected: isSelected,
                            cornerRadius: 6,
                            horizontalPadding: 10,
                            verticalPadding: 4))
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.surface2))
                .overlay(RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(.separator.opacity(0.4), lineWidth: 1))
            }
        }
    }
}

private struct AnalyzeRowView: View {
    let entry: AnalyzeEntry
    let isSelected: Bool
    let canSelect: Bool
    let onToggle: () -> Void
    let onOpen: () -> Void
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: onOpen) {
                HStack(spacing: 8) {
                    Image(systemName: rowIcon)
                        .font(.system(size: 11))
                        .foregroundStyle(iconStyle)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.name)
                            .font(.system(size: 12, weight: entry.isDir ? .medium : .regular))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text((entry.isPartial == true ? "≥ " : "") + ByteFormat.format(entry.size))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if canSelect {
                        Color.clear.frame(width: 24, height: 24)
                    } else {
                        Image(systemName: entry.isDir ? "chevron.right" : "arrow.up.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .frame(width: 18)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(MoleSelectableRowButtonStyle(isSelected: isSelected))

            if canSelect {
                Button(action: onToggle) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                }
                .buttonStyle(MoleIconButtonStyle(
                    isActive: isSelected,
                    tint: isSelected ? Color.moleAccentText : Color.secondary,
                    size: 24))
                .padding(.trailing, 3)
            }
        }
    }

    private var rowIcon: String { entry.isDir ? "folder" : "doc" }
    private var iconStyle: AnyShapeStyle { AnyShapeStyle(Color.moleAccentText) }
}
