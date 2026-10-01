import AppKit
import SwiftUI

/// 从当前目录逐层浏览实际磁盘占用。
struct AnalyzeTabView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var savedLocations: SavedScanLocationStore
    @ObservedObject private var l10n = L10n.shared

    init(state: AppState) {
        self.state = state
        self.savedLocations = state.savedScanLocations
    }

    @State private var scanMenuOpen = false

    var body: some View {
        pageContent
            .overlayPreferenceValue(ScanButtonAnchorKey.self) { anchor in
                scanMenuOverlay(anchor)
            }
    }

    private var pageContent: some View {
        VStack(spacing: 0) {
            header
            if !showsPlaceholder {
                statusRow
            }
            content
            footer
        }
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
        }
    }

    private var header: some View {
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
            advancedMenu
            if !showsPlaceholder {
                scanSplitButton
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    private var advancedMenu: some View {
        Menu {
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
    }

    private var statusRow: some View {
        HStack(spacing: 6) {
            if isCurrentFocusRunning { ProgressView().controlSize(.mini) }
            Text(focusStatus)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if state.analyzeFocus == .largeFiles {
                Text(l10n.t("analyze.directory.hint"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var content: some View {
        if showsPlaceholder {
            placeholder
        } else if isCurrentFocusRunning && !hasFocusResults {
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.large)
                Text(focusStatus)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 24)
        } else {
            resultList
        }
    }

    private var placeholder: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 8)
            AnalyzeIdleArtwork()
            scanSplitButton
                .padding(.top, 28)
            Text(l10n.t(state.analyzeFocus.detailKey))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
                .padding(.top, 12)
            Spacer(minLength: 96)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var resultList: some View {
        switch state.analyzeFocus {
        case .largeFiles:
            directoryResults
        case .duplicates:
            duplicateResults
        case .videos:
            mediaResults(items: state.videoItems, emptyKey: "analyze.scan.video.none")
        case .images:
            imageResults
        }
    }

    private var directoryResults: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if state.analyzeLargeFiles.isEmpty && state.analyzeEntries.isEmpty {
                    Text(l10n.t("analyze.scan.large.empty"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                }
                if !state.analyzeLargeFiles.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(l10n.t("analyze.scan.option.large"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        ForEach(state.analyzeLargeFiles, id: \.path) { file in
                            mediaRow(name: file.name, path: file.path, size: file.size, detail: nil)
                        }
                    }
                }
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
                    .disabled(state.isBusy)
                }
                if state.snapshotsScanned {
                    snapshotsSection
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private var duplicateResults: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if state.dupGroups.isEmpty {
                    Text(l10n.t("analyze.dup.empty"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                } else {
                    duplicatesSection
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func mediaResults(items: [MediaFileItem], emptyKey: String) -> some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                if items.isEmpty {
                    Text(l10n.t(emptyKey))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                }
                ForEach(items) { item in
                    mediaRow(name: item.name, path: item.path, size: item.bytes, detail: nil)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private var imageResults: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                if state.images.isEmpty {
                    Text(l10n.t("img.status.none"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                }
                ForEach(state.images) { item in
                    let detail: String? = (item.width > 0 && item.height > 0)
                        ? "\(item.width) × \(item.height)" : nil
                    mediaRow(name: (item.path as NSString).lastPathComponent,
                             path: item.path, size: item.bytes, detail: detail)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func mediaRow(name: String, path: String, size: UInt64, detail: String?) -> some View {
        Button { state.revealFile(at: path) } label: {
            HStack(spacing: 8) {
                Image(systemName: "doc")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.moleAccentText)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(detail ?? path)
                        .font(.system(size: 10, design: detail == nil ? .monospaced : .default))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Text(ByteFormat.format(size))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(MoleSelectableRowButtonStyle(isSelected: false))
        .disabled(state.isBusy)
    }

    @ViewBuilder
    private var footer: some View {
        if state.analyzeFocus == .largeFiles,
           !state.analyzeEntries.isEmpty || !state.analyzeAIItems.isEmpty {
            Divider()
            HStack {
                Text(footerText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button { state.applyAnalyzeCleanup() } label: {
                    Label(l10n.t("analyze.apply"), systemImage: "trash.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled((state.analyzeSelection.isEmpty && state.analyzeAISelection.isEmpty)
                          || state.isBusy)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        } else if state.analyzeFocus == .duplicates, !state.dupGroups.isEmpty {
            Divider()
            HStack {
                Text(footerText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                if !state.dupSelection.isEmpty {
                    Button { state.deleteDuplicates() } label: {
                        Label(l10n.t("analyze.dupDelete"), systemImage: "trash.fill")
                    }
                    .buttonStyle(DangerButtonStyle())
                    .labelStyle(.iconOnly)
                    .help(l10n.t("analyze.dupDelete"))
                    .disabled(state.isBusy)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private var scanSplitButton: some View {
        AnalyzeScanSplitButton(
            title: scanButtonTitle,
            menuOpen: scanMenuOpen,
            primaryEnabled: !state.isBusy || state.isAnalyzing,
            menuEnabled: !state.isBusy,
            accessibilityMenu: l10n.t("analyze.scan.menu")
        ) {
            if state.isAnalyzing {
                state.cancelAnalyze()
            } else {
                state.runAnalyzeFocus(state.analyzeFocus)
            }
            scanMenuOpen = false
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
                        selection: state.analyzeFocus,
                        title: { l10n.t($0.optionKey) },
                        detail: { l10n.t($0.detailKey) }
                    ) { kind in
                        state.selectAnalyzeFocus(kind)
                        scanMenuOpen = false
                    }
                    .frame(width: width, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .offset(x: x, y: y)
                }
            }
        }
    }

    private var showsPlaceholder: Bool {
        !state.completedAnalyzeFocuses.contains(state.analyzeFocus) && !isCurrentFocusRunning
    }

    private var isCurrentFocusRunning: Bool {
        switch state.analyzeFocus {
        case .largeFiles:
            return state.isAnalyzing
        case .duplicates:
            return state.isScanningDups || (state.isAnalyzing && state.duplicateScanPending)
        case .videos:
            return state.isScanningVideos
        case .images:
            return state.isScanningImages
        }
    }

    private var hasFocusResults: Bool {
        switch state.analyzeFocus {
        case .largeFiles:
            return !state.analyzeEntries.isEmpty || !state.analyzeLargeFiles.isEmpty
        case .duplicates:
            return !state.dupGroups.isEmpty
        case .videos:
            return !state.videoItems.isEmpty
        case .images:
            return !state.images.isEmpty
        }
    }

    private var focusStatus: String {
        switch state.analyzeFocus {
        case .largeFiles:
            return state.isAnalyzing ? l10n.t("analyze.scanning") : state.analyzeStatus
        case .duplicates:
            if state.duplicateScanPending || state.isAnalyzing {
                return l10n.t("analyze.scanning")
            }
            return state.isScanningDups ? l10n.t("common.scanning") : state.analyzeStatus
        case .videos:
            return state.videoStatus
        case .images:
            return state.imageStatus
        }
    }

    private var scanButtonTitle: String {
        let cancelsLargeScan = state.isAnalyzing
            && (state.analyzeFocus == .largeFiles || state.duplicateScanPending)
        return cancelsLargeScan ? l10n.t("common.cancel") : l10n.t(state.analyzeFocus.actionKey)
    }

    private var scopeTitle: String {
        if state.analyzePath == "/" { return "/" }
        let name = URL(fileURLWithPath: state.analyzePath).lastPathComponent
        return name.isEmpty ? state.analyzePath : name
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

private struct ScanButtonAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

/// 占位插画：浅蓝团子端着一杯热饮，对应分析页尚未扫描时的空状态。
private struct AnalyzeIdleArtwork: View {
    var body: some View {
        Canvas { context, size in
            let sx = size.width / 320
            let sy = size.height / 190
            context.scaleBy(x: sx, y: sy)

            var shadow = Path()
            shadow.addEllipse(in: CGRect(x: 86, y: 160, width: 156, height: 16))
            context.fill(shadow, with: .color(Color.black.opacity(0.10)))

            var blob = Path()
            blob.move(to: CGPoint(x: 78, y: 108))
            blob.addCurve(to: CGPoint(x: 132, y: 52),
                          control1: CGPoint(x: 36, y: 96), control2: CGPoint(x: 58, y: 40))
            blob.addCurve(to: CGPoint(x: 214, y: 44),
                          control1: CGPoint(x: 168, y: 28), control2: CGPoint(x: 186, y: 26))
            blob.addCurve(to: CGPoint(x: 286, y: 96),
                          control1: CGPoint(x: 258, y: 36), control2: CGPoint(x: 308, y: 58))
            blob.addCurve(to: CGPoint(x: 252, y: 146),
                          control1: CGPoint(x: 304, y: 132), control2: CGPoint(x: 278, y: 158))
            blob.addCurve(to: CGPoint(x: 156, y: 158),
                          control1: CGPoint(x: 224, y: 168), control2: CGPoint(x: 188, y: 172))
            blob.addCurve(to: CGPoint(x: 78, y: 108),
                          control1: CGPoint(x: 108, y: 164), control2: CGPoint(x: 48, y: 142))
            blob.closeSubpath()
            context.fill(blob, with: .color(Color(red: 0.75, green: 0.90, blue: 0.96)))

            var eyes = Path()
            eyes.addRoundedRect(in: CGRect(x: 116, y: 86, width: 22, height: 4.2),
                                cornerSize: CGSize(width: 2, height: 2))
            eyes.addRoundedRect(in: CGRect(x: 156, y: 84, width: 22, height: 4.2),
                                cornerSize: CGSize(width: 2, height: 2))
            context.fill(eyes, with: .color(Color(red: 0.16, green: 0.27, blue: 0.38)))

            let cup = Path(roundedRect: CGRect(x: 186, y: 78, width: 54, height: 42),
                           cornerRadius: 9)
            context.fill(cup, with: .color(Color(red: 0.94, green: 0.98, blue: 1)))
            context.stroke(cup, with: .color(Color(red: 0.22, green: 0.48, blue: 0.66)),
                           lineWidth: 2.6)

            var coffee = Path()
            coffee.move(to: CGPoint(x: 196, y: 93))
            coffee.addLine(to: CGPoint(x: 230, y: 93))
            context.stroke(coffee, with: .color(Color(red: 0.22, green: 0.48, blue: 0.66)),
                           style: StrokeStyle(lineWidth: 2.2, lineCap: .round))

            var handle = Path()
            handle.move(to: CGPoint(x: 238, y: 90))
            handle.addCurve(to: CGPoint(x: 238, y: 112),
                            control1: CGPoint(x: 262, y: 88), control2: CGPoint(x: 262, y: 114))
            context.stroke(handle, with: .color(Color(red: 0.22, green: 0.48, blue: 0.66)),
                           style: StrokeStyle(lineWidth: 2.6, lineCap: .round))

            var steam = Path()
            steam.move(to: CGPoint(x: 204, y: 70))
            steam.addCurve(to: CGPoint(x: 210, y: 46),
                           control1: CGPoint(x: 196, y: 62), control2: CGPoint(x: 216, y: 54))
            steam.move(to: CGPoint(x: 222, y: 68))
            steam.addCurve(to: CGPoint(x: 228, y: 44),
                           control1: CGPoint(x: 214, y: 60), control2: CGPoint(x: 234, y: 52))
            context.stroke(steam, with: .color(Color(red: 0.49, green: 0.66, blue: 0.76)),
                           style: StrokeStyle(lineWidth: 2.1, lineCap: .round))
        }
        .frame(width: 280, height: 166)
        .accessibilityHidden(true)
    }
}

/// 主操作 + 下拉箭头的胶囊按钮。箭头只打开选项，主区域才开始扫描。
private struct AnalyzeScanSplitButton: View {
    let title: String
    let menuOpen: Bool
    let primaryEnabled: Bool
    let menuEnabled: Bool
    let accessibilityMenu: String
    let onPrimary: () -> Void
    let onToggleMenu: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onPrimary) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 18)
                    .frame(minWidth: 132, minHeight: 40)
            }
            .buttonStyle(SplitSegmentStyle())
            .disabled(!primaryEnabled)

            Rectangle()
                .fill(Color.moleOnAccent.opacity(0.28))
                .frame(width: 1, height: 22)

            Button(action: onToggleMenu) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 42, height: 40)
                    .rotationEffect(.degrees(menuOpen ? 180 : 0))
            }
            .buttonStyle(SplitSegmentStyle())
            .disabled(!menuEnabled)
            .accessibilityLabel(accessibilityMenu)
        }
        .foregroundStyle(Color.moleOnAccent)
        .background(Capsule().fill(Color.moleAccent))
        .clipShape(Capsule())
        .opacity(primaryEnabled || menuEnabled ? 1 : 0.45)
        .animation(.easeOut(duration: 0.16), value: menuOpen)
    }
}

private struct SplitSegmentStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.white.opacity(configuration.isPressed ? 0.16 : 0))
            .contentShape(Rectangle())
    }
}

/// 扫描类型面板：标题加说明，交互对齐拆分按钮的下拉列表。
private struct AnalyzeScanMenu: View {
    let selection: AnalyzeScanKind
    let title: (AnalyzeScanKind) -> String
    let detail: (AnalyzeScanKind) -> String
    let onSelect: (AnalyzeScanKind) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(AnalyzeScanKind.allCases) { kind in
                Button { onSelect(kind) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title(kind))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(detail(kind))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(kind == selection
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
