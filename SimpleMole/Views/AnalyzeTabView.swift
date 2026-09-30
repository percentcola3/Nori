import SwiftUI

/// 从当前目录逐层浏览实际磁盘占用。
struct AnalyzeTabView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var l10n = L10n.shared
    /// 从分析结果目录发起的自动清理规则创建。
    @State private var autoCleanIntent: AutoCleanupIntent?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            // 标题、当前状态与扫描操作共用一行；状态与提示按剩余宽度截断。
            HStack(alignment: .center, spacing: 8) {
                if state.analyzePath != "/" {
                    Button { state.analyzeGoUp() } label: {
                        Label(l10n.t("analyze.up"), systemImage: "chevron.left")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .labelStyle(.iconOnly)
                    .disabled(state.isBusy)
                }
                Text(scopeTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                if state.isAnalyzing { ProgressView().controlSize(.mini) }
                Text(state.analyzeStatus)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Button { state.scanDuplicates() } label: {
                    Label(l10n.t("duplicates.entry"), systemImage: "square.on.square.dashed")
                }
                .buttonStyle(SecondaryButtonStyle())
                .labelStyle(.iconOnly)
                .controlSize(.small)
                .disabled(state.isBusy)
                if state.analyzeMode == .directories {
                    Text(l10n.t("analyze.directory.hint"))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Menu {
                    Button { state.scanAnalyze(NSHomeDirectory()) } label: {
                        Label(l10n.t("analyze.scope.user"), systemImage: "person.crop.circle")
                    }
                    Button { state.scanAnalyze("/") } label: {
                        Label(l10n.t("analyze.scope.root"), systemImage: "internaldrive")
                    }
                    Button { state.chooseAnalyzeFolder() } label: {
                        Label(l10n.t("analyze.scope.custom"), systemImage: "folder")
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
            .padding(.bottom, 8)
            .onAppear { state.scanUserSpace() }

            if state.isAnalyzing, !state.analyzeCurrentPath.isEmpty {
                Text(state.analyzeCurrentPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
            }

            if state.isAnalyzing && state.analyzeEntries.isEmpty {
                VStack(spacing: 12) {
                    NoriStatusAnimation(mood: .working, size: 156, assetName: "nori-analyzing")
                    ProgressView().controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(reduceMotion ? .opacity : .moleStateSwap)
            } else if state.analyzeEntries.isEmpty {
                EmptyStateView(symbol: "chart.bar.doc.horizontal",
                               title: l10n.t("analyze.status.empty"),
                               subtitle: l10n.t("analyze.empty.subtitle"))
                .transition(reduceMotion ? .opacity : .moleStateSwap)
            } else if !state.isAnalyzing && state.analyzeMode != .directories {
                AnalyzeModePicker(state: state)
                    .padding(.bottom, 8)
                SlimCandidateListView(state: state)
                .transition(reduceMotion ? .opacity : .moleStateSwap)
            } else {
                if !state.isAnalyzing {
                    AnalyzeModePicker(state: state)
                        .padding(.bottom, 4)
                }
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
                        if state.snapshotsScanned && !state.isAnalyzing {
                            snapshotsSection
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    // 扫描中频繁更新大小与排序，避免逐帧追赶尚未稳定的结果。
                    .animation(reduceMotion || state.isAnalyzing ? nil : MoleMotion.panel,
                               value: state.analyzeEntries.map(\.path))
                }
                .transition(reduceMotion ? .opacity : .moleStateSwap)
            }

            if state.analyzeMode != .directories && !state.isAnalyzing
                && !state.analyzeEntries.isEmpty {
                Divider()
                slimFooter
            } else if !state.isAnalyzing && !state.analyzeEntries.isEmpty {
                Divider()
                HStack {
                    if let footerText {
                        Text(footerText)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { state.applyAnalyzeCleanup() } label: {
                        Label(l10n.t("analyze.apply"), systemImage: "trash.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(state.analyzeSelection.isEmpty
                              || state.isBusy)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
        .sheet(isPresented: $state.showDuplicateFiles) {
            DuplicateFilesView(state: state)
        }
        .sheet(isPresented: $state.showSlimSheet) {
            SlimOptionsSheet(state: state)
        }
        .sheet(item: $autoCleanIntent) { intent in
            AutoCleanupIntentSheet(state: state, intent: intent) {
                autoCleanIntent = nil
            }
        }
        // 分析中 → 结果/空态 的整块互换走弹簧过渡。
        .animation(reduceMotion ? nil : MoleMotion.panel, value: state.isAnalyzing)
        .animation(reduceMotion ? nil : MoleMotion.panel, value: state.analyzeEntries.isEmpty)
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

    private var slimFooter: some View {
        HStack(spacing: 8) {
            if let progress = state.slimProgress {
                ProgressView(value: progress.fraction ?? 0)
                    .progressViewStyle(.linear)
                    .frame(width: 80)
                    .opacity(progress.fraction == nil ? 0.35 : 1)
                Text(l10n.tf("slim.progress", progress.index, progress.total, progress.name))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button(l10n.t("common.cancel")) { state.cancelSlim() }
                    .buttonStyle(SecondaryButtonStyle())
            } else {
                Text(state.slimSelection.isEmpty
                     ? l10n.t("slim.footer.hint")
                     : l10n.tf("slim.footer.selected", state.slimSelectedCandidates.count,
                               ByteFormat.format(state.slimSelectedBytes)))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button { state.requestSlim() } label: {
                    Label(l10n.t("slim.action"), systemImage: "arrow.down.right.and.arrow.up.left")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(state.slimSelectedCandidates.isEmpty || state.isBusy)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var snapshotsSection: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 11))
                .foregroundStyle(Color.moleAccentText)
                .accessibilityLabel(l10n.t("analyze.snapshots"))
                .accessibilityValue(l10n.tf("analyze.snapshotCount", state.localSnapshots.count))
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

    private var footerText: String? {
        guard !state.analyzeSelection.isEmpty else { return nil }
        return l10n.tf("analyze.selected", state.analyzeSelection.count,
                       ByteFormat.format(state.analyzeSelectedBytes))
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
