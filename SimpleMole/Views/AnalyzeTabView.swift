import QuickLook
import SwiftUI

/// 全盘扫描结果：按 大文件 / 图片 / 视频 / 重复文件 四个子分类一页展示。
/// 不提供扫描范围选择与目录层级浏览；系统位置在扫描层就被排除，不再出现。
struct AnalyzeTabView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expandedSections: Set<AnalyzeSection> = []
    @State private var duplicatesExpanded = false
    @State private var previewURL: URL?
    @State private var showTrashConfirmation = false
    /// 从磁盘分析行发起的“按目录定时清理”意图。
    @State private var autoCleanIntent: AutoCleanupIntent?

    private var scanning: Bool {
        state.isAnalyzing || state.isScanningDuplicates
    }

    private var hasResults: Bool {
        !state.analyzeLargeFiles.isEmpty || !state.analyzeMedia.isEmpty
            || !state.duplicateGroups.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if state.isAnalyzing && !hasResults && state.duplicateGroups.isEmpty {
                // 扫描中只保留 SVG 动画：下方展示当前正在分析的目录，
                // 取消按钮也在动画之下，工具栏不再出现。
                VStack(spacing: 16) {
                    NoriStatusAnimation(mood: .working, size: 156, assetName: "nori-analyzing")
                    Text(displayCurrentPath)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 460)
                        .animation(nil, value: displayCurrentPath)
                    Button {
                        state.cancelAnalyze()
                    } label: {
                        Label(l10n.t("common.cancel"), systemImage: "xmark.circle")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .controlSize(.small)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(reduceMotion ? .opacity : .moleStateSwap)
            } else if !scanning && !hasResults {
                // 与其他页面的空态一致：用 Nori 的 SVG 动图占位，不重复“尚未分析”文案。
                // 未扫描时入口放在这里，工具栏不出现“重新扫描”。
                VStack(spacing: 12) {
                    NoriStatusAnimation(mood: .idle, size: 120, assetName: "nori-coffee")
                    Text(l10n.t("analyze.empty.subtitle"))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                    Button {
                        state.scanDiskOverview(force: true)
                    } label: {
                        Label(l10n.t("analyze.start"), systemImage: "magnifyingglass")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(state.isBusy)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(reduceMotion ? .opacity : .moleStateSwap)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if let section = state.analyzeMode.section {
                            // 聚焦模式：只渲染选中的子分类。
                            let candidates = state.slimCandidates(in: section)
                            if candidates.isEmpty {
                                modeEmptyHint(section)
                            } else {
                                slimSectionCard(section, candidates: candidates)
                            }
                        } else if state.analyzeMode == .duplicates {
                            duplicatesCard
                        } else {
                            // 整个磁盘：四个子分类一页展示。
                            ForEach(AnalyzeSection.allCases) { section in
                                let candidates = state.slimCandidates(in: section)
                                if !candidates.isEmpty {
                                    slimSectionCard(section, candidates: candidates)
                                }
                            }
                            duplicatesCard
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    // 扫描中清单持续增长，避免逐帧追赶尚未稳定的结果。
                    .animation(reduceMotion || scanning ? nil : MoleMotion.panel,
                               value: state.analyzeLargeFiles.map(\.path))
                    .animation(reduceMotion || scanning ? nil : MoleMotion.panel,
                               value: state.analyzeMode)
                }
                .transition(reduceMotion ? .opacity : .moleStateSwap)
            }

            if !state.isAnalyzing && (hasResults || state.isScanningDuplicates) {
                Divider()
                footer
            }
        }
        .sheet(isPresented: $state.showSlimSheet) {
            SlimOptionsSheet(state: state)
        }
        .sheet(item: $autoCleanIntent) { intent in
            AutoCleanupIntentSheet(state: state, intent: intent) {
                autoCleanIntent = nil
            }
        }
        .quickLookPreview($previewURL)
        .alert(l10n.tf("duplicates.trash.title", state.duplicateSelectedCount),
               isPresented: $showTrashConfirmation) {
            Button(l10n.t("common.cancel"), role: .cancel) {}
            Button(l10n.t("duplicates.trash"), role: .destructive) {
                state.deleteSelectedDuplicates()
            }
        } message: {
            Text(trashConfirmationMessage)
        }
        // 扫描中 → 结果/空态 的整块互换走弹簧过渡。
        .animation(reduceMotion ? nil : MoleMotion.panel, value: state.isAnalyzing)
        .animation(reduceMotion ? nil : MoleMotion.panel, value: hasResults)
    }

    private func toggleExpanded(_ section: AnalyzeSection) {
        if expandedSections.contains(section) {
            expandedSections.remove(section)
        } else {
            expandedSections.insert(section)
        }
    }

    private func slimSectionCard(_ section: AnalyzeSection,
                                 candidates: [SlimCandidate]) -> some View {
        SlimSectionCard(
            state: state,
            section: section,
            candidates: candidates,
            isExpanded: expandedSections.contains(section)) {
            toggleExpanded(section)
        } onScheduleDirectory: { directory in
            autoCleanIntent = AutoCleanupIntent(paths: [directory], cacheVerified: false)
        }
        .transition(.molePanelReveal)
    }

    private var duplicatesCard: some View {
        DuplicatesSectionCard(
            state: state,
            isExpanded: duplicatesExpanded,
            onToggleExpand: { duplicatesExpanded.toggle() },
            onPreview: { previewURL = URL(fileURLWithPath: $0) })
            .transition(.molePanelReveal)
    }

    /// 聚焦的分类暂无结果：轻量提示，不用整页空态（磁盘走查已经完成）。
    private func modeEmptyHint(_ section: AnalyzeSection) -> some View {
        HStack(spacing: 8) {
            Image(systemName: section.symbol)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Text(l10n.t("analyze.mode.empty"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.surface2))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.hairline, lineWidth: 1))
    }

    private var toolbar: some View {
        HStack(alignment: .center, spacing: 8) {
            // 分析类型下拉：默认整个磁盘；聚焦某个子分类时只展示并只跟进它。
            Picker(l10n.t("analyze.mode.overview"), selection: $state.analyzeMode) {
                Text(l10n.t("analyze.mode.overview")).tag(AnalyzeMode.overview)
                Text(l10n.t("analyze.section.largeFiles")).tag(AnalyzeMode.largeFiles)
                Text(l10n.t("analyze.section.images")).tag(AnalyzeMode.images)
                Text(l10n.t("analyze.section.videos")).tag(AnalyzeMode.videos)
                Text(l10n.t("analyze.section.duplicates")).tag(AnalyzeMode.duplicates)
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()
            .disabled(state.isBusy)
            if !scanning {
                Text(scanStatusText)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            // 扫描中的取消在动画下方；未扫描时入口在空态的“开始分析”。
            // 工具栏只在已有结果且空闲时提供“重新扫描”。
            if hasResults && !scanning {
                Button {
                    state.scanDiskOverview(force: true)
                } label: {
                    Label(l10n.t("analyze.scan"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(state.isBusy)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .onChange(of: state.analyzeMode) { mode in
            // 已有磁盘走查结果后切入重复文件：自动跟进一次内容级比对，
            // 与“整个磁盘”模式扫描完成后的行为保持一致。
            guard mode == .duplicates, hasResults,
                  !state.isBusy, !state.isScanningDuplicates,
                  !state.duplicateScanFinished else { return }
            state.scanDuplicateFiles()
        }
    }

    private var scanStatusText: String {
        if state.isAnalyzing { return state.analyzeStatus }
        if state.isScanningDuplicates { return state.duplicateStatus }
        return state.analyzeStatus
    }

    /// 扫描中展示的当前目录：主目录缩写为 ~；尚未回报路径时退化为扫描文案。
    private var displayCurrentPath: String {
        guard !state.analyzeCurrentPath.isEmpty else {
            return l10n.t("analyze.scanning")
        }
        let home = NSHomeDirectory()
        return state.analyzeCurrentPath.hasPrefix(home)
            ? "~" + state.analyzeCurrentPath.dropFirst(home.count)
            : state.analyzeCurrentPath
    }

    private var footer: some View {
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
                Text(footerSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                if state.duplicateSelectedCount > 0 {
                    Button { showTrashConfirmation = true } label: {
                        Label(l10n.t("duplicates.trash"), systemImage: "trash")
                    }
                    .buttonStyle(DangerButtonStyle())
                    .disabled(state.isBusy)
                }
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

    private var footerSummary: String {
        var parts: [String] = []
        if !state.slimSelectedCandidates.isEmpty {
            parts.append(l10n.tf("slim.footer.selected", state.slimSelectedCandidates.count,
                                 ByteFormat.format(state.slimSelectedBytes)))
        }
        if state.duplicateSelectedCount > 0 {
            parts.append(l10n.tf("duplicates.selection.count", state.duplicateSelectedCount,
                                 ByteFormat.format(state.duplicateSelectedBytes)))
        }
        return parts.isEmpty ? l10n.t("slim.footer.hint") : parts.joined(separator: " · ")
    }

    private var trashConfirmationMessage: String {
        let selection = l10n.tf("duplicates.selection.count", state.duplicateSelectedCount,
                                ByteFormat.format(state.duplicateSelectedBytes))
        let explanation = l10n.t(state.duplicateMode == .exact
                                 ? "duplicates.trash.message" : "duplicates.trash.similarMessage")
        return selection + "\n\n" + explanation
    }
}
