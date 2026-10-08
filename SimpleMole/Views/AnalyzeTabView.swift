import AppKit
import QuickLook
import SwiftUI

/// 每类独立扫描并保留结果；侧边栏切换只改变展示，不启动扫描。
struct AnalyzeTabView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var l10n = L10n.shared
    @State private var previewURL: URL?
    @State private var showTrashConfirmation = false
    @State private var pendingDeletion: AnalysisDeletionRequest?

    private var mode: AnalyzeMode { state.analyzeMode }
    private var scanning: Bool {
        mode == .duplicates ? state.isScanningDuplicates : state.analyzingMode == mode
    }
    private var fullScanning: Bool { scanning && state.analysisScanIsFull }
    private var scanned: Bool { state.analysisHasScanned(mode) }
    private var hasResults: Bool { resultCount(mode) > 0 }
    private var hasSelectableResults: Bool {
        mode == .disk ? !state.analysisFileItems(for: .disk).isEmpty : hasResults
    }
    private var selectedCount: Int {
        mode == .duplicates ? state.duplicateSelectedCount : state.analysisFileSelectedItems.count
    }
    private var selectedBytes: UInt64 {
        mode == .duplicates ? state.duplicateSelectedBytes : state.analysisFileSelectedBytes
    }
    private var allSelected: Bool {
        guard hasResults, selectedCount > 0 else { return false }
        if mode == .duplicates {
            return state.duplicateGroups.allSatisfy { group in
                group.members.lazy.filter { !state.duplicateSelection.contains($0.path) }.count == 1
            }
        }
        return selectedCount == state.analysisFileItems(for: mode).count
    }
    private var selectedSize: String {
        let gigabytes = Double(selectedBytes) / 1_000_000_000
        let number = (gigabytes > 0 && gigabytes < 0.01 ? 0.01 : gigabytes)
            .formatted(.number.precision(.fractionLength(2)))
        return (gigabytes > 0 && gigabytes < 0.01 ? "< " : "") + number + " GB"
    }
    private var deletionConfirmationMessage: String {
        guard let request = pendingDeletion else { return l10n.t("analyze.delete.confirm.msg") }
        let home = request.mode == .disk ? state.diskBrowserHomePath : NSHomeDirectory()
        return l10n.t(AnalysisFileDeletionPlan.requiresPermanentDeletion(paths: request.paths, homeDirectory: home)
            ? "analyze.delete.confirm.cache" : "analyze.delete.confirm.msg")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            AnalyzeSidebar(selection: $state.analyzeMode, details: sidebarDetails,
                           scanningMode: state.isScanningDuplicates ? .duplicates : state.analyzingMode,
                           isSearching: state.isIncrementalAnalysisScanning)
                .frame(width: 120).padding(.leading, 10).padding(.vertical, 14)
            VStack(spacing: 0) {
                header
                NoriPageTransition(phase: fullScanning ? 1 : scanned ? 2 : 0) { content }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if (hasResults || scanned) && !fullScanning { footer }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentPanel()
            .padding(EdgeInsets(top: 12, leading: 10, bottom: 12, trailing: 12))
        }
        .frame(maxHeight: .infinity)
        .sheet(isPresented: $state.showSlimSheet) { SlimOptionsSheet(state: state) }
        .quickLookPreview($previewURL)
        .alert(l10n.tf("duplicates.trash.title", state.duplicateSelectedCount),
               isPresented: $showTrashConfirmation) {
            Button(l10n.t("common.cancel"), role: .cancel) {}
            Button(l10n.t("duplicates.trash"), role: .destructive) { state.deleteSelectedDuplicates() }
        } message: { Text(trashConfirmationMessage) }
        .alert(l10n.tf("analyze.delete.confirm.title", pendingDeletion?.paths.count ?? 0),
               isPresented: Binding(get: { pendingDeletion != nil },
                                    set: { if !$0 { pendingDeletion = nil } })) {
            Button(l10n.t("common.cancel"), role: .cancel) { pendingDeletion = nil }
            Button(l10n.t("analyze.delete.ok"), role: .destructive) {
                if let request = pendingDeletion {
                    pendingDeletion = nil
                    state.deleteAnalysisFiles(request.paths, mode: request.mode)
                }
            }
        } message: { Text(deletionConfirmationMessage) }
        .accessibilityIdentifier("analysis-workspace")
    }

    @ViewBuilder private var header: some View {
        if mode == .duplicates, !fullScanning, !state.duplicateGroups.isEmpty {
            let similarCount = state.duplicateGroups.reduce(0) { $0 + ($1.kind == .similarImages ? 1 : 0) }
            Text(l10n.tf("duplicates.summary.merged", state.duplicateGroups.count - similarCount,
                         ByteFormat.format(state.duplicateReclaimableBytes), similarCount))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
                .accessibilityIdentifier("analysis-duplicate-summary")
        }
    }

    @ViewBuilder private var content: some View {
        if fullScanning {
            if mode == .duplicates {
                DuplicateScanActivity(progress: state.duplicateScanProgress, onCancel: state.cancelDuplicateScan)
            } else {
                NoriPlaceholderStage { size in
                    NoriStatusAnimation(mood: .working, size: size, assetName: "nori-disk")
                    Text(state.analysisStatus(for: mode)).font(.system(size: 11))
                        .foregroundStyle(.secondary).lineLimit(1)
                    Text(abbreviate(state.analyzeCurrentPath)).font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).frame(maxWidth: 420)
                    Button(action: cancelScan) {
                        Label(l10n.t("common.cancel"), systemImage: "xmark.circle")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("analysis-full-scan-cancel")
                }
            }
        } else if !hasResults {
            NoriPlaceholderStage { size in
                NoriIdlePlaceholder(state: state, size: size)
                if scanned {
                    Text(l10n.t("analyze.scan.empty"))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                if !scanned { scanButton }
            }
        } else if mode == .disk {
            DiskBrowserView(state: state, scanning: scanning,
                            onPreview: { previewURL = URL(fileURLWithPath: $0) })
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    if mode == .duplicates {
                        DuplicatesSectionCard(state: state,
                            onPreview: { previewURL = URL(fileURLWithPath: $0) }, showsControls: false)
                    } else {
                        ForEach(state.analysisFileItems(for: mode)) { item in analysisFileRow(item) }
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
            }
            .accessibilityIdentifier("analysis-results-" + mode.rawValue)
        }
    }

    private func analysisFileRow(_ item: AnalysisFileItem) -> some View {
        let selected = state.analysisSelection(for: mode).contains(item.path)
        return HStack(spacing: 8) {
            Button { state.toggleAnalysisFileSelection(item) } label: {
                HStack(spacing: 10) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14)).foregroundStyle(selected ? Color.moleAccentText : Color.secondary)
                    if mode == .images {
                        MediaThumbnail(path: item.path, size: item.size, kind: .image)
                    } else {
                        Image(systemName: mode.symbol).font(.system(size: 14))
                            .foregroundStyle(Color.moleAccentText).frame(width: 26)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text(abbreviate(item.path)).font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(ByteFormat.format(item.size)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(MolePlainButtonStyle(pressedScale: 0.99))
            .disabled(state.isAnalysisTaskBusy || scanning)
            .opacity(state.isAnalysisTaskBusy || scanning ? 0.45 : 1)
            .accessibilityLabel(item.path)
            .accessibilityValue(l10n.t(selected ? "duplicates.row.selected" : "duplicates.row.kept"))
            Button { previewURL = URL(fileURLWithPath: item.path) } label: { Image(systemName: "eye") }
                .buttonStyle(MoleIconButtonStyle(size: 26, showsBackground: false))
                .help(l10n.t("duplicates.preview"))
                .accessibilityLabel(l10n.t("duplicates.preview") + ": " + item.name)
            Button { state.revealPath(item.path) } label: { Image(systemName: "folder") }
                .buttonStyle(MoleIconButtonStyle(size: 26, showsBackground: false))
                .help(l10n.t("analyze.reveal"))
                .accessibilityLabel(l10n.t("analyze.reveal") + ": " + item.name)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .modifier(ListRowSurface(selected: selected))
        .accessibilityIdentifier("analysis-file-" + item.path)
    }

    private var scanButton: some View {
        Button { state.scanAnalysisMode(mode, forceFull: true) } label: {
            Label(l10n.t(mode.actionKey), systemImage: "magnifyingglass")
        }
        .buttonStyle(PrimaryButtonStyle(tint: .moleAccent))
        .disabled(state.isAnalysisTaskBusy || state.isAnalyzing || state.isScanningDuplicates)
        .accessibilityIdentifier("analysis-scan-" + mode.rawValue)
    }

    private var rescanButton: some View {
        Button { state.scanAnalysisMode(mode, forceFull: true) } label: {
            Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(AnalysisIconButtonStyle())
        .disabled(state.isAnalysisTaskBusy || state.isAnalyzing || state.isScanningDuplicates)
        .help(l10n.t("analyze.scan.full"))
        .accessibilityLabel(l10n.t("analyze.scan.full"))
        .accessibilityIdentifier("analysis-scan-" + mode.rawValue)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            Divider()
            if let progress = state.slimProgress {
                HStack(spacing: 10) {
                    ProgressView(value: progress.fraction ?? 0).frame(width: 100)
                    Text(l10n.tf("slim.progress", progress.index, progress.total, progress.name))
                        .font(.system(size: 11)).lineLimit(1)
                    Spacer()
                    Button { state.cancelSlim() } label: { Image(systemName: "xmark") }
                        .buttonStyle(AnalysisIconButtonStyle())
                        .help(l10n.t("common.cancel"))
                        .accessibilityLabel(l10n.t("common.cancel"))
                }
            } else {
                HStack(spacing: 8) {
                    AnalysisSelectionButtons(
                        allSelected: allSelected,
                        noneSelected: hasSelectableResults && selectedCount == 0,
                        canSelectAll: hasSelectableResults && !state.isAnalysisTaskBusy && !scanning,
                        canDeselectAll: selectedCount > 0 && !state.isAnalysisTaskBusy && !scanning,
                        onSelectAll: selectAll, onDeselectAll: deselectAll)
                    Spacer(minLength: 8)
                    if mode == .images {
                        Button {
                            state.slimSelection = state.analysisSelection(for: .images)
                            state.requestSlim()
                        } label: {
                            Label(l10n.t("slim.action"), systemImage: "arrow.down.right.and.arrow.up.left")
                        }
                        .buttonStyle(AnalysisActionButtonStyle(tint: .moleAccentText))
                        .disabled(selectedCount == 0 || state.isAnalysisTaskBusy || scanning)
                    }
                    if scanning {
                        Button { cancelScan() } label: { Image(systemName: "xmark") }
                            .buttonStyle(AnalysisIconButtonStyle())
                            .help(l10n.t("common.cancel"))
                            .accessibilityLabel(l10n.t("common.cancel"))
                    } else {
                        rescanButton
                    }
                    Button(role: .destructive) {
                        if mode == .duplicates { showTrashConfirmation = true }
                        else { pendingDeletion = AnalysisDeletionRequest(mode: mode,
                            paths: state.analysisFileSelectedItems.map(\.path)) }
                    } label: {
                        Label(l10n.tf("cleanup.delete.withCount", selectedSize), systemImage: "trash")
                            .monospacedDigit()
                    }
                    .buttonStyle(AnalysisActionButtonStyle(tint: .danger))
                    .disabled(selectedCount == 0 || state.isAnalysisTaskBusy || scanning)
                    .accessibilityIdentifier("analysis-clean-selected")
                }
            }
        }
        .padding(.horizontal, 8).padding(.bottom, 2)
    }

    private var sidebarDetails: [AnalyzeMode: String] {
        Dictionary(uniqueKeysWithValues: AnalyzeMode.menuOrder.map { item in
            (item, state.analysisHasScanned(item)
                ? l10n.tf("analyze.sidebar.count", resultCount(item)) : l10n.t("analyze.scan.never"))
        })
    }
    private func resultCount(_ item: AnalyzeMode) -> Int {
        if item == .disk { return state.diskBrowserEntries(at: state.diskBrowserRootPath).count }
        return item == .duplicates ? state.duplicateGroups.count : state.analysisFileItems(for: item).count
    }
    private func selectAll() {
        if mode == .duplicates { state.selectAllDuplicates() } else { state.selectAllAnalysisFiles() }
    }
    private func deselectAll() {
        if mode == .duplicates { state.deselectAllDuplicates() } else { state.deselectAllAnalysisFiles() }
    }
    private func cancelScan() {
        if mode == .duplicates { state.cancelDuplicateScan() } else { state.cancelAnalyze() }
    }
    private func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
    private var trashConfirmationMessage: String {
        l10n.tf("duplicates.selection.count", state.duplicateSelectedCount,
                ByteFormat.format(state.duplicateSelectedBytes)) + "\n\n"
            + l10n.t(state.duplicateSelectionIncludesSimilar ? "duplicates.trash.similarMessage" : "duplicates.trash.message")
    }
}

private struct AnalysisSelectionButtons: View {
    let allSelected: Bool
    let noneSelected: Bool
    let canSelectAll: Bool
    let canDeselectAll: Bool
    let onSelectAll: () -> Void
    let onDeselectAll: () -> Void
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onSelectAll) { AnalysisSelectionGlyph(checkmark: true) }
                .buttonStyle(AnalysisSelectionButtonStyle(isActive: allSelected))
                .disabled(!canSelectAll)
                .help(l10n.t("analyze.selection.all"))
                .accessibilityLabel(l10n.t("analyze.selection.all"))
                .accessibilityAddTraits(allSelected ? .isSelected : [])
                .accessibilityRemoveTraits(allSelected ? [] : .isSelected)
                .accessibilityIdentifier("analysis-select-all")
            Button(action: onDeselectAll) { AnalysisSelectionGlyph(checkmark: false) }
                .buttonStyle(AnalysisSelectionButtonStyle(isActive: noneSelected))
                .disabled(!canDeselectAll)
                .help(l10n.t("analyze.selection.none"))
                .accessibilityLabel(l10n.t("analyze.selection.none"))
                .accessibilityAddTraits(noneSelected ? .isSelected : [])
                .accessibilityRemoveTraits(noneSelected ? [] : .isSelected)
                .accessibilityIdentifier("analysis-deselect-all")
        }
    }
}

