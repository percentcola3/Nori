import AppKit
import QuickLook
import SwiftUI

/// 全盘扫描结果按 大文件 / 重复文件 / 视频 / 图片 聚焦展示。
/// 进入页面不主动扫描：空态是占位插画和分体扫描按钮。点选下拉类型立即扫描，
/// 主按钮再次扫描当前类型。不提供扫描范围选择与目录层级浏览。
struct AnalyzeTabView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expandedSections: Set<AnalyzeSection> = [.largeFiles, .videos, .images]
    @State private var previewURL: URL?
    @State private var showTrashConfirmation = false
    /// 大文件/视频删除的待确认清单（单行或批量）。
    @State private var pendingDeletePaths: [String]?
    /// 从磁盘分析行发起的“按目录定时清理”意图。
    @State private var autoCleanIntent: AutoCleanupIntent?
    @State private var scanMenuOpen = false

    private var scanning: Bool {
        state.isAnalyzing || state.isScanningDuplicates
    }

    private var hasResults: Bool {
        // 按当前分类判断空态，其他分类的结果不能挤掉本页的 SVG 占位。
        switch state.analyzeMode {
        case .largeFiles:
            return !state.analyzeLargeFiles.isEmpty
        case .videos:
            return state.analyzeMedia.contains { $0.kind == .video }
        case .images:
            return state.analyzeMedia.contains { $0.kind == .image }
        case .duplicates:
            return !state.duplicateGroups.isEmpty
        }
    }

    private var presentationPhase: Int {
        if scanning && !hasResults { return 1 }
        return hasResults ? 2 : 0
    }

    var body: some View {
        NoriPageTransition(phase: presentationPhase) {
        VStack(spacing: 0) {
            if hasResults { toolbar }
            if scanning && !hasResults {
                // 扫描中只保留 SVG 动画：下方展示当前正在分析的目录，
                // 取消按钮也在动画之下，工具栏不再出现。
                if state.isScanningDuplicates {
                    DuplicateScanActivity(progress: state.duplicateScanProgress,
                                          onCancel: state.cancelDuplicateScan)
                        } else {
                    NoriPlaceholderStage { size in
                        NoriStatusAnimation(mood: .working, size: size, assetName: "nori-disk")
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
                    }
            } else if !scanning && !hasResults {
                // 进入分析页不主动扫描：SVG 占位 + 带下拉面板的扫描按钮，
                // 面板里选择 大文件/图片/视频/重复文件 后按类型触发分析。
                NoriPlaceholderStage { size in
                    NoriIdlePlaceholder(state: state, size: size)
                    scanSplitButton
                }
            } else {
                ScrollView {
                    LiquidGlassGroup {
                    LazyVStack(spacing: 12) {
                        switch state.analyzeMode {
                        case .largeFiles, .videos:
                            // 大文件/视频：平铺删除清单，不套卡片。
                            let items = state.analysisFileItems(for: state.analyzeMode)
                            if items.isEmpty {
                                modeEmptyHint(state.analyzeMode.section ?? .largeFiles)
                            } else {
                                analysisFileSection(items)
                            }
                        case .images:
                            // 图片：唯一保留瘦身（降分辨率压缩）的分类。
                            let candidates = state.slimCandidates(in: .images)
                            if candidates.isEmpty {
                                modeEmptyHint(.images)
                            } else {
                                slimSectionCard(.images, candidates: candidates)
                            }
                        case .duplicates:
                            duplicatesCard
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                    // 扫描中清单持续增长，避免逐帧追赶尚未稳定的结果。
                    .animation(reduceMotion || scanning ? nil : MoleMotion.panel,
                               value: state.analyzeLargeFiles.map(\.path))
                    .animation(reduceMotion || scanning ? nil : MoleMotion.panel,
                               value: state.analyzeMode)
                    }
                }
            }

            if !scanning && hasResults {
                Divider()
                footer
            }
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
        .alert(l10n.tf("analyze.delete.confirm.title", pendingDeletePaths?.count ?? 0),
               isPresented: Binding(
                get: { pendingDeletePaths != nil },
                set: { if !$0 { pendingDeletePaths = nil } })) {
            Button(l10n.t("common.cancel"), role: .cancel) { pendingDeletePaths = nil }
            Button(l10n.t("analyze.delete.ok"), role: .destructive) {
                let paths = pendingDeletePaths ?? []
                pendingDeletePaths = nil
                state.deleteAnalysisFiles(paths)
            }
        } message: {
            Text(l10n.t("analyze.delete.confirm.msg"))
        }
        // 扫描中 → 结果/空态 的整块互换走弹簧过渡。
        .overlayPreferenceValue(ScanButtonAnchorKey.self) { anchor in
            scanMenuOverlay(anchor)
        }
    }

    private func toggleExpanded(_ section: AnalyzeSection) {
        withAnimation(reduceMotion ? nil : MoleMotion.panel) {
            if expandedSections.contains(section) { expandedSections.remove(section) }
            else { expandedSections.insert(section) }
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
    }

    // MARK: 大文件/视频平铺删除清单

    /// 不套卡片的全量平铺清单：行间细线分隔，每行勾选 + 定位 + 删除。
    private func analysisFileSection(_ items: [AnalysisFileItem]) -> some View {
        let section: AnalyzeSection = state.analyzeMode == .videos ? .videos : .largeFiles
        return VStack(spacing: 8) {
            Button { toggleExpanded(section) } label: {
                HStack(spacing: 8) {
                    Image(systemName: section.symbol).foregroundStyle(Color.moleAccentText)
                    Text(l10n.t(section.titleKey)).font(.system(size: 12, weight: .semibold))
                    Text("\(items.count)").font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    Text(ByteFormat.format(items.reduce(0) { $0 + $1.size }))
                        .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(expandedSections.contains(section) ? 0 : -90))
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .contentShape(Rectangle())
                .modifier(ListRowGlass())
            }
            .buttonStyle(MolePlainButtonStyle(pressedScale: 0.995))
            if expandedSections.contains(section) {
                analysisFileList(items).padding(.leading, 14).transition(.molePanelReveal)
            }
        }
        .clipped()
    }

    private func analysisFileList(_ items: [AnalysisFileItem]) -> some View {
        LazyVStack(spacing: 8) {
            ForEach(items) { item in analysisFileRow(item) }
        }
    }

    private func analysisFileRow(_ item: AnalysisFileItem) -> some View {
        let isSelected = state.analysisFileSelection.contains(item.path)
        return HStack(spacing: 10) {
            Button {
                state.toggleAnalysisFileSelection(item)
            } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? Color.moleAccentText : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(state.isBusy)
            Image(systemName: state.analyzeMode == .videos ? "film" : "doc")
                .font(.system(size: 12))
                .foregroundStyle(Color.moleAccentText)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(item.path)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(ByteFormat.format(item.size))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
            Button {
                state.revealPath(item.path)
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(MoleIconButtonStyle())
            .help(l10n.t("analyze.reveal"))
            Button {
                pendingDeletePaths = [item.path]
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(MoleIconButtonStyle(tint: Color.warning))
            .disabled(state.isBusy || state.isDeletingAnalysisFiles)
            .help(l10n.t("analyze.delete.one"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .modifier(ListRowGlass(selected: isSelected))
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
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    /// 主操作扫描当前类型；箭头打开菜单，选择类型后立即扫描。
    private var scanSplitButton: some View {
        AnalyzeScanSplitButton(
            title: l10n.t(state.analyzeMode.actionKey),
            menuOpen: scanMenuOpen,
            enabled: !state.isBusy,
            accessibilityMenu: l10n.t("analyze.scan.menu")
        ) {
            runSelectedScan()
        } onToggleMenu: {
            setScanMenuOpen(!scanMenuOpen)
        }
        .anchorPreference(key: ScanButtonAnchorKey.self, value: .bounds) { $0 }
    }

    @ViewBuilder
    private func scanMenuOverlay(_ anchor: Anchor<CGRect>?) -> some View {
        if scanMenuOpen, let anchor {
            GeometryReader { proxy in
                let frame = proxy[anchor]
                let width: CGFloat = 248
                let menuHeight: CGFloat = 180
                let x = min(max(12, frame.maxX - width), max(12, proxy.size.width - width - 12))
                let spaceBelow = proxy.size.height - frame.maxY
                let y = spaceBelow >= menuHeight + 12
                    ? frame.maxY + 8
                    : max(8, frame.minY - 8 - menuHeight)
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture { setScanMenuOpen(false) }
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
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                }
            }
        }
    }

    /// 点选类型即开始对应扫描，包括重新选择当前类型。
    private func chooseAnalyzeMode(_ mode: AnalyzeMode) {
        guard !state.isBusy else { return }
        state.analyzeMode = mode
        runSelectedScan()
    }

    private func setScanMenuOpen(_ open: Bool) {
        guard scanMenuOpen != open else { return }
        if reduceMotion {
            scanMenuOpen = open
        } else {
            withAnimation(MoleMotion.panel) { scanMenuOpen = open }
        }
    }

    /// 主按钮按当前类型开扫。重复文件做内容级比对；大文件、图片、视频
    /// 共享一次磁盘走查，结果按所选分类展示。
    private func runSelectedScan() {
        setScanMenuOpen(false)
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
                scanSplitButton
                Spacer()
                // 按当前模式分流：大文件/视频＝删除；重复文件＝清理；
                // 图片＝瘦身（唯一可降分辨率压缩的分类）。
                switch state.analyzeMode {
                case .largeFiles, .videos:
                    if !state.analysisFileSelectedItems.isEmpty {
                        Button {
                            pendingDeletePaths = state.analysisFileSelectedItems.map(\.path)
                        } label: {
                            Label(l10n.tf("analyze.delete.selected",
                                          state.analysisFileSelectedItems.count),
                                  systemImage: "trash.fill")
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .accessibilityValue(footerSummary)
                        .disabled(state.isBusy || state.isDeletingAnalysisFiles)
                    }
                case .duplicates:
                    if state.duplicateSelectedCount > 0 {
                        Button { showTrashConfirmation = true } label: {
                            Label(l10n.t("duplicates.trash"), systemImage: "trash.fill")
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .accessibilityValue(footerSummary)
                        .disabled(state.isBusy)
                    }
                case .images:
                    Button { state.requestSlim() } label: {
                        Label(l10n.t("slim.action"), systemImage: "arrow.down.right.and.arrow.up.left")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(state.slimSelectedCandidates.isEmpty || state.isBusy)
                }
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
        if !state.analysisFileSelectedItems.isEmpty {
            parts.append(l10n.tf("slim.footer.selected", state.analysisFileSelectedItems.count,
                                 ByteFormat.format(state.analysisFileSelectedBytes)))
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
                .fill(Color.hairline)
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
        .foregroundStyle(Color.primary)
        .modifier(ActionGlassChrome())
        .opacity(enabled ? 1 : 0.45)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: menuOpen)
    }
}

private struct SplitSegmentStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.65 : 1)
            .contentShape(Rectangle())
    }
}

/// 扫描类型面板：标题加说明，点选后立即执行对应扫描。
/// 选中态是液态玻璃透镜，在条目之间做 matchedGeometry 过渡；面板本身也是玻璃，
/// 不再铺实色底。
private struct AnalyzeScanMenu: View {
    let selection: AnalyzeMode
    let title: (AnalyzeMode) -> String
    let detail: (AnalyzeMode) -> String
    let onSelect: (AnalyzeMode) -> Void

    @Namespace private var selectionNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var menuShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
    }

    var body: some View {
        // 面板玻璃和选中透镜放在同一组里，合成成一块液态玻璃，而不是两层叠色。
        LiquidGlassGroup {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(AnalyzeMode.menuOrder) { mode in
                    Button { onSelect(mode) } label: {
                        scanRow(mode)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .modifier(ScanMenuChrome(reduceMotion: reduceMotion,
                                     reduceTransparency: reduceTransparency,
                                     shape: menuShape))
        }
        .shadow(color: .black.opacity(0.12), radius: 16, y: 8)
    }

    private func scanRow(_ mode: AnalyzeMode) -> some View {
        let selected = mode == selection
        return VStack(alignment: .leading, spacing: 1) {
            Text(title(mode))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
            Text(detail(mode))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.clear)
                    .matchedGeometryEffect(id: "scan-selection", in: selectionNamespace)
            }
        }
        .modifier(ScanSelectionGlass(selected: selected,
                                     id: mode.rawValue,
                                     namespace: selectionNamespace,
                                     reduceMotion: reduceMotion,
                                     reduceTransparency: reduceTransparency))
    }
}

/// 菜单玻璃必须包住内容。实色底会盖住折射，看起来就像玻璃没生效。
private struct ScanMenuChrome: ViewModifier {
    var reduceMotion: Bool
    var reduceTransparency: Bool
    var shape: RoundedRectangle
    @Environment(\.controlActiveState) private var controlActiveState

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !reduceTransparency, controlActiveState == .key {
            content
                .glassEffect(Glass.regular.interactive(!reduceMotion), in: shape)
                .clipGlassEdge(in: shape)
        } else {
            content.background(GlassSurface(cornerRadius: 14, usesSystemGlass: false))
        }
    }
}

/// 选中行的玻璃透镜。文字是 glassEffect 的内容，不能把玻璃垫在文字后面。
private struct ScanSelectionGlass: ViewModifier {
    var selected: Bool
    var id: String
    var namespace: Namespace.ID
    var reduceMotion: Bool
    var reduceTransparency: Bool
    @Environment(\.controlActiveState) private var controlActiveState

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !reduceTransparency, selected, controlActiveState == .key {
            content
                .glassEffect(
                    Glass.regular
                        .tint(Color.accent.opacity(0.22))
                        .interactive(!reduceMotion),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .glassEffectID(id, in: namespace)
                .glassEffectTransition(reduceMotion ? .identity : .matchedGeometry)
                .clipGlassEdge(in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else if selected {
            content.background(GlassSurface(cornerRadius: 8, usesSystemGlass: false,
                                             highlighted: true))
        } else {
            content
        }
    }
}
