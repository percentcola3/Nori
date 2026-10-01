import AppKit
import QuickLook
import SwiftUI

/// 全盘扫描结果按 大文件 / 重复文件 / 视频 / 图片 聚焦展示。
/// 进入页面不主动扫描：空态是占位插画和分体扫描按钮。下拉只改待执行的类型，
/// 主按钮才开始对应扫描。不提供扫描范围选择与目录层级浏览。
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
    @State private var scanMenuOpen = false

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
                // 进入分析页不主动扫描：SVG 占位 + 带下拉面板的扫描按钮，
                // 面板里选择 大文件/图片/视频/重复文件 后按类型触发分析。
                VStack(spacing: 18) {
                    NoriStatusAnimation(mood: .idle, size: 120, assetName: "nori-coffee")
                    scanSplitButton
                    Text(l10n.t(state.analyzeMode.detailKey))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
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
                        } else {
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
        .overlayPreferenceValue(ScanButtonAnchorKey.self) { anchor in
            scanMenuOverlay(anchor)
        }
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
            if !scanning {
                Text(scanStatusText)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            // 已有结果后工具栏提供同款下拉扫描按钮；未扫描的入口在空态。
            if hasResults && !scanning {
                scanSplitButton
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    /// 主操作 + 下拉箭头。箭头只改待扫描类型，主区域才开始这一类扫描。
    private var scanSplitButton: some View {
        AnalyzeScanSplitButton(
            title: l10n.t(state.analyzeMode.actionKey),
            menuOpen: scanMenuOpen,
            enabled: !state.isBusy,
            accessibilityMenu: l10n.t("analyze.scan.menu")
        ) {
            runSelectedScan()
        } onToggleMenu: {
            scanMenuOpen.toggle()
        }
        .anchorPreference(key: ScanButtonAnchorKey.self, value: .bounds) { $0 }
    }

    @ViewBuilder
    private func scanMenuOverlay(_ anchor: Anchor<CGRect>?) -> some View {
        if scanMenuOpen, let anchor {
            GeometryReader { proxy in
                let frame = proxy[anchor]
                let width: CGFloat = 336
                let menuHeight: CGFloat = 292
                let x = min(max(12, frame.maxX - width), max(12, proxy.size.width - width - 12))
                let spaceBelow = proxy.size.height - frame.maxY
                let y = spaceBelow >= menuHeight + 12
                    ? frame.maxY + 8
                    : max(8, frame.minY - 8 - menuHeight)
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture { scanMenuOpen = false }
                    AnalyzeScanMenu(
                        selection: state.analyzeMode,
                        title: { l10n.t($0.titleKey) },
                        detail: { l10n.t($0.detailKey) }
                    ) { mode in
                        chooseAnalyzeMode(mode)
                    }
                    .frame(width: width, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .offset(x: x, y: y)
                }
            }
        }
    }

    /// 下拉只切换待执行的扫描，不开始遍历。
    private func chooseAnalyzeMode(_ mode: AnalyzeMode) {
        state.analyzeMode = mode
        scanMenuOpen = false
    }

    /// 主按钮按当前类型开扫。重复文件做内容级比对；大文件、图片、视频
    /// 共享一次磁盘走查，结果按所选分类展示。
    private func runSelectedScan() {
        scanMenuOpen = false
        switch state.analyzeMode {
        case .duplicates:
            guard !state.isBusy, !state.isScanningDuplicates else { return }
            state.scanDuplicateFiles()
        case .largeFiles, .images, .videos:
            guard !scanning else { return }
            state.scanDiskOverview(force: true)
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

private struct ScanButtonAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

/// 主操作 + 下拉箭头的胶囊按钮。箭头只打开选项，主区域才开始扫描。
private struct AnalyzeScanSplitButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    let menuOpen: Bool
    let enabled: Bool
    let accessibilityMenu: String
    let onPrimary: () -> Void
    let onToggleMenu: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onPrimary) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 16)
                    .frame(minWidth: 132, minHeight: 34)
            }
            .buttonStyle(SplitSegmentStyle())
            .disabled(!enabled)

            Rectangle()
                .fill(Color.moleOnAccent.opacity(0.28))
                .frame(width: 1, height: 18)

            Button(action: onToggleMenu) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 36, height: 34)
                    .rotationEffect(.degrees(menuOpen ? 180 : 0))
            }
            .buttonStyle(SplitSegmentStyle())
            .disabled(!enabled)
            .accessibilityLabel(accessibilityMenu)
        }
        .foregroundStyle(Color.moleOnAccent)
        .background(Capsule().fill(Color.moleAccent))
        .clipShape(Capsule())
        .opacity(enabled ? 1 : 0.45)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: menuOpen)
    }
}

private struct SplitSegmentStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.white.opacity(configuration.isPressed ? 0.16 : 0))
            .contentShape(Rectangle())
    }
}

/// 扫描类型面板：标题加说明。点选只改变主按钮将要执行的扫描。
private struct AnalyzeScanMenu: View {
    let selection: AnalyzeMode
    let title: (AnalyzeMode) -> String
    let detail: (AnalyzeMode) -> String
    let onSelect: (AnalyzeMode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(AnalyzeMode.menuOrder) { mode in
                Button { onSelect(mode) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title(mode))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(detail(mode))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(mode == selection
                                  ? Color.moleAccent.opacity(0.14)
                                  : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(menuFill)
                .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.hairline, lineWidth: 1)
        )
    }

    private var menuFill: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(srgbRed: 0.16, green: 0.18, blue: 0.22, alpha: 1)
                : NSColor.white
        })
    }
}