private struct AnalysisSelectionGlyph: View {
    let checkmark: Bool

    var body: some View {
        ZStack {
            Circle().strokeBorder(lineWidth: 1.35)
            AnalysisSelectionMark(checkmark: checkmark)
                .stroke(style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                .frame(width: 12, height: 12)
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }
}

private struct AnalysisSelectionMark: Shape {
    let checkmark: Bool

    func path(in rect: CGRect) -> Path {
        Path { path in
            if checkmark {
                path.move(to: CGPoint(x: rect.minX + rect.width * 0.12, y: rect.minY + rect.height * 0.53))
                path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.39, y: rect.minY + rect.height * 0.79))
                path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.88, y: rect.minY + rect.height * 0.22))
            } else {
                path.move(to: CGPoint(x: rect.minX + rect.width * 0.15, y: rect.midY))
                path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.85, y: rect.midY))
            }
        }
    }
}

private struct AnalysisSelectionButtonStyle: ButtonStyle {
    let isActive: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    private var shape: Circle { Circle() }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isActive ? Color.moleAccentText
                : isEnabled && (isHovering || configuration.isPressed) ? Color.primary : Color.secondary)
            .frame(width: 32, height: 32)
            .background {
                if isEnabled && (isHovering || configuration.isPressed) {
                    Circle().fill(Color.surface2)
                }
            }
            .contentShape(shape)
            .opacity(isEnabled ? 1 : isActive ? 0.75 : 0.4)
            .scaleEffect(reduceMotion || !isEnabled || !configuration.isPressed ? 1 : 0.94)
            .onHover { isHovering = $0 }
            .animation(reduceMotion ? nil : MoleMotion.press, value: configuration.isPressed)
            .animation(reduceMotion ? nil : MoleMotion.hover, value: isHovering)
            .animation(reduceMotion ? nil : MoleMotion.selection, value: isActive)
    }
}

private struct AnalysisIconButtonStyle: ButtonStyle {
    var quiet = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        Group {
            if quiet {
                icon(configuration)
            } else {
                icon(configuration)
                    .background(Capsule().fill(Color.surface2))
            }
        }
        .opacity(isEnabled ? 1 : 0.5)
        .scaleEffect(reduceMotion || !configuration.isPressed ? 1 : 0.96)
        .animation(reduceMotion ? nil : MoleMotion.press, value: configuration.isPressed)
    }

    private func icon(_ configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(quiet ? Color.secondary : isEnabled ? Color.primary : Color.secondary)
            .frame(width: 28, height: 28)
            .contentShape(Capsule())
    }
}

private struct AnalysisActionButtonStyle: ButtonStyle {
    let tint: Color
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isEnabled ? tint : Color.secondary)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .contentShape(Capsule())
            .modifier(ActionGlassChrome(tint: isEnabled ? tint : nil))
            .opacity(isEnabled ? 1 : 0.45)
            .modifier(MoleButtonFeedbackModifier(isPressed: configuration.isPressed))
    }
}

private struct AnalysisDeletionRequest {
    let mode: AnalyzeMode
    let paths: [String]
}

extension AnalyzeMode {
    var symbol: String {
        switch self {
        case .disk: return "internaldrive"
        case .duplicates: return "square.on.square"
        case .largeFiles: return "doc.zipper"
        case .images: return "photo"
        case .videos: return "film"
        }
    }
}

private struct AnalyzeSidebar: View {
    @Binding var selection: AnalyzeMode
    let details: [AnalyzeMode: String]
    let scanningMode: AnalyzeMode?
    let isSearching: Bool
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var namespace

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LiquidGlassGroup {
                VStack(spacing: 3) {
                    ForEach(AnalyzeMode.menuOrder) { item in
                        Button { selection = item } label: {
                            HStack(spacing: 6) {
                                Image(systemName: item.symbol).font(.system(size: 13, weight: .medium)).frame(width: 16)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(l10n.t(item.titleKey))
                                        .font(.system(size: 12, weight: selection == item ? .semibold : .medium))
                                        .lineLimit(1).minimumScaleFactor(0.85)
                                    Text(scanningMode == item ? l10n.t("analyze.scanning") : details[item] ?? "")
                                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                                        .minimumScaleFactor(0.85)
                                }
                                Spacer(minLength: 0)
                                if scanningMode == item { ProgressView().controlSize(.mini) }
                            }
                            .padding(.horizontal, 6).padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(RoundedRectangle(cornerRadius: 10))
                            .modifier(SidebarSelectionLens(selected: selection == item,
                                id: "analysis-selection", namespace: namespace))
                        }
                        .buttonStyle(MolePlainButtonStyle(pressedScale: 0.98))
                        .accessibilityAddTraits(selection == item ? .isSelected : [])
                        .accessibilityIdentifier("analysis-section-" + item.rawValue)
                    }
                }
            }
            Spacer(minLength: 0)
            if isSearching {
                HStack(spacing: 0) {
                    NoriStatusAnimation(mood: .working, size: 36, assetName: "nori-working")
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(l10n.t("analyze.scanning"))
                .accessibilityIdentifier("analysis-search-activity")
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .animation(reduceMotion ? nil : MoleMotion.selection, value: selection)
        .accessibilityIdentifier("analysis-sidebar")
    }
}
